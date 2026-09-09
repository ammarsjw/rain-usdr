// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

import { ICircuitBreaker } from "../interfaces/ICircuitBreaker.sol";
import { IOracleSecurityModule } from "../interfaces/IOracleSecurityModule.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { _WAD, _WARD_ROLE } from "../shared/Constants.sol";
import { IlkAlreadyInitialized, InvalidAddress, InvalidBytes, UnrecognizedParameter } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title CircuitBreaker
 * @author Rain Team
 * @notice A defense against price manipulation during liquidation. Watches how far each watched collateral's delayed
 *         price has moved from its recent trend. If any move is too large too fast, it throttles liquidations, slowing
 *         them but never freezing them, so a manipulated price cannot trigger a wave of unfair liquidations. It never
 *         touches ordinary vault operations.
 * @dev A single instance watches every registered ilk and aggregates to ONE global verdict: {check} iterates the
 *      watched set, computes each ilk's deviation from its own trailing-average trend, and takes the maximum. The
 *      breaker activates when the maximum deviation exceeds the threshold (25%) and deactivates only after a full calm
 *      period (in seconds) has elapsed since activation AND every ilk's deviation is back under the threshold at that
 *      moment. Trend anchors are per-ilk (deviation is relative, so ilks at different price scales can never share a
 *      buffer), each anchored to the average of a small ring buffer of observations recorded at most once per
 *      `obsInterval`, so a single manipulated observation moves an anchor by at most 1/N.
 *
 *      The global verdict is deliberate policy: a dislocation in ANY watched ilk throttles liquidations of ALL ilks,
 *      mirroring the solvency gate's global posture. The cost is a cross-ilk griefing surface (manipulating one ilk's
 *      market throttles another ilk's liquidations); the OSM delay, the 1/N anchor movement and the fact that the
 *      breaker throttles rather than halts bound that surface. An unavailable price for an ilk skips it rather than
 *      activating: a dark feed is not price manipulation, and liquidations must not freeze because a feed hiccuped
 *      (fail-open, the OPPOSITE polarity from the Solvency Engine, whose unavailable price is a solvency question).
 *
 *      Residual assumption: a keeper calls {check} regularly (at least once per observation interval); if checks stop
 *      entirely, the trends go stale until calls resume.
 */
contract CircuitBreaker is ICircuitBreaker, AccessControl {
    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc ICircuitBreaker
    uint256 public constant OBS_COUNT = 12;

    /// @inheritdoc ICircuitBreaker
    IVaultEngine public immutable VAULT_ENGINE;

    /// @inheritdoc ICircuitBreaker
    IOracleSecurityModule public immutable ORACLE_SECURITY_MODULE;

    /// @inheritdoc ICircuitBreaker
    uint256 public threshold;

    /// @inheritdoc ICircuitBreaker
    uint256 public calmPeriod;

    /// @inheritdoc ICircuitBreaker
    uint256 public obsInterval;

    /// @inheritdoc ICircuitBreaker
    uint256 public activatedAt;

    /// @inheritdoc ICircuitBreaker
    uint256 public lastObsTimestamp;

    /// @inheritdoc ICircuitBreaker
    bool public active;

    /// @inheritdoc ICircuitBreaker
    bytes32[] public watchedIlks;

    /// @inheritdoc ICircuitBreaker
    mapping(bytes32 ilkId => bool watched) public isWatched;

    /// @dev Per-ilk next write position in the ring buffer.
    mapping(bytes32 ilkId => uint256 index) private _obsIndex;

    /// @dev Per-ilk number of populated observations (grows to OBS_COUNT and stays there).
    mapping(bytes32 ilkId => uint256 filled) private _obsFilled;

    /// @dev Per-ilk ring buffer of trailing price observations [wad].
    mapping(bytes32 ilkId => uint256[OBS_COUNT] observations) private _observations;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the breaker.
     * @param vaultEngine_ Address of the Vault Engine, used to validate watched ilks.
     * @param oracleSecurityModule_ Address of the Oracle Security Module to watch.
     */
    constructor(IVaultEngine vaultEngine_, IOracleSecurityModule oracleSecurityModule_) {
        if (address(vaultEngine_) == address(0) || address(oracleSecurityModule_) == address(0)) {
            _revert(InvalidAddress.selector);
        }

        _setRoleAdmin(_WARD_ROLE, _WARD_ROLE);

        _grantRole(_WARD_ROLE, msg.sender);

        VAULT_ENGINE = vaultEngine_;
        ORACLE_SECURITY_MODULE = oracleSecurityModule_;

        threshold = _WAD / 4;
        calmPeriod = 1800;
        obsInterval = 300;
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc ICircuitBreaker
     */
    function file(bytes32 what, uint256 data) external onlyRole(_WARD_ROLE) {
        if (what == "threshold") {
            threshold = data;
        } else if (what == "calmPeriod") {
            calmPeriod = data;
        } else if (what == "obsInterval") {
            obsInterval = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, data: data });
    }

    /**
     * @inheritdoc ICircuitBreaker
     */
    function addIlk(bytes32 ilkId) external onlyRole(_WARD_ROLE) {
        if (isWatched[ilkId]) {
            _revert(IlkAlreadyInitialized.selector);
        }

        // The ilk must exist in the Vault Engine: an unknown ilk would silently contribute a zero deviation forever,
        // polluting the watched set without ever being noticed.
        (, , uint256 rate, , , , , ) = VAULT_ENGINE.ilks(ilkId);

        if (rate == 0) {
            _revert(InvalidBytes.selector);
        }

        isWatched[ilkId] = true;
        watchedIlks.push(ilkId);

        emit AddIlk({ ilkId: ilkId });
    }

    /**
     * @inheritdoc ICircuitBreaker
     */
    function removeIlk(bytes32 ilkId) external onlyRole(_WARD_ROLE) {
        uint256 length = watchedIlks.length;

        for (uint256 i; i < length; ++i) {
            if (watchedIlks[i] == ilkId) {
                // Swap-and-pop removal.
                watchedIlks[i] = watchedIlks[length - 1];
                watchedIlks.pop();
                isWatched[ilkId] = false;

                // Clearing the trend state so a later re-add starts fresh instead of anchoring to a stale trend.
                delete _observations[ilkId];
                delete _obsIndex[ilkId];
                delete _obsFilled[ilkId];

                emit RemoveIlk({ ilkId: ilkId });

                return;
            }
        }

        _revert(InvalidBytes.selector);
    }

    /**
     * @inheritdoc ICircuitBreaker
     */
    function check() external {
        uint256 maxDeviation;
        bytes32 worstIlk;

        // A single global observation clock: one call samples every watched ilk simultaneously, so per-ilk timestamps
        // would all carry the same value anyway. The clock only advances when at least one observation actually lands,
        // so a round where every feed is dark does not silently consume an observation slot.
        bool record = lastObsTimestamp == 0 || block.timestamp - lastObsTimestamp >= obsInterval;
        bool recorded;

        uint256 watchedIlksLength = watchedIlks.length;

        for (uint256 i; i < watchedIlksLength; ++i) {
            bytes32 ilkId = watchedIlks[i];

            (bytes32 val, bool has) = ORACLE_SECURITY_MODULE.peek(ilkId);

            // Fail-open per ilk: a dark feed is not price manipulation, and the breaker must never freeze liquidations
            // because an oracle hiccuped. The ilk simply contributes no deviation this round.
            if (!has) {
                continue;
            }

            uint256 currentPrice = uint256(val);

            // Recording an observation at most once per interval. A single manipulated observation moves an ilk's
            // trailing average by at most 1/OBS_COUNT, so no anchor can be poisoned in one block.
            if (record) {
                _observations[ilkId][_obsIndex[ilkId]] = currentPrice;
                _obsIndex[ilkId] = (_obsIndex[ilkId] + 1) % OBS_COUNT;

                if (_obsFilled[ilkId] < OBS_COUNT) {
                    ++_obsFilled[ilkId];
                }

                recorded = true;
            }

            // Comparing the current delayed price to this ilk's trailing-average trend and aggregating the maximum:
            // the global verdict is driven by the single worst dislocation across the watched set.
            uint256 deviation = _deviation(currentPrice, trendPrice(ilkId));

            if (deviation > maxDeviation) {
                maxDeviation = deviation;
                worstIlk = ilkId;
            }
        }

        if (recorded) {
            lastObsTimestamp = block.timestamp;
        }

        if (maxDeviation > threshold) {
            // The move is too large too fast: activate (or re-anchor the calm clock while already active).
            if (!active) {
                active = true;

                emit Activated({ ilkId: worstIlk, deviation: maxDeviation });
            }

            activatedAt = block.timestamp;
        } else if (active && block.timestamp >= activatedAt + calmPeriod) {
            // Time-based deactivation: a full calm period has elapsed since the last above-threshold reading AND every
            // watched ilk's deviation is back under the threshold right now (the maximum is under it).
            active = false;
            activatedAt = 0;

            emit Deactivated();
        }

        emit Checked({ worstIlk: worstIlk, maxDeviation: maxDeviation, active: active });
    }

    /**
     * @inheritdoc ICircuitBreaker
     */
    function trendPrice(bytes32 ilkId) public view returns (uint256 trend) {
        uint256 filled = _obsFilled[ilkId];

        if (filled == 0) {
            return 0;
        }

        uint256 sum;

        for (uint256 i; i < filled; ++i) {
            sum += _observations[ilkId][i];
        }

        trend = sum / filled;
    }

    /**
     * @inheritdoc ICircuitBreaker
     */
    function ilkCount() external view returns (uint256) {
        return watchedIlks.length;
    }

    /**
     * @dev Returns the relative deviation between two prices [wad].
     * @param current The current price [wad].
     * @param trend The trend anchor price [wad].
     * @return deviation The relative deviation [wad].
     */
    function _deviation(uint256 current, uint256 trend) private pure returns (uint256) {
        if (trend == 0) {
            return 0;
        }

        uint256 diff = current > trend ? current - trend : trend - current;

        return (diff * _WAD) / trend;
    }
}
