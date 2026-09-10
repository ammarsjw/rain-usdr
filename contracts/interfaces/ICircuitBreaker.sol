// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { IOracleSecurityModule } from "./IOracleSecurityModule.sol";
import { IVaultEngine } from "./IVaultEngine.sol";

/**
 * @title ICircuitBreaker
 * @author Rain Team
 * @notice Interface for the contract that slows liquidations when any watched collateral's price moves suspiciously
 *         fast.
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
     * @dev Emitted when an ilk is added to the watched set.
     * @param ilkId Identifier of the collateral type.
     */
    event AddIlk(bytes32 indexed ilkId);

    /**
     * @dev Emitted when an ilk is removed from the watched set.
     * @param ilkId Identifier of the collateral type.
     */
    event RemoveIlk(bytes32 indexed ilkId);

    /**
     * @dev Emitted when the breaker activates.
     * @param ilkId Identifier of the collateral type whose deviation triggered activation.
     * @param deviation The relative price deviation that triggered activation [wad].
     */
    event Activated(bytes32 indexed ilkId, uint256 deviation);

    /**
     * @dev Emitted when the breaker deactivates.
     */
    event Deactivated();

    /**
     * @dev Emitted on every check, for the dashboard.
     * @param worstIlk Identifier of the collateral type with the largest deviation this check. Zero when no watched
     *        ilk produced a readable price.
     * @param maxDeviation The largest relative price deviation observed across the watched set [wad].
     * @param active Whether the breaker is active after the check.
     */
    event Checked(bytes32 indexed worstIlk, uint256 maxDeviation, bool active);

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Adjusts the deviation threshold {threshold}, the calm period in seconds {calmPeriod}, or the minimum
     *         spacing between trend observations {obsInterval}.
     * @param what Name of the parameter.
     * @param data New value.
     */
    function file(bytes32 what, uint256 data) external;

    /**
     * @notice Adds a collateral type to the watched set.
     * @dev The ilk must be initialized in the Vault Engine.
     * @param ilkId Identifier of the collateral type.
     */
    function addIlk(bytes32 ilkId) external;

    /**
     * @notice Removes a collateral type from the watched set and clears its trend state.
     * @param ilkId Identifier of the collateral type.
     */
    function removeIlk(bytes32 ilkId) external;

    /**
     * @notice Determines whether any watched collateral's price is moving abnormally and sets the breaker on or off.
     * @dev Public, anyone can call. Iterates the watched set, takes the maximum deviation from each ilk's own trend,
     *      and activates above the threshold. Deactivates only once a full calm period has elapsed since the last
     *      above-threshold reading and every deviation is back under the threshold. Ilks with unavailable prices are
     *      skipped (fail-open): a dark feed is not manipulation and must not freeze liquidations.
     */
    function check() external;

    /**
     * @notice Returns the number of watched collateral types.
     */
    function ilkCount() external view returns (uint256);

    /**
     * @notice Returns a collateral type's trailing-average trend anchor price [wad]. Zero until its first observation.
     * @param ilkId Identifier of the collateral type.
     */
    function trendPrice(bytes32 ilkId) external view returns (uint256);

    /**
     * @notice Returns the size of each ilk's trailing-average observation ring buffer.
     */
    function OBS_COUNT() external view returns (uint256);

    /**
     * @notice Returns the Vault Engine used to validate watched ilks.
     */
    function VAULT_ENGINE() external view returns (IVaultEngine);

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
     * @notice Returns the timestamp of the last recorded trend observation across the watched set.
     */
    function lastObsTimestamp() external view returns (uint256);

    /**
     * @notice Reports whether the breaker is currently active, meaning liquidations are being throttled globally.
     */
    function active() external view returns (bool);

    /**
     * @notice Returns the watched collateral type at an index.
     * @param index Position in the watched set.
     * @return ilkId Identifier of the collateral type.
     */
    function watchedIlks(uint256 index) external view returns (bytes32 ilkId);

    /**
     * @notice Reports whether a collateral type is in the watched set.
     * @param ilkId Identifier of the collateral type.
     */
    function isWatched(bytes32 ilkId) external view returns (bool);
}
