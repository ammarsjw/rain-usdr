// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

import { IReserveAccounting } from "../interfaces/IReserveAccounting.sol";
import { _COMMITTER_ROLE, _RECORDER_ROLE, _WARD_ROLE } from "../shared/Constants.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title ReserveAccounting
 * @author Rain Team
 * @notice The bookkeeper for the protocol's stable dollars. Tracks the total reserve (all USDT and USDC
 *         held), how much is committed to guaranteed obligations (the settlement escrow), and how much is
 *         free (the slack). This is where the reserve is split so that the same dollar is never promised
 *         twice.
 * @dev Only the Solvency Engine may update the committed escrow, and only the Peg Stability Modules may
 *      record reserve movements.
 */
contract ReserveAccounting is IReserveAccounting, AccessControl {
    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc IReserveAccounting
    uint256 public totalReserve;

    /// @inheritdoc IReserveAccounting
    uint256 public committedEscrow;

    /// @inheritdoc IReserveAccounting
    uint256 public sameBlockInflow;

    /// @inheritdoc IReserveAccounting
    uint256 public lastInflowBlock;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Authorizes the deployer.
     */
    constructor() {
        _setRoleAdmin(_COMMITTER_ROLE, _WARD_ROLE);
        _setRoleAdmin(_RECORDER_ROLE, _WARD_ROLE);
        _setRoleAdmin(_WARD_ROLE, _WARD_ROLE);

        _grantRole(_WARD_ROLE, msg.sender);
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IReserveAccounting
     */
    function recordIncrease(uint256 wad) external onlyRole(_RECORDER_ROLE) {
        totalReserve += wad;

        // Same-block inflow tracking (audit H05): an inflow only counts toward the solvency breach test and
        // the free slack from the NEXT block onward. Without this, a flash-loaned sellStable -> buyStable
        // round trip inflates the breach test's denominator (and widens free slack) inside one transaction,
        // stepping over the gate at will. The accumulator resets when the block advances.
        if (block.number != lastInflowBlock) {
            sameBlockInflow = 0;
            lastInflowBlock = block.number;
        }

        sameBlockInflow += wad;

        emit RecordIncrease({ wad: wad, totalReserve: totalReserve });
    }

    /**
     * @inheritdoc IReserveAccounting
     */
    function recordDecrease(uint256 wad) external onlyRole(_RECORDER_ROLE) {
        totalReserve -= wad;

        // Same-block inflow tracking (audit H05): an outflow un-counts fresh same-block inflow first, so a
        // deposit-then-withdraw round trip nets to zero rather than leaving phantom "settled" inflow behind.
        // Only the portion exceeding the fresh inflow touches the settled figure.
        if (block.number == lastInflowBlock && sameBlockInflow != 0) {
            sameBlockInflow = wad >= sameBlockInflow ? 0 : sameBlockInflow - wad;
        }

        // The reserve must never drop below the committed escrow: freeSlack() would underflow and every
        // consumer of the split (redemption above all) would revert. The PSM checks freeSlack before
        // recording, so this is defence in depth against any future recorder that does not.
        if (totalReserve < committedEscrow) {
            _revert(ReserveBelowEscrow.selector);
        }

        emit RecordDecrease({ wad: wad, totalReserve: totalReserve });
    }

    /**
     * @inheritdoc IReserveAccounting
     */
    function updateCommittedEscrow(uint256 wad) external onlyRole(_COMMITTER_ROLE) {
        // The committed amount must not exceed the total reserve. This is the solvency guarantee expressed at
        // the accounting level.
        if (wad > totalReserve) {
            _revert(EscrowExceedsReserve.selector);
        }

        committedEscrow = wad;

        emit UpdateCommittedEscrow({ wad: wad, freeSlack: totalReserve - wad });
    }

    /**
     * @inheritdoc IReserveAccounting
     */
    function effectiveReserve() public view returns (uint256) {
        // The reserve figure a solvency judgment may trust THIS block (audit H05): fresh same-block inflow is
        // discounted, so a flash-loaned deposit cannot widen the breach test's denominator or the free slack
        // inside the transaction that made it. From the next block onward the inflow counts in full.
        uint256 fresh = block.number == lastInflowBlock ? sameBlockInflow : 0;

        return totalReserve - fresh;
    }

    /**
     * @inheritdoc IReserveAccounting
     */
    function freeSlack() external view returns (uint256) {
        // Measured against the effective (same-block-inflow-discounted) reserve, so redemption capacity
        // cannot be expanded by a deposit made in the same transaction (audit H05). Floored at zero: the
        // escrow is bounded by the SETTLED reserve, which can exceed the effective figure right after an
        // inflow.
        uint256 effective = effectiveReserve();

        return effective > committedEscrow ? effective - committedEscrow : 0;
    }
}
