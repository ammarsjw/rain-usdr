// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { Auth } from "../extensions/Auth.sol";
import { IReserveAccounting } from "../interfaces/IReserveAccounting.sol";
import { _COMMITTER_ROLE, _RECORDER_ROLE, _WARD_ROLE } from "../shared/Constants.sol";

/**
 * @title ReserveAccounting
 * @author Rain Team
 * @notice The bookkeeper for the protocol's stable dollars. Tracks the total reserve (all USDT
 *         and USDC held), how much is committed to guaranteed obligations (the settlement
 *         escrow), and how much is free (the slack). This is where the reserve is split so
 *         that the same dollar is never promised twice.
 * @dev Custom to USDR. Only the Solvency Engine may update the committed escrow, and only the
 *      Peg Stability Modules may record reserve movements.
 */
contract ReserveAccounting is IReserveAccounting, Auth {
    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc IReserveAccounting
    uint256 public totalReserve;

    /// @inheritdoc IReserveAccounting
    uint256 public committedEscrow;

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IReserveAccounting
     */
    function addRecorder(address account) external onlyRole(_WARD_ROLE) {
        _grantRole(_RECORDER_ROLE, account);

        emit AddRecorder({ account: account });
    }

    /**
     * @inheritdoc IReserveAccounting
     */
    function removeRecorder(address account) external onlyRole(_WARD_ROLE) {
        _revokeRole(_RECORDER_ROLE, account);

        emit RemoveRecorder({ account: account });
    }

    /**
     * @inheritdoc IReserveAccounting
     */
    function addCommitter(address account) external onlyRole(_WARD_ROLE) {
        _grantRole(_COMMITTER_ROLE, account);

        emit AddCommitter({ account: account });
    }

    /**
     * @inheritdoc IReserveAccounting
     */
    function removeCommitter(address account) external onlyRole(_WARD_ROLE) {
        _revokeRole(_COMMITTER_ROLE, account);

        emit RemoveCommitter({ account: account });
    }

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

        emit RecordDecrease({ wad: wad, totalReserve: totalReserve });
    }

    /**
     * @inheritdoc IReserveAccounting
     */
    function updateCommittedEscrow(uint256 wad) external onlyRole(_COMMITTER_ROLE) {
        // The committed amount must not exceed the total reserve — this is the solvency guarantee expressed at the
        // accounting level.
        require(wad <= totalReserve, "ReserveAccounting/escrow-exceeds-reserve");

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
