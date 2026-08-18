// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

import { IBalanceSheet } from "../interfaces/IBalanceSheet.sol";
import { IReserveAccounting } from "../interfaces/IReserveAccounting.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { _RAY, _WAD, _WARD_ROLE } from "../shared/Constants.sol";
import { InvalidAddress, UnrecognizedParameter } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title BalanceSheet
 * @author Rain Team
 * @notice The protocol's treasury and debt manager. Receives revenue as surplus, holds a safety buffer, and absorbs
 *         bad debt through an ordered waterfall. When the surplus buffer is full, the excess goes toward buying back
 *         and burning RAIN.
 * @dev Uses no surplus or debt auctions. USDR uses a RAIN buyback-and-burn for surplus and a controlled backstop for
 *      bad debt instead. The strict "fill before burn" rule is enforced in `distributeSurplus`. Bad debt entering via
 *      `fess` sits in a time-indexed queue for `wait` seconds before it can be healed so surplus cannot be netted
 *      against debt whose auction is still running. USDR has no debt auctions, so there is no `Ash` (on-auction debt)
 *      term anywhere in the accounting.
 */
contract BalanceSheet is IBalanceSheet, AccessControl {
    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc IBalanceSheet
    IVaultEngine public immutable VAULT_ENGINE;

    /// @inheritdoc IBalanceSheet
    uint256 public humpFloor;

    /// @inheritdoc IBalanceSheet
    uint256 public humpRate;

    /// @inheritdoc IBalanceSheet
    uint256 public wait;

    /// @inheritdoc IBalanceSheet
    uint256 public totalQueuedSin;

    /// @inheritdoc IBalanceSheet
    address public buybackReceiver;

    /// @inheritdoc IBalanceSheet
    IReserveAccounting public reserveAccounting;

    /// @inheritdoc IBalanceSheet
    mapping(uint256 era => uint256 tab) public sin;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the balance sheet.
     * @param vaultEngine_ Address of the Vault Engine.
     */
    constructor(IVaultEngine vaultEngine_) {
        if (address(vaultEngine_) == address(0)) {
            _revert(InvalidAddress.selector);
        }

        _setRoleAdmin(_WARD_ROLE, _WARD_ROLE);

        _grantRole(_WARD_ROLE, msg.sender);

        VAULT_ENGINE = vaultEngine_;
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IBalanceSheet
     */
    function file(bytes32 what, uint256 data) external onlyRole(_WARD_ROLE) {
        if (what == "humpFloor") {
            humpFloor = data;
        } else if (what == "humpRate") {
            humpRate = data;
        } else if (what == "wait") {
            wait = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, data: data });
    }

    /**
     * @inheritdoc IBalanceSheet
     */
    function file(bytes32 what, address data) external onlyRole(_WARD_ROLE) {
        if (what == "buybackReceiver") {
            buybackReceiver = data;
        } else if (what == "reserveAccounting") {
            reserveAccounting = IReserveAccounting(data);
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, addr: data });
    }

    /**
     * @inheritdoc IBalanceSheet
     */
    function fess(uint256 tab) external onlyRole(_WARD_ROLE) {
        // Queueing the bad debt by its era so it cannot be healed (or shipped out as surplus) until `wait` seconds
        // have passed and `flog` releases it.
        sin[block.timestamp] += tab;
        totalQueuedSin += tab;

        emit Fess({ tab: tab });
    }

    /**
     * @inheritdoc IBalanceSheet
     */
    function flog(uint256 era) external {
        if (block.timestamp < era + wait) {
            _revert(WaitNotElapsed.selector);
        }

        uint256 tab = sin[era];

        totalQueuedSin -= tab;
        sin[era] = 0;

        emit Flog({ era: era, tab: tab });
    }

    /**
     * @inheritdoc IBalanceSheet
     */
    function heal(uint256 rad) external {
        if (rad > VAULT_ENGINE.usdr(address(this))) {
            _revert(InsufficientSurplus.selector);
        }

        // Only debt released from the queue may be healed. USDR has no debt auctions, so there is no on-auction
        // (Ash) term to subtract, only the queued portion.
        if (rad > VAULT_ENGINE.sin(address(this)) - totalQueuedSin) {
            _revert(InsufficientDebt.selector);
        }

        VAULT_ENGINE.heal(rad);

        emit Heal({ rad: rad });
    }

    /**
     * @inheritdoc IBalanceSheet
     */
    function suck(address kpr, uint256 rad) external onlyRole(_WARD_ROLE) {
        // Creating the reward as a small piece of bad debt, to be covered later from surplus.
        VAULT_ENGINE.suck(address(this), kpr, rad);

        emit Suck({ kpr: kpr, rad: rad });
    }

    /**
     * @inheritdoc IBalanceSheet
     */
    function distributeSurplus() external returns (uint256 excess) {
        uint256 surplus = VAULT_ENGINE.usdr(address(this));
        uint256 badDebt = VAULT_ENGINE.sin(address(this));

        // Bad debt (including debt still sitting in the queue) is always absorbed before any distribution. Queued
        // sin counts too: it is real bad debt that just cannot be healed yet, so it must never be shipped out.
        if (badDebt != 0) {
            _revert(OutstandingBadDebt.selector);
        }

        uint256 target = humpTarget();

        // The strict "fill before burn" rule: the surplus buffer must be above its target first. When the buffer is
        // below target, no distribution happens and all revenue stays -- this is a routine keeper no-op, not an
        // error, so it returns 0 instead of reverting.
        if (surplus <= target) {
            return 0;
        }

        if (buybackReceiver == address(0)) {
            _revert(NoBuybackReceiver.selector);
        }

        // Only the amount above the buffer target is released to the RAIN buyback process.
        excess = surplus - target;

        VAULT_ENGINE.move(address(this), buybackReceiver, excess);

        emit DistributeSurplus({ excess: excess });
    }

    /**
     * @inheritdoc IBalanceSheet
     */
    function humpTarget() public view returns (uint256 target) {
        // Dynamic buffer target: the greater of the static floor and `humpRate` of the total stable reserve. The
        // reserve is tracked in wad, the buffer in rad, so the rate product is scaled up by RAY.
        target = humpFloor;

        if (address(reserveAccounting) != address(0)) {
            uint256 dynamic = ((reserveAccounting.totalReserve() * humpRate) / _WAD) * _RAY;

            if (dynamic > target) {
                target = dynamic;
            }
        }
    }
}
