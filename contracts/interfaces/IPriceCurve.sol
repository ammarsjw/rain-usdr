// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/**
 * @title IPriceCurve
 * @author Rain Team
 * @notice Interface for the falling auction price calculator.
 */
interface IPriceCurve {
    /* ========================== EVENTS ========================== */

    /// @notice Emitted when a parameter is updated.
    event File(bytes32 indexed what, uint256 data);

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Adjusts the auction lifetime ("tau").
     * @param what Name of the parameter.
     * @param data New value in seconds.
     */
    function file(bytes32 what, uint256 data) external;

    /**
     * @notice Returns the auction price right now.
     * @param top The starting price [ray].
     * @param dur Seconds elapsed since the auction began.
     * @return The current price [ray]. Zero once the lifetime has fully elapsed.
     */
    function price(uint256 top, uint256 dur) external view returns (uint256);
}
