// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

import { ICircuitBreaker } from "../interfaces/ICircuitBreaker.sol";
import { IOracleSecurityModule } from "../interfaces/IOracleSecurityModule.sol";
import { _WAD, _WARD_ROLE } from "../shared/Constants.sol";
import { InvalidAddress, InvalidBytes, UnrecognizedParameter } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title CircuitBreaker
 * @author Rain Team
 * @notice A defense against price manipulation during liquidation. Watches how far the delayed price has moved from
 *         its recent trend. If the move is too large too fast, it throttles liquidations, slowing them but never
 *         freezing them, so a manipulated price cannot trigger a wave of unfair liquidations. It never touches
 *         ordinary vault operations.
 * @dev Activates when the delayed price deviates more than the threshold (25%) from the trailing-average trend.
 *      Deactivates only after a full calm period (in seconds) has elapsed since activation AND the deviation is back
 *      under the threshold at that moment. The trend anchor is the average of a small ring buffer of observations
 *      recorded at most once per `obsInterval`, so a single manipulated observation moves the anchor by at most 1/N.
 *      Residual assumption: a keeper calls {check} regularly (at least once per observation interval); if checks stop
 *      entirely, the trend goes stale until calls resume.
 */
contract CircuitBreaker is ICircuitBreaker, AccessControl {
    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc ICircuitBreaker
    uint256 public constant OBS_COUNT = 12;

    /// @inheritdoc ICircuitBreaker
    bytes32 public immutable ILK_ID;

    /// @inheritdoc ICircuitBreaker
    IOracleSecurityModule public immutable PIP;

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

    /// @dev Next write position in the ring buffer.
    uint256 private _obsIndex;

    /// @dev Number of populated observations (grows to OBS_COUNT and stays there).
    uint256 private _obsFilled;

    /// @dev Ring buffer of trailing price observations [wad].
    uint256[OBS_COUNT] private _observations;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the breaker.
     * @param ilkId_ Identifier of the collateral type to watch.
     * @param pip_ Address of the Oracle Security Module to watch.
     */
    constructor(bytes32 ilkId_, IOracleSecurityModule pip_) {
        if (ilkId_ == bytes32(0)) {
            _revert(InvalidBytes.selector);
        }

        if (address(pip_) == address(0)) {
            _revert(InvalidAddress.selector);
        }

        _setRoleAdmin(_WARD_ROLE, _WARD_ROLE);

        _grantRole(_WARD_ROLE, msg.sender);

        ILK_ID = ilkId_;
        PIP = pip_;

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
    function check() external {
        (bytes32 val, bool has) = PIP.peek(ILK_ID);

        if (!has) {
            return;
        }

        uint256 currentPrice = uint256(val);

        // Recording an observation at most once per interval. A single manipulated observation moves the trailing
        // average by at most 1/OBS_COUNT, so the anchor cannot be poisoned in one block.
        if (lastObsTimestamp == 0 || block.timestamp - lastObsTimestamp >= obsInterval) {
            _observations[_obsIndex] = currentPrice;
            _obsIndex = (_obsIndex + 1) % OBS_COUNT;

            if (_obsFilled < OBS_COUNT) {
                ++_obsFilled;
            }

            lastObsTimestamp = block.timestamp;
        }

        // Comparing the current delayed price to the trailing-average trend.
        uint256 deviation = _deviation(currentPrice, trendPrice());

        if (deviation > threshold) {
            // The move is too large too fast: activate (or re-anchor the calm clock while already active).
            if (!active) {
                active = true;

                emit Activated({ deviation: deviation });
            }

            activatedAt = block.timestamp;
        } else if (active && block.timestamp >= activatedAt + calmPeriod) {
            // Time-based deactivation: a full calm period has elapsed since the last above-threshold reading AND the
            // deviation is back under the threshold right now.
            active = false;
            activatedAt = 0;

            emit Deactivated();
        }

        emit Checked({ deviation: deviation, active: active });
    }

    /**
     * @inheritdoc ICircuitBreaker
     */
    function trendPrice() public view returns (uint256 trend) {
        uint256 filled = _obsFilled;

        if (filled == 0) {
            return 0;
        }

        uint256 sum;

        for (uint256 i; i < filled; ++i) {
            sum += _observations[i];
        }

        trend = sum / filled;
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
