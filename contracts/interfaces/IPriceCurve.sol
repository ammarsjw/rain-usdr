// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @title IPriceCurve
 * @author Rain Team
 * @notice Interface for the falling auction price calculator.
 */
interface IPriceCurve {
    /* ========================== EVENTS ========================== */

    /**
     * @dev Emitted when a parameter is updated.
     * @param what Name of the parameter.
     * @param data New value in seconds.
     */
    event File(bytes32 indexed what, uint256 data);

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Returns the auction lifetime in seconds, how long until the price reaches zero.
     */
    function tau() external view returns (uint256);

    /**
     * @notice Adjusts the auction lifetime: {tau}.
     * @param what Name of the parameter.
     * @param data New value in seconds.
     */
    function file(bytes32 what, uint256 data) external;

    /**
     * @notice Returns the auction price right now.
     * @param top The starting price [ray].
     * @param dur Seconds elapsed since the auction began.
     * @return price The current price [ray]. Zero once the lifetime has fully elapsed.
     */
    function price(uint256 top, uint256 dur) external view returns (uint256);
}
