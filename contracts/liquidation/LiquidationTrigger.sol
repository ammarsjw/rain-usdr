// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IBalanceSheet } from "../interfaces/IBalanceSheet.sol";
import { ICircuitBreaker } from "../interfaces/ICircuitBreaker.sol";
import { IDutchAuction } from "../interfaces/IDutchAuction.sol";
import { IGovernor } from "../interfaces/IGovernor.sol";
import { ILiquidationTrigger } from "../interfaces/ILiquidationTrigger.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { _WAD, _WARD_ROLE } from "../shared/Constants.sol";
import { InvalidAddress, NotLive, SystemPaused, UnrecognizedParameter } from "../shared/Errors.sol";
import { Cage } from "../shared/Events.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title LiquidationTrigger
 * @author Rain Team
 * @notice The watchdog. When a vault falls below its required collateralization, anyone can point this
 *         contract at it to {bark}, seizing the vault and kicking off a Dutch auction to sell its collateral
 *         and recover the debt.
 * @dev Adds a circuit breaker check. When the breaker is active, the rate of new liquidations is throttled to
 *      a fraction of normal.
 */
contract LiquidationTrigger is ILiquidationTrigger, AccessControl {
    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc ILiquidationTrigger
    IVaultEngine public immutable VAULT_ENGINE;

    /// @inheritdoc ILiquidationTrigger
    uint256 public globalHole;

    /// @inheritdoc ILiquidationTrigger
    uint256 public globalDirt;

    /// @inheritdoc ILiquidationTrigger
    uint256 public throttle;

    /// @inheritdoc ILiquidationTrigger
    uint256 public live;

    /// @inheritdoc ILiquidationTrigger
    IBalanceSheet public balanceSheet;

    /// @inheritdoc ILiquidationTrigger
    ICircuitBreaker public circuitBreaker;

    /// @inheritdoc ILiquidationTrigger
    address public governor;

    /// @inheritdoc ILiquidationTrigger
    mapping(bytes32 ilkId => IlkLiquidation liquidation) public ilks;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the trigger.
     * @param vaultEngine_ Address of the Vault Engine.
     */
    constructor(IVaultEngine vaultEngine_) {
        if (address(vaultEngine_) == address(0)) {
            _revert(InvalidAddress.selector);
        }

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
            // The throttle lives in (0, WAD]: it scales available liquidation room while the circuit breaker
            // is active, and zero would silently convert the throttle into a full liquidation halt.
            if (data == 0 || data > _WAD) {
                _revert(InvalidThrottle.selector);
            }

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
        } else if (what == "governor") {
            governor = data;
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
            if (data < _WAD) {
                _revert(ChopBelowOne.selector);
            }

            ilks[ilkId].chop = data;
        } else if (what == "hole") {
            ilks[ilkId].hole = data;
        } else if (what == "barkFactor") {
            // The bark factor must be in (0, 1]: a vault only becomes liquidatable once its collateral ratio
            // falls to this fraction of the ilk's required ratio.
            if (data == 0 || data > _WAD) {
                _revert(InvalidBarkFactor.selector);
            }

            ilks[ilkId].barkFactor = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ ilkId: ilkId, what: what, data: data });
    }

    /**
     * @inheritdoc ILiquidationTrigger
     */
    function file(bytes32 ilkId, bytes32 what, address clip) external onlyRole(_WARD_ROLE) {
        if (what == "clip") {
            ilks[ilkId].clip = clip;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ ilkId: ilkId, what: what, addr: clip });
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
    function bark(uint256 vaultId, address kpr) external returns (uint256 id) {
        if (live != 1) {
            _revert(NotLive.selector);
        }

        // Emergency pause check (full stop).
        if (governor != address(0) && IGovernor(governor).paused()) {
            _revert(SystemPaused.selector);
        }

        // The vault must exist; its collateral type is fixed at open time. Each vault is checked against the
        // bark threshold independently: only the (ink, art) of THIS vault id enter the unsafe condition, so
        // one owner's unsafe vault never drags their other vaults into liquidation.
        address owner = VAULT_ENGINE.ownerOf(vaultId);

        if (owner == address(0)) {
            _revert(VaultNotFound.selector);
        }

        bytes32 ilkId = VAULT_ENGINE.ilkOf(vaultId);

        // The ilk's liquidation parameters must be fully configured. An ilk listed in the Vault Engine but
        // never configured here is borrowable yet unliquidatable: a zero barkFactor makes the unsafe check
        // refuse every vault, a zero clip has no auction house to kick, and a zero chop would zero the
        // divisor in the room calculation. Each failure mode surfaces as an unrelated revert (or silent
        // no-op) — this guard turns the misconfiguration into one typed, monitorable error at the entry
        // point instead.
        {
            IlkLiquidation memory pre = ilks[ilkId];

            if (pre.clip == address(0) || pre.chop < _WAD || pre.barkFactor == 0) {
                _revert(IlkNotConfigured.selector);
            }
        }

        // Accrue the stability fee first so the unsafe check, the tab and the auction all snapshot the true
        // accrued debt at the current rate.
        VAULT_ENGINE.drip(ilkId);

        (uint256 ink, uint256 art) = VAULT_ENGINE.urns(vaultId);

        IlkLiquidation memory milk = ilks[ilkId];
        uint256 dart;
        uint256 rate;
        uint256 dust;

        {
            uint256 spot;

            (, , rate, spot, , dust, , ) = VAULT_ENGINE.ilks(ilkId);

            // Unsafe check: the vault's collateral value must be below `barkFactor` of its debt. `spot` [ray]
            // already embeds the ilk's required ratio (mat), so `ink * spot < art * rate` is the at-mat
            // condition; scaling the debt side by barkFactor [wad] moves the trigger to barkFactor of mat
            // (e.g. 65% of 400% = 260%). Units: ink [wad] * spot [ray] = [rad]; art [wad] * rate [ray] =
            // [rad]. With a variable rate, `art * rate` is no longer a multiple of RAY, so dividing by WAD
            // before multiplying by barkFactor would truncate; Math.mulDiv keeps full 512-bit precision at
            // any rate >= RAY.
            if (spot == 0 || ink * spot >= Math.mulDiv(art * rate, milk.barkFactor, _WAD)) {
                _revert(NotUnsafe.selector);
            }

            // Capacity checks: room must remain under both the per-collateral and global limits.
            if (globalHole <= globalDirt || milk.hole <= milk.dirt) {
                _revert(LiquidationLimitHit.selector);
            }

            uint256 room = Math.min(globalHole - globalDirt, milk.hole - milk.dirt);

            // Circuit breaker check: when the breaker is active, new liquidations are throttled to a fraction
            // of the normal available room per period.
            if (address(circuitBreaker) != address(0) && circuitBreaker.active()) {
                room = (room * throttle) / _WAD;
            }

            // uint256.max()/(RAD*WAD) = 115,792,089,237,316, i.e. the room [rad] * WAD product has overflow
            // headroom up to ~115 trillion rad of room. Ordering multiplies before dividing so small rooms at
            // large rates still yield a correctly scaled, nonzero dart.
            dart = Math.min(art, (room * _WAD) / rate / milk.chop);

            // Partial liquidation edge case logic.
            if (art > dart) {
                if ((art - dart) * rate < dust) {
                    // If the leftover vault would be dusty, liquidate it entirely — but only if the FULL
                    // vault still fits the available room. The bump raises the tab past the amount the room
                    // cap authorized, so without a re-check it would push dirt beyond hole/globalHole,
                    // silently overriding the capacity limits the caps exist to enforce (and, while the
                    // circuit breaker is active, the throttle too). When the full vault does not fit, the
                    // bark fails rather than corrupting the capacity accounting; the vault becomes
                    // liquidatable as room frees up.
                    if (Math.mulDiv(art * rate, milk.chop, _WAD) > room) {
                        _revert(LiquidationLimitHit.selector);
                    }

                    dart = art;
                } else {
                    // In a partial liquidation, the resulting auction should be non-dusty.
                    if (dart * rate < dust) {
                        _revert(DustyAuction.selector);
                    }
                }
            }
        }

        uint256 dink = (ink * dart) / art;

        if (dink == 0) {
            _revert(NullAuction.selector);
        }

        // The signed range's magnitude bound is int256.max (2**255 - 1): a value of exactly 2**255 passes a
        // strict `> 2**255` check but overflows the int256 cast below, surfacing as a raw arithmetic panic
        // instead of the typed error. The guard is therefore inclusive of the boundary.
        if (dart >= 2 ** 255 || dink >= 2 ** 255) {
            _revert(Overflow.selector);
        }

        // Seizing the vault: collateral moves to the auction, debt moves to the balance sheet.
        VAULT_ENGINE.grab(vaultId, milk.clip, address(balanceSheet), -int256(dink), -int256(dart));

        uint256 due = dart * rate;

        balanceSheet.fess(due);

        {
            // The debt to recover is increased by the liquidation penalty (13%).
            uint256 tab = (due * milk.chop) / _WAD;

            globalDirt += tab;
            ilks[ilkId].dirt += tab;

            // Starting the Dutch auction. Whoever called bark is eligible for the keeper reward. Any leftover
            // collateral from the auction is returned to the vault's owner. The vault id rides along so
            // emergency settlement can reclaim the auction into the vault it was seized from.
            id = IDutchAuction(milk.clip).kick({ tab: tab, lot: dink, vaultId: vaultId, usr: owner, kpr: kpr });
        }

        emit Bark({
            ilkId: ilkId,
            vaultId: vaultId,
            urn: owner,
            ink: dink,
            art: dart,
            due: due,
            clip: milk.clip,
            id: id
        });
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
