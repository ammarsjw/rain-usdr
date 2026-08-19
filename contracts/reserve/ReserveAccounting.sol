// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

import { IReserveAccounting } from "../interfaces/IReserveAccounting.sol";
import { _COMMITTER_ROLE, _RECORDER_ROLE, _WARD_ROLE } from "../shared/Constants.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title ReserveAccounting
 * @author Rain Team
 * @notice The bookkeeper for the protocol's stable dollars. Tracks the total reserve (all USDT and USDC held), how
 *         much is committed to guaranteed obligations (the settlement escrow), and how much is free (the slack). This
 *         is where the reserve is split so that the same dollar is never promised twice.
 * @dev Only the Solvency Engine may update the committed escrow, and only the Peg Stability Modules may record reserve
 *      movements.
 */
contract ReserveAccounting is IReserveAccounting, AccessControl {
    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc IReserveAccounting
    uint256 public totalReserve;

    /// @inheritdoc IReserveAccounting
    uint256 public committedEscrow;

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

        emit RecordIncrease({ wad: wad, totalReserve: totalReserve });
    }

    /**
     * @inheritdoc IReserveAccounting
     */
    function recordDecrease(uint256 wad) external onlyRole(_RECORDER_ROLE) {
        totalReserve -= wad;

        // The reserve must never drop below the committed escrow: freeSlack() would underflow and every consumer
        // of the split (redemption above all) would revert. The PSM checks freeSlack before recording, so this is
        // defence in depth against any future recorder that does not.
        if (totalReserve < committedEscrow) {
            _revert(ReserveBelowEscrow.selector);
        }

        emit RecordDecrease({ wad: wad, totalReserve: totalReserve });
    }

    /**
     * @inheritdoc IReserveAccounting
     */
    function updateCommittedEscrow(uint256 wad) external onlyRole(_COMMITTER_ROLE) {
        // The committed amount must not exceed the total reserve. This is the solvency guarantee expressed at the
        // accounting level.
        if (wad > totalReserve) {
            _revert(EscrowExceedsReserve.selector);
        }

        committedEscrow = wad;

        emit UpdateCommittedEscrow({ wad: wad, freeSlack: totalReserve - wad });
    }

    /**
     * @inheritdoc IReserveAccounting
     */
    function freeSlack() external view returns (uint256) {
        // Never negative, because `updateCommittedEscrow` forbids committing more than exists.
        return totalReserve - committedEscrow;
    }
}
