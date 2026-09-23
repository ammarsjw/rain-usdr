// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

import { IDutchAuction } from "../interfaces/IDutchAuction.sol";
import { IExternalExposure } from "../interfaces/IExternalExposure.sol";
import { IOracleSecurityModule } from "../interfaces/IOracleSecurityModule.sol";
import { IReserveAccounting } from "../interfaces/IReserveAccounting.sol";
import { ISolvencyEngine } from "../interfaces/ISolvencyEngine.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { _RAY, _WAD, _WARD_ROLE } from "../shared/Constants.sol";
import { IlkAlreadyInitialized, InvalidAddress, InvalidBytes, UnrecognizedParameter } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title SolvencyEngine
 * @author Rain Team
 * @notice The guardian. Computes the protocol's worst-case loss under stress and verifies that the stable
 *         reserve exceeds it. When the worst-case loss exceeds the configured fraction of the reserve, the
 *         engine flags a breach and the rest of the system gates every non-reserve-increasing operation until
 *         the invariant is restored. A keeper bot is expected to call {checkInvariant} regularly to keep the
 *         flag fresh.
 * @dev The stress scenario prices COLLATERAL: each volatile ilk's aggregate locked collateral is valued at
 *      the delayed oracle price read DIRECTLY from the Oracle Security Module (never reconstructed as spot
 *      times mat), marked down by the stress markdown (50%) and the stress liquidation depth (35%); the loss
 *      is any debt not covered by that stressed recoverable value. An unavailable price values the collateral
 *      at zero, so the invariant fails CLOSED. Exposure reported by the prediction market layer is consumed
 *      defensively: it is clamped to a governance-set cap and a reverting reporter falls back to the cap, so
 *      the invariant can never overflow or permanently revert.
 */
contract SolvencyEngine is ISolvencyEngine, AccessControl {
    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc ISolvencyEngine
    IVaultEngine public immutable VAULT_ENGINE;

    /// @inheritdoc ISolvencyEngine
    IReserveAccounting public immutable RESERVE_ACCOUNTING;

    /// @inheritdoc ISolvencyEngine
    uint256 public stressMarkdown;

    /// @inheritdoc ISolvencyEngine
    uint256 public stressDepth;

    /// @inheritdoc ISolvencyEngine
    uint256 public reserveFactor;

    /// @inheritdoc ISolvencyEngine
    uint256 public exposureCap;

    /// @inheritdoc ISolvencyEngine
    bool public breached;

    /// @inheritdoc ISolvencyEngine
    IExternalExposure public externalExposure;

    /// @inheritdoc ISolvencyEngine
    IOracleSecurityModule public osm;

    /// @inheritdoc ISolvencyEngine
    bytes32[] public volatileIlks;

    /// @inheritdoc ISolvencyEngine
    mapping(bytes32 ilkId => IDutchAuction auctionHouse) public auctionHouse;

    /// @inheritdoc ISolvencyEngine
    mapping(bytes32 ilkId => bool volatile) public isVolatile;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the engine.
     * @param vaultEngine_ Address of the Vault Engine.
     * @param reserveAccounting_ Address of the reserve accounting contract.
     */
    constructor(IVaultEngine vaultEngine_, IReserveAccounting reserveAccounting_) {
        if (address(vaultEngine_) == address(0) || address(reserveAccounting_) == address(0)) {
            _revert(InvalidAddress.selector);
        }

        _setRoleAdmin(_WARD_ROLE, _WARD_ROLE);

        _grantRole(_WARD_ROLE, msg.sender);

        VAULT_ENGINE = vaultEngine_;
        RESERVE_ACCOUNTING = reserveAccounting_;

        stressMarkdown = _WAD / 2;
        stressDepth = (_WAD * 35) / 100;
        reserveFactor = (_WAD * 9) / 10;
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc ISolvencyEngine
     */
    function file(bytes32 what, uint256 data) external onlyRole(_WARD_ROLE) {
        // stressMarkdown and stressDepth are deliberately NOT filable here (audit M10): their PRODUCT
        // determines stressed recovery, and two independently scheduled scalar updates let a permissionless
        // executor order a mixed-direction transition through a transient tuple more permissive than either
        // endpoint (e.g. 50%*60% -> 40%*70% exposes 50%*70% if depth executes first), draining reserve at a
        // false-solvent intermediate. Correlated risk-policy transitions go through {fileStress}, which
        // validates and writes the complete tuple atomically.
        if (what == "reserveFactor") {
            // The breach threshold fraction lives in (0, WAD]: zero would flag a breach on any loss
            // regardless of reserve, above WAD would tolerate losses exceeding the entire reserve.
            if (data == 0 || data > _WAD) {
                _revert(ParameterOutOfBounds.selector);
            }

            reserveFactor = data;
        } else if (what == "exposureCap") {
            // Symmetric guard to the wiring check below: zeroing the cap while a reporter is wired clamps
            // every honest report to zero AND turns a reverting reporter's fallback into zero, exactly what
            // the wiring guard was added to prevent. Disabling exposure tracking must be done explicitly by
            // unwiring the reporter first.
            if (data == 0 && address(externalExposure) != address(0)) {
                _revert(ExposureCapNotSet.selector);
            }

            exposureCap = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, data: data });
    }

    /**
     * @inheritdoc ISolvencyEngine
     */
    function fileStress(uint256 markdown, uint256 depth) external onlyRole(_WARD_ROLE) {
        // The complete stress tuple is validated and written ATOMICALLY (audit M10): governance schedules
        // this single call, so no permissionless executor can order a mixed-direction transition through a
        // transient tuple more permissive than either endpoint. Stress parameters live in (0, WAD]: zero
        // would value all collateral at nothing forever (permanent breach), above WAD would inflate
        // recoverable value beyond market (disabling the invariant).
        if (markdown == 0 || markdown > _WAD || depth == 0 || depth > _WAD) {
            _revert(ParameterOutOfBounds.selector);
        }

        stressMarkdown = markdown;
        stressDepth = depth;

        emit FileStress({ markdown: markdown, depth: depth });
    }

    /**
     * @inheritdoc ISolvencyEngine
     */
    function file(bytes32 what, address data) external onlyRole(_WARD_ROLE) {
        if (what == "externalExposure") {
            // Wiring an exposure reporter without a nonzero cap would clamp every report to zero (fail-open);
            // the cap must be configured first.
            if (data != address(0) && exposureCap == 0) {
                _revert(ExposureCapNotSet.selector);
            }

            externalExposure = IExternalExposure(data);
        } else if (what == "osm") {
            osm = IOracleSecurityModule(data);
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, data: uint256(uint160(data)) });
    }

    /**
     * @inheritdoc ISolvencyEngine
     */
    function file(bytes32 ilkId, bytes32 what, address data) external onlyRole(_WARD_ROLE) {
        if (what == "auctionHouse") {
            // The auction house must serve this exact ilk: a mismatched wiring would price another
            // collateral's in-auction exposure under this ilk's oracle and silently corrupt the loss
            // computation.
            if (data != address(0) && IDutchAuction(data).ILK_ID() != ilkId) {
                _revert(InvalidBytes.selector);
            }

            auctionHouse[ilkId] = IDutchAuction(data);
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ ilkId: ilkId, what: what, data: uint256(uint160(data)) });
    }

    /**
     * @inheritdoc ISolvencyEngine
     */
    function addVolatileIlk(bytes32 ilkId) external onlyRole(_WARD_ROLE) {
        if (isVolatile[ilkId]) {
            _revert(IlkAlreadyInitialized.selector);
        }

        // The ilk must exist in the Vault Engine: an unknown ilk would silently contribute zero debt and zero
        // collateral, polluting the loss computation without ever being noticed.
        (, , uint256 rate, , , , , ) = VAULT_ENGINE.ilks(ilkId);

        if (rate == 0) {
            _revert(InvalidBytes.selector);
        }

        isVolatile[ilkId] = true;
        volatileIlks.push(ilkId);

        emit AddVolatileIlk({ ilkId: ilkId });
    }

    /**
     * @inheritdoc ISolvencyEngine
     */
    function removeVolatileIlk(bytes32 ilkId) external onlyRole(_WARD_ROLE) {
        uint256 length = volatileIlks.length;

        for (uint256 i; i < length; ++i) {
            if (volatileIlks[i] == ilkId) {
                // The ilk must carry NO live exposure before it leaves the loss model (audit M09): removal
                // deletes its contribution from the only list worstCaseLoss traverses, so delisting an ilk
                // with outstanding debt would release escrow against exposure that still exists. Symmetric
                // with addVolatileIlk's existence check. Both exposure sources are checked: live vault debt
                // (globalArt) and seized-but-unsettled auctions (totalTab/totalLot), which the loss term
                // prices the same way.
                (uint256 globalArt, , , , , , , ) = VAULT_ENGINE.ilks(ilkId);

                if (globalArt != 0) {
                    _revert(IlkStillExposed.selector);
                }

                IDutchAuction house = auctionHouse[ilkId];

                if (address(house) != address(0) && (house.totalTab() != 0 || house.totalLot() != 0)) {
                    _revert(IlkStillExposed.selector);
                }

                // Swap-and-pop removal.
                volatileIlks[i] = volatileIlks[length - 1];
                volatileIlks.pop();
                isVolatile[ilkId] = false;

                emit RemoveVolatileIlk({ ilkId: ilkId });

                return;
            }
        }

        _revert(InvalidBytes.selector);
    }

    /**
     * @inheritdoc ISolvencyEngine
     */
    function checkInvariant() external returns (uint256 loss, uint256 reserve) {
        loss = worstCaseLoss();

        // The breach test is judged against the EFFECTIVE reserve (audit H05): fresh same-block inflow is
        // discounted, so a flash-loaned sellStable cannot widen the denominator inside the transaction that
        // made it and step over the gate. From the next block onward the inflow counts in full.
        reserve = RESERVE_ACCOUNTING.effectiveReserve();

        // Surfacing exposure-reporter anomalies for monitoring: a revert or an above-cap report both fall
        // back to the conservative cap inside {worstCaseLoss}; here the anomaly is made visible.
        if (address(externalExposure) != address(0)) {
            try externalExposure.reportedExposure() returns (uint256 reported) {
                if (reported > exposureCap) {
                    emit ExposureClamped({ reported: reported, cap: exposureCap });
                }
            } catch {
                emit ExposureClamped({ reported: type(uint256).max, cap: exposureCap });
            }
        }

        // The master rule: worst-case loss must stay under the gated fraction of the stable reserve. This
        // function never reverts on a breach: state is always brought up to date so the committed escrow and
        // free slack can never go stale (a stale escrow would let redemptions overpay).
        breached = loss > (reserve * reserveFactor) / _WAD;

        // Keeping the reserve split accurate. The escrow is committed at the SAME coverage the breach test
        // demands (loss / reserveFactor, not the raw loss): the breach test requires the reserve to exceed
        // the loss by the buffer, so the dollars reserved against that loss must include the buffer too.
        // Committing the raw loss lets permissionless redemption drain free slack down to exactly `loss`,
        // where the very next breach test (loss > loss * reserveFactor) is true by construction — ordinary
        // user behaviour walks the protocol into a self-inflicted breach. With the buffered escrow,
        // exhausting free slack leaves reserve == loss / reserveFactor and the invariant precisely
        // satisfied. Still capped at the full reserve so accounting never reverts.
        uint256 required = (loss * _WAD) / reserveFactor;

        RESERVE_ACCOUNTING.updateCommittedEscrow(required > reserve ? reserve : required);

        emit InvariantChecked({ reserve: reserve, worstCaseLoss: loss, passed: !breached });
    }

    /**
     * @inheritdoc ISolvencyEngine
     */
    function isBreached() external view returns (bool) {
        return breached;
    }

    /**
     * @inheritdoc ISolvencyEngine
     */
    function breachThreshold() external view returns (uint256) {
        return (RESERVE_ACCOUNTING.totalReserve() * reserveFactor) / _WAD;
    }

    /**
     * @inheritdoc ISolvencyEngine
     */
    function worstCaseLoss() public view returns (uint256 loss) {
        // Adding the shortfall risk from volatile collateral, priced at stressed COLLATERAL values: debt
        // outstanding minus the stressed recoverable value of the collateral actually locked against it.
        uint256 volatileIlksLength = volatileIlks.length;

        for (uint256 i; i < volatileIlksLength; ++i) {
            bytes32 ilkId = volatileIlks[i];

            (uint256 globalArt, , uint256 rate, , , , , ) = VAULT_ENGINE.ilks(ilkId);

            // Total debt against this collateral [wad]: art [wad] * rate [ray] / RAY.
            uint256 ilkDebt = (globalArt * rate) / _RAY;

            // Collateral market value [wad], priced DIRECTLY from the Oracle Security Module. Reconstructing
            // the price as spot * mat is forbidden: a mat change without a poke desynchronizes the two and
            // the reconstructed price is wrong by exactly matNew / matOld. An unavailable or zero price
            // values the collateral at zero, which is the conservative direction (loss rises).
            uint256 collateralValue;

            (bytes32 val, bool has) = osm.peek(ilkId);

            if (has) {
                // Backed ink only: collateral in a debt-free vault can never pay another vault's debt
                // (liquidation surplus returns to the vault's own owner), so pricing the recoverable value
                // from the raw global ink would let an idle or flash-deposited vault suppress the loss and
                // disarm the gates. Only collateral in vaults that actually carry debt is credited.
                collateralValue = (VAULT_ENGINE.backedInk(ilkId) * uint256(val)) / _WAD;
            }

            // Stressed recoverable value: collateral value marked down by the stress markdown [wad] and the
            // stress liquidation depth [wad].
            uint256 recoverable = (((collateralValue * stressMarkdown) / _WAD) * stressDepth) / _WAD;

            if (ilkDebt > recoverable) {
                loss += ilkDebt - recoverable;
            }

            // Seized-but-unsettled risk: debt moved to the liquidation pipeline by grab leaves the live urn
            // aggregates above, but the shortfall persists until take or heal actually covers it. The
            // remaining auction tab is charged as debt, credited with the stressed value of the collateral
            // still on auction (the same markdown and depth applied to live vaults), so a bark can never
            // lower the computed loss.
            IDutchAuction house = auctionHouse[ilkId];

            if (address(house) != address(0)) {
                // Remaining auction debt [wad]: tab [rad] / RAY.
                uint256 auctionDebt = house.totalTab() / _RAY;

                uint256 auctionLotValue;

                if (has) {
                    auctionLotValue = (house.totalLot() * uint256(val)) / _WAD;
                }

                uint256 auctionRecoverable = (((auctionLotValue * stressMarkdown) / _WAD) * stressDepth) / _WAD;

                if (auctionDebt > auctionRecoverable) {
                    loss += auctionDebt - auctionRecoverable;
                }
            }
        }

        // Adding any exposure reported by the prediction market layer, defensively: a reverting reporter
        // falls back to the cap (conservative), and any reported value is clamped to the cap so it can never
        // overflow the sum.
        if (address(externalExposure) != address(0)) {
            uint256 exposure = exposureCap;

            try externalExposure.reportedExposure() returns (uint256 reported) {
                exposure = reported > exposureCap ? exposureCap : reported;
            } catch {
                // Reporter reverted: use the cap.
            }

            loss += exposure;
        }
    }
}
