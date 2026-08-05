// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { IOracleSecurityModule } from "./IOracleSecurityModule.sol";

/**
 * @title ICircuitBreaker
 * @author Rain Team
 * @notice Interface for the contract that slows liquidations when the price moves suspiciously fast.
 */
interface ICircuitBreaker {
    /* ========================== EVENTS ========================== */

    /**
     * @dev Emitted when a parameter is updated.
     * @param what Name of the parameter.
     * @param data New value.
     */
    event File(bytes32 indexed what, uint256 data);

    /**
     * @dev Emitted when the breaker activates.
     * @param deviation The relative price deviation that triggered activation [wad].
     */
    event Activated(uint256 deviation);

    /**
     * @dev Emitted when the breaker deactivates.
     */
    event Deactivated();

    /**
     * @dev Emitted on every check, for the dashboard.
     * @param deviation The relative price deviation observed [wad].
     * @param active Whether the breaker is active after the check.
     */
    event Checked(uint256 deviation, bool active);

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Returns the trend window in seconds (one hour).
     */
    function TREND_WINDOW() external view returns (uint256);

    /**
     * @notice Returns the Oracle Security Module being watched.
     */
    function PIP() external view returns (IOracleSecurityModule);

    /**
     * @notice Returns the identifier of the collateral type whose price is being watched.
     */
    function ILK_ID() external view returns (bytes32);

    /**
     * @notice Returns the deviation threshold that activates the breaker [wad].
     */
    function threshold() external view returns (uint256);

    /**
     * @notice Returns the number of consecutive calm blocks required to deactivate the breaker.
     */
    function calmBlocks() external view returns (uint256);

    /**
     * @notice Returns the one-hour trend anchor price [wad].
     */
    function trendPrice() external view returns (uint256);

    /**
     * @notice Returns the timestamp when the trend anchor was recorded.
     */
    function trendTimestamp() external view returns (uint256);

    /**
     * @notice Returns the number of consecutive calm blocks observed while active.
     */
    function calmCount() external view returns (uint256);

    /**
     * @notice Returns the last block in which the breaker was checked.
     */
    function lastCheckedBlock() external view returns (uint256);

    /**
     * @notice Reports whether the breaker is currently active, meaning liquidations are being throttled.
     */
    function active() external view returns (bool);

    /**
     * @notice Adjusts the deviation threshold {threshold} or the number of calm blocks needed to reset {calmBlocks}.
     * @param what Name of the parameter.
     * @param data New value.
     */
    function file(bytes32 what, uint256 data) external;

    /**
     * @notice Determines whether prices are moving abnormally and sets the breaker on or off.
     * @dev Public, anyone can call. Activates above the threshold. Deactivates after the required consecutive calm
     *      blocks.
     */
    function check() external;
}
