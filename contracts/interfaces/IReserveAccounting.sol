// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @title IReserveAccounting
 * @author Rain Team
 * @notice Interface for the stable reserve bookkeeper.
 */
interface IReserveAccounting {
    /* ========================== EVENTS ========================== */

    /**
     * @dev Emitted when stablecoins enter the reserve.
     * @param wad Amount entering [wad].
     * @param totalReserve The total reserve after the increase [wad].
     */
    event RecordIncrease(uint256 wad, uint256 totalReserve);

    /**
     * @dev Emitted when stablecoins leave the reserve.
     * @param wad Amount leaving [wad].
     * @param totalReserve The total reserve after the decrease [wad].
     */
    event RecordDecrease(uint256 wad, uint256 totalReserve);

    /**
     * @dev Emitted when the settlement escrow is updated.
     * @param wad The committed escrow amount [wad].
     * @param freeSlack The free slack after the update [wad].
     */
    event UpdateCommittedEscrow(uint256 wad, uint256 freeSlack);

    /* ========================== ERRORS ========================== */

    /**
     * @dev Indicates that the committed escrow would exceed the total reserve.
     */
    error EscrowExceedsReserve();

    /**
     * @dev Indicates that a decrease would drop the total reserve below the committed escrow.
     */
    error ReserveBelowEscrow();

    /* ========================== FUNCTIONS ========================== */

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
     * @dev Reverts if the committed amount would exceed the total reserve. Only the Solvency Engine can call
     *      this.
     * @param wad The current worst-case loss [wad].
     */
    function updateCommittedEscrow(uint256 wad) external;

    /**
     * @notice Reports how much reserve is currently free for redemption.
     * @return slack Total reserve minus committed escrow [wad].
     */
    function freeSlack() external view returns (uint256);

    /**
     * @notice Returns the total stable reserve (all USDT and USDC held) [wad].
     */
    function totalReserve() external view returns (uint256);

    /**
     * @notice Returns the amount committed to guaranteed obligations, the settlement escrow [wad].
     */
    function committedEscrow() external view returns (uint256);
}
