// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/**
 * @title IGovernor.
 * @author Rain Team.
 * @notice Interface for the timelocked parameter changer and emergency pause.
 */
interface IGovernor {
    /* ========================== EVENTS ========================== */

    /// @notice Emitted when a parameter is updated.
    event File(bytes32 indexed what, uint256 data);

    /// @notice Emitted when a change is scheduled.
    event Schedule(uint256 indexed id, address indexed target, bytes data, uint256 eta);

    /// @notice Emitted when a scheduled change is executed.
    event Execute(uint256 indexed id);

    /// @notice Emitted when a scheduled change is cancelled.
    event Cancel(uint256 indexed id);

    /// @notice Emitted when the emergency pause begins.
    event Pause(bytes32 scope, uint256 pausedAt);

    /// @notice Emitted when the pause is lifted.
    event Unpause();

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Adjusts the timelock delay ("delay").
     * @param what Name of the parameter.
     * @param data New value in seconds.
     */
    function file(bytes32 what, uint256 data) external;

    /**
     * @notice Queues a parameter change (or a new collateral addition) to take effect after
     *         the timelock delay.
     * @param target Contract and setting to change.
     * @param data Encoded calldata of the change.
     * @return id Identifier of the scheduled change.
     */
    function schedule(address target, bytes calldata data) external returns (uint256 id);

    /**
     * @notice Applies a previously scheduled change after its delay has passed.
     * @dev Reverts if called early, if not scheduled, if cancelled, or if already executed.
     * @param id Identifier of the scheduled change.
     * @return out Return data of the executed call.
     */
    function execute(uint256 id) external returns (bytes memory out);

    /**
     * @notice Removes a queued change before it executes.
     * @param id Identifier of the scheduled change.
     */
    function cancel(uint256 id) external;

    /**
     * @notice Halts sensitive operations during an emergency.
     * @dev The scope is declared up front and cannot be widened afterward. Auto-expires after
     *      72 hours.
     * @param scope Which operations to pause.
     */
    function pause(bytes32 scope) external;

    /**
     * @notice Lifts the pause. Governance may lift it early; after 72 hours anyone may.
     */
    function unpause() external;
}
