// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @title IGovernor
 * @author Rain Team
 * @notice Interface for the timelocked parameter changer and emergency pause.
 */
interface IGovernor {
    /* ========================== TYPES ========================== */

    /**
     * @notice A scheduled parameter change.
     * @param target Contract to call.
     * @param data Encoded calldata of the change.
     * @param eta Earliest execution time.
     * @param executed Whether the change has already been executed.
     * @param cancelled Whether the change has been cancelled.
     */
    struct Change {
        address target;
        bytes data;
        uint256 eta;
        bool executed;
        bool cancelled;
    }

    /* ========================== EVENTS ========================== */

    /**
     * @dev Emitted when a parameter is updated.
     * @param what Name of the parameter.
     * @param data New value in seconds.
     */
    event File(bytes32 indexed what, uint256 data);

    /**
     * @dev Emitted when a change is scheduled.
     * @param id Identifier of the scheduled change.
     * @param target Contract to call.
     * @param data Encoded calldata of the change.
     * @param eta Earliest execution time.
     */
    event Schedule(uint256 indexed id, address indexed target, bytes data, uint256 eta);

    /**
     * @dev Emitted when a scheduled change is executed.
     * @param id Identifier of the executed change.
     */
    event Execute(uint256 indexed id);

    /**
     * @dev Emitted when a scheduled change is cancelled.
     * @param id Identifier of the cancelled change.
     */
    event Cancel(uint256 indexed id);

    /**
     * @dev Emitted when the emergency pause begins.
     * @param scope Which operations were paused.
     * @param pausedAt Timestamp when the pause began.
     */
    event Pause(bytes32 scope, uint256 pausedAt);

    /**
     * @dev Emitted when the pause is lifted.
     */
    event Unpause();

    /* ========================== ERRORS ========================== */

    /**
     * @dev Indicates that no change has been scheduled for the given id.
     */
    error NotScheduled();

    /**
     * @dev Indicates that the change has been cancelled.
     */
    error ChangeCancelled();

    /**
     * @dev Indicates that the change has already been executed.
     */
    error AlreadyExecuted();

    /**
     * @dev Indicates that the timelock delay has not yet elapsed.
     */
    error DelayNotElapsed();

    /**
     * @dev Indicates that the scheduled call reverted during execution.
     */
    error ExecutionFailed();

    /**
     * @dev Indicates that the system is already paused.
     */
    error AlreadyPaused();

    /**
     * @dev Indicates that the system is not paused.
     */
    error NotPaused();

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Adjusts the timelock delay {delay}.
     * @param what Name of the parameter.
     * @param data New value in seconds.
     */
    function file(bytes32 what, uint256 data) external;

    /**
     * @notice Queues a parameter change or a new collateral addition to take effect after the timelock delay.
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
     * @dev The scope is declared up front and cannot be widened afterward. Auto-expires after 72 hours.
     * @param scope Which operations to pause.
     */
    function pause(bytes32 scope) external;

    /**
     * @notice Lifts the pause. Governance may lift it early. After 72 hours anyone may.
     */
    function unpause() external;

    /**
     * @notice Returns the maximum pause duration in seconds (72 hours), after which anyone can un-pause.
     */
    function PAUSE_MAX() external view returns (uint256);

    /**
     * @notice Returns the scope of the current pause, fixed at the moment of pausing.
     */
    function pauseScope() external view returns (bytes32);

    /**
     * @notice Returns the mandatory timelock delay in seconds.
     */
    function delay() external view returns (uint256);

    /**
     * @notice Returns the timestamp when the current pause began.
     */
    function pausedAt() external view returns (uint256);

    /**
     * @notice Returns the change id counter, the number of changes scheduled so far.
     */
    function changeCount() external view returns (uint256);

    /**
     * @notice Returns whether the system is currently paused.
     */
    function paused() external view returns (bool);

    /**
     * @notice Returns a scheduled change's details.
     * @param changeId Identifier of the scheduled change.
     * @return target Contract to call.
     * @return data Encoded calldata of the change.
     * @return eta Earliest execution time.
     * @return executed Whether the change has already been executed.
     * @return cancelled Whether the change has been cancelled.
     */
    function changes(
        uint256 changeId
    ) external view returns (address target, bytes memory data, uint256 eta, bool executed, bool cancelled);
}
