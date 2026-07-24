// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IBalanceSheet } from "../interfaces/IBalanceSheet.sol";
import { ICircuitBreaker } from "../interfaces/ICircuitBreaker.sol";
import { IDutchAuction } from "../interfaces/IDutchAuction.sol";
import { ILiquidationTrigger } from "../interfaces/ILiquidationTrigger.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { Auth } from "../shared/Auth.sol";
import { WAD, WARD_ROLE } from "../shared/Constants.sol";
import { NotLive, UnrecognizedParameter } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title LiquidationTrigger.
 * @author Rain Team.
 * @notice The watchdog. When a vault falls below its required collateralization, anyone can
 *         point this contract at it to "bark" — seizing the vault and kicking off a Dutch
 *         auction to sell its collateral and recover the debt.
 * @dev Based on MakerDAO's Dog. Adds a circuit breaker check: when the breaker is active, the
 *      rate of new liquidations is throttled to a fraction of normal.
 */
contract LiquidationTrigger is ILiquidationTrigger, Auth {
    /* ========================== TYPES ========================== */

    /**
     * @notice Liquidation settings for a collateral type.
     * @param clip The Dutch auction contract for this collateral.
     * @param chop The liquidation penalty [wad]. 13% = 1.13 * WAD.
     * @param hole The maximum active liquidation size for this collateral [rad].
     * @param dirt The amount currently being auctioned for this collateral [rad].
     */
    struct IlkLiquidation {
        address clip;
        uint256 chop;
        uint256 hole;
        uint256 dirt;
    }

    /* ========================== STATE VARIABLES ========================== */

    /// @notice Liquidation settings per collateral type.
    mapping(bytes32 ilkId => IlkLiquidation liquidation) public ilks;

    /// @notice The Vault Engine (core ledger).
    IVaultEngine public immutable vaultEngine;

    /// @notice The Balance Sheet that receives seized debt.
    IBalanceSheet public balanceSheet;

    /// @notice The circuit breaker that throttles liquidations during abnormal price moves.
    ICircuitBreaker public circuitBreaker;

    /// @notice The maximum active liquidation size across all collateral types [rad].
    uint256 public Hole;

    /// @notice The amount currently being auctioned across all collateral types [rad].
    uint256 public Dirt;

    /// @notice Throttled liquidation rate while the breaker is active [wad]. 20% = 0.2 * WAD.
    uint256 public throttle;

    /// @notice Liveness flag. `1` while live, `0` after shutdown.
    uint256 public live;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the trigger with the launch throttle of 20%.
     * @param vaultEngine_ Address of the Vault Engine.
     */
    constructor(IVaultEngine vaultEngine_) {
        vaultEngine = vaultEngine_;
        throttle = WAD / 5;
        live = 1;

        _initAuth();
    }

    /* ========================== ADMINISTRATION ========================== */

    /**
     * @inheritdoc ILiquidationTrigger
     */
    function file(bytes32 what, uint256 data) external onlyRole(WARD_ROLE) {
        if (what == "Hole") {
            Hole = data;
        } else if (what == "throttle") {
            throttle = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, data: data });
    }

    /**
     * @inheritdoc ILiquidationTrigger
     */
    function file(bytes32 what, address data) external onlyRole(WARD_ROLE) {
        if (what == "balanceSheet") {
            balanceSheet = IBalanceSheet(data);
        } else if (what == "circuitBreaker") {
            circuitBreaker = ICircuitBreaker(data);
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, addr: data });
    }

    /**
     * @inheritdoc ILiquidationTrigger
     */
    function file(bytes32 ilkId, bytes32 what, uint256 data) external onlyRole(WARD_ROLE) {
        if (what == "chop") {
            require(data >= WAD, "LiquidationTrigger/chop-below-one");

            ilks[ilkId].chop = data;
        } else if (what == "hole") {
            ilks[ilkId].hole = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ ilkId: ilkId, what: what, data: data });
    }

    /**
     * @inheritdoc ILiquidationTrigger
     */
    function file(bytes32 ilkId, bytes32 what, address clip_) external onlyRole(WARD_ROLE) {
        if (what == "clip") {
            ilks[ilkId].clip = clip_;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ ilkId: ilkId, what: what, addr: clip_ });
    }

    /**
     * @inheritdoc ILiquidationTrigger
     */
    function cage() external onlyRole(WARD_ROLE) {
        live = 0;

        emit Cage();
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc ILiquidationTrigger
     */
    function chop(bytes32 ilkId) external view returns (uint256) {
        return ilks[ilkId].chop;
    }

    /**
     * @inheritdoc ILiquidationTrigger
     */
    function bark(bytes32 ilkId, address urn, address kpr) external returns (uint256 id) {
        if (live != 1) {
            _revert(NotLive.selector);
        }

        (uint256 ink, uint256 art) = vaultEngine.urns(ilkId, urn);
        IlkLiquidation memory milk = ilks[ilkId];
        uint256 dart;
        uint256 rate;
        uint256 dust;

        {
            uint256 spot;
            (, rate, spot, , dust) = vaultEngine.ilks(ilkId);

            // Unsafe check: the vault's collateral value must be less than its debt.
            require(spot > 0 && ink * spot < art * rate, "LiquidationTrigger/not-unsafe");

            // Capacity checks: room must remain under both the per-collateral and global limits.
            require(Hole > Dirt && milk.hole > milk.dirt, "LiquidationTrigger/liquidation-limit-hit");

            uint256 room = _min(Hole - Dirt, milk.hole - milk.dirt);

            // Circuit breaker check: when the breaker is active, new liquidations are throttled
            // to a fraction of the normal available room per period.
            if (address(circuitBreaker) != address(0) && circuitBreaker.active()) {
                room = (room * throttle) / WAD;
            }

            // uint256.max()/(RAD*WAD) = 115,792,089,237,316
            dart = _min(art, ((room / rate) * WAD) / milk.chop);

            // Partial liquidation edge case logic.
            if (art > dart) {
                if ((art - dart) * rate < dust) {
                    // If the leftover vault would be dusty, liquidate it entirely.
                    dart = art;
                } else {
                    // In a partial liquidation, the resulting auction should be non-dusty.
                    require(dart * rate >= dust, "LiquidationTrigger/dusty-auction-from-partial-liquidation");
                }
            }
        }

        uint256 dink = (ink * dart) / art;

        require(dink > 0, "LiquidationTrigger/null-auction");
        require(dart <= 2 ** 255 && dink <= 2 ** 255, "LiquidationTrigger/overflow");

        // Seizing the vault: collateral moves to the auction, debt moves to the balance sheet.
        vaultEngine.grab(ilkId, urn, milk.clip, address(balanceSheet), -int256(dink), -int256(dart));

        uint256 due = dart * rate;
        balanceSheet.fess(due);

        {
            // The debt to recover is increased by the liquidation penalty (13%).
            uint256 tab = (due * milk.chop) / WAD;
            Dirt += tab;
            ilks[ilkId].dirt += tab;

            // Starting the Dutch auction. Whoever called bark is eligible for the keeper reward.
            id = IDutchAuction(milk.clip).kick({ tab: tab, lot: dink, usr: urn, kpr: kpr });
        }

        emit Bark({ ilkId: ilkId, urn: urn, ink: dink, art: dart, due: due, clip: milk.clip, id: id });
    }

    /**
     * @inheritdoc ILiquidationTrigger
     */
    function digs(bytes32 ilkId, uint256 rad) external onlyRole(WARD_ROLE) {
        Dirt -= rad;
        ilks[ilkId].dirt -= rad;

        emit Digs({ ilkId: ilkId, rad: rad });
    }

    /* ========================== MATH HELPERS ========================== */

    /// @dev Returns the smaller of two numbers.
    function _min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x <= y ? x : y;
    }
}
