// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

import { IBalanceSheet } from "../interfaces/IBalanceSheet.sol";
import { ICircuitBreaker } from "../interfaces/ICircuitBreaker.sol";
import { IDutchAuction } from "../interfaces/IDutchAuction.sol";
import { ILiquidationTrigger } from "../interfaces/ILiquidationTrigger.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { _WAD, _WARD_ROLE } from "../shared/Constants.sol";
import { NotLive, UnrecognizedParameter } from "../shared/Errors.sol";
import { Cage } from "../shared/Events.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title LiquidationTrigger
 * @author Rain Team
 * @notice The watchdog. When a vault falls below its required collateralization, anyone can point this contract at
 *         it to "bark", seizing the vault and kicking off a Dutch auction to sell its collateral and recover the
 *         debt.
 * @dev Adds a circuit breaker check. When the breaker is active, the rate of new liquidations is throttled to a
 *      fraction of normal.
 */
contract LiquidationTrigger is ILiquidationTrigger, AccessControl {
    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc ILiquidationTrigger
    IVaultEngine public immutable VAULT_ENGINE;

    /// @inheritdoc ILiquidationTrigger
    IBalanceSheet public balanceSheet;

    /// @inheritdoc ILiquidationTrigger
    ICircuitBreaker public circuitBreaker;

    /// @inheritdoc ILiquidationTrigger
    uint256 public globalHole;

    /// @inheritdoc ILiquidationTrigger
    uint256 public globalDirt;

    /// @inheritdoc ILiquidationTrigger
    uint256 public throttle;

    /// @inheritdoc ILiquidationTrigger
    uint256 public live;

    /// @inheritdoc ILiquidationTrigger
    mapping(bytes32 ilkId => IlkLiquidation liquidation) public ilks;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the trigger with the launch throttle of 20%.
     * @param vaultEngine_ Address of the Vault Engine.
     */
    constructor(IVaultEngine vaultEngine_) {
        _setRoleAdmin(_WARD_ROLE, _WARD_ROLE);
        _grantRole(_WARD_ROLE, msg.sender);

        VAULT_ENGINE = vaultEngine_;
        throttle = _WAD / 5;
        live = 1;
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc ILiquidationTrigger
     */
    function file(bytes32 what, uint256 data) external onlyRole(_WARD_ROLE) {
        if (what == "globalHole") {
            globalHole = data;
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
    function file(bytes32 what, address data) external onlyRole(_WARD_ROLE) {
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
    function file(bytes32 ilkId, bytes32 what, uint256 data) external onlyRole(_WARD_ROLE) {
        if (what == "chop") {
            require(data >= _WAD, "LiquidationTrigger/chop-below-one");

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
    function file(bytes32 ilkId, bytes32 what, address clip_) external onlyRole(_WARD_ROLE) {
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
    function cage() external onlyRole(_WARD_ROLE) {
        live = 0;

        emit Cage();
    }

    /**
     * @inheritdoc ILiquidationTrigger
     */
    function bark(bytes32 ilkId, address urn, address kpr) external returns (uint256 id) {
        if (live != 1) {
            _revert(NotLive.selector);
        }

        (uint256 ink, uint256 art) = VAULT_ENGINE.urns(ilkId, urn);
        IlkLiquidation memory milk = ilks[ilkId];
        uint256 dart;
        uint256 rate;
        uint256 dust;

        {
            uint256 spot;
            (, rate, spot, , dust) = VAULT_ENGINE.ilks(ilkId);

            // Unsafe check: the vault's collateral value must be less than its debt.
            require(spot > 0 && ink * spot < art * rate, "LiquidationTrigger/not-unsafe");

            // Capacity checks: room must remain under both the per-collateral and global limits.
            require(globalHole > globalDirt && milk.hole > milk.dirt, "LiquidationTrigger/liquidation-limit-hit");

            uint256 room = Math.min(globalHole - globalDirt, milk.hole - milk.dirt);

            // Circuit breaker check: when the breaker is active, new liquidations are throttled to a fraction of the
            // normal available room per period.
            if (address(circuitBreaker) != address(0) && circuitBreaker.active()) {
                room = (room * throttle) / _WAD;
            }

            // uint256.max()/(RAD*WAD) = 115,792,089,237,316
            dart = Math.min(art, ((room / rate) * _WAD) / milk.chop);

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
        VAULT_ENGINE.grab(ilkId, urn, milk.clip, address(balanceSheet), -int256(dink), -int256(dart));

        uint256 due = dart * rate;
        balanceSheet.fess(due);

        {
            // The debt to recover is increased by the liquidation penalty (13%).
            uint256 tab = (due * milk.chop) / _WAD;
            globalDirt += tab;
            ilks[ilkId].dirt += tab;

            // Starting the Dutch auction. Whoever called bark is eligible for the keeper reward.
            id = IDutchAuction(milk.clip).kick({ tab: tab, lot: dink, usr: urn, kpr: kpr });
        }

        emit Bark({ ilkId: ilkId, urn: urn, ink: dink, art: dart, due: due, clip: milk.clip, id: id });
    }

    /**
     * @inheritdoc ILiquidationTrigger
     */
    function digs(bytes32 ilkId, uint256 rad) external onlyRole(_WARD_ROLE) {
        globalDirt -= rad;
        ilks[ilkId].dirt -= rad;

        emit Digs({ ilkId: ilkId, rad: rad });
    }

    /**
     * @inheritdoc ILiquidationTrigger
     */
    function chop(bytes32 ilkId) external view returns (uint256) {
        return ilks[ilkId].chop;
    }
}
