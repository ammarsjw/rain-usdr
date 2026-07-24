// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/**
 * @title IReserveAccounting.
 * @author Rain Team.
 * @notice Interface for the stable reserve bookkeeper.
 */
interface IReserveAccounting {
    /* ========================== EVENTS ========================== */

    /// @notice Emitted when a recorder is added.
    event AddRecorder(address indexed account);

    /// @notice Emitted when a recorder is removed.
    event RemoveRecorder(address indexed account);

    /// @notice Emitted when a committer is added.
    event AddCommitter(address indexed account);

    /// @notice Emitted when a committer is removed.
    event RemoveCommitter(address indexed account);

    /// @notice Emitted when stablecoins enter the reserve.
    event RecordIncrease(uint256 wad, uint256 totalReserve);

    /// @notice Emitted when stablecoins leave the reserve.
    event RecordDecrease(uint256 wad, uint256 totalReserve);

    /// @notice Emitted when the settlement escrow is updated.
    event UpdateCommittedEscrow(uint256 wad, uint256 freeSlack);

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Returns the total stable reserve (all USDT and USDC held).
     * @return The total reserve [wad].
     */
    function totalReserve() external view returns (uint256);

    /**
     * @notice Returns the amount committed to guaranteed obligations.
     * @return The settlement escrow [wad].
     */
    function committedEscrow() external view returns (uint256);

    /**
     * @notice Allows a contract (a Peg Stability Module) to record reserve movements.
     * @param account Address being granted recorder rights.
     */
    function addRecorder(address account) external;

    /**
     * @notice Revokes a contract's recorder rights.
     * @param account Address losing recorder rights.
     */
    function removeRecorder(address account) external;

    /**
     * @notice Allows a contract (the Solvency Engine) to update the committed escrow.
     * @param account Address being granted committer rights.
     */
    function addCommitter(address account) external;

    /**
     * @notice Revokes a contract's committer rights.
     * @param account Address losing committer rights.
     */
    function removeCommitter(address account) external;

    /**
     * @notice Registers stablecoins entering the reserve (from a PSM mint).
     * @param wad Amount entering [wad].
     */
    function recordIncrease(uint256 wad) external;

    /**
     * @notice Registers stablecoins leaving the reserve (from a PSM redemption or payout).
     * @param wad Amount leaving [wad].
     */
    function recordDecrease(uint256 wad) external;

    /**
     * @notice Sets how much of the reserve is committed to guaranteed obligations.
     * @dev Reverts if the committed amount would exceed the total reserve. Only the Solvency
     *      Engine can call this.
     * @param wad The current worst-case loss [wad].
     */
    function updateCommittedEscrow(uint256 wad) external;

    /**
     * @notice Reports how much reserve is currently free for redemption.
     * @return Total reserve minus committed escrow [wad].
     */
    function freeSlack() external view returns (uint256);
}
