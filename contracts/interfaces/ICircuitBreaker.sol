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
     * @notice Adjusts the deviation threshold {threshold}, the calm period in seconds {calmPeriod}, or the minimum
     *         spacing between trend observations {obsInterval}.
     * @param what Name of the parameter.
     * @param data New value.
     */
    function file(bytes32 what, uint256 data) external;

    /**
     * @notice Determines whether prices are moving abnormally and sets the breaker on or off.
     * @dev Public, anyone can call. Activates above the threshold. Deactivates only once a full calm period has
     *      elapsed since the last above-threshold reading and the deviation is back under the threshold.
     */
    function check() external;

    /**
     * @notice Returns the trailing-average trend anchor price [wad]. Zero until the first observation.
     */
    function trendPrice() external view returns (uint256);

    /**
     * @notice Returns the size of the trailing-average observation ring buffer.
     */
    function OBS_COUNT() external view returns (uint256);

    /**
     * @notice Returns the identifier of the collateral type whose price is being watched.
     */
    function ILK_ID() external view returns (bytes32);

    /**
     * @notice Returns the Oracle Security Module being watched.
     */
    function ORACLE_SECURITY_MODULE() external view returns (IOracleSecurityModule);

    /**
     * @notice Returns the deviation threshold that activates the breaker [wad].
     */
    function threshold() external view returns (uint256);

    /**
     * @notice Returns the calm period in seconds that must elapse after the last above-threshold reading before the
     *         breaker may deactivate.
     */
    function calmPeriod() external view returns (uint256);

    /**
     * @notice Returns the minimum spacing between trend observations in seconds.
     */
    function obsInterval() external view returns (uint256);

    /**
     * @notice Returns the timestamp of the last above-threshold reading while active. Zero when inactive.
     */
    function activatedAt() external view returns (uint256);

    /**
     * @notice Returns the timestamp of the last recorded trend observation.
     */
    function lastObsTimestamp() external view returns (uint256);

    /**
     * @notice Reports whether the breaker is currently active, meaning liquidations are being throttled.
     */
    function active() external view returns (bool);
}
