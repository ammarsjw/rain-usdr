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
     * @param pausedAt Timestamp when the pause began.
     * @param scope Bitmask of modules halted for this pause window.
     */
    event Pause(uint256 pausedAt, uint256 scope);

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
     * @notice Halts the modules selected by `scope` during an emergency.
     * @dev Auto-expires after 72 hours. A new pause cannot start until {PAUSE_COOLDOWN} has elapsed since the
     *      previous pause ended. `scope` is a bitmask of module bits (`_PAUSE_FROB`, `_PAUSE_PSM`,
     *      `_PAUSE_BARK`, `_PAUSE_AUCTION`, or `_PAUSE_ALL`).
     * @param scope Bitmask of modules to pause.
     */
    function pause(uint256 scope) external;

    /**
     * @notice Lifts the pause. Governance may lift it early. After 72 hours anyone may.
     */
    function unpause() external;

    /**
     * @notice Returns whether the pause window is active AND includes the given module bit(s).
     * @param scope Module bit or mask to test against {pauseScope}.
     */
    function paused(uint256 scope) external view returns (bool);

    /**
     * @notice Returns whether the pause window is currently active. Auto-expires 72 hours after it began.
     */
    function paused() external view returns (bool);

    /**
     * @notice Returns the maximum pause duration in seconds, after which anyone can un-pause.
     */
    function PAUSE_MAX() external view returns (uint256);

    /**
     * @notice Returns the mandatory cooldown between the end of one pause and the start of the next.
     */
    function PAUSE_COOLDOWN() external view returns (uint256);

    /**
     * @notice Returns the mandatory timelock delay in seconds.
     */
    function DELAY() external view returns (uint256);

    /**
     * @notice Returns the timestamp when the current pause began.
     */
    function pausedAt() external view returns (uint256);

    /**
     * @notice Returns the module bitmask of the current (or last) pause.
     */
    function pauseScope() external view returns (uint256);

    /**
     * @notice Returns when the previous pause window ended (early unpause or auto-expiry). Zero before any
     *         pause.
     */
    function lastPauseEnd() external view returns (uint256);

    /**
     * @notice Returns the change id counter, the number of changes scheduled so far.
     */
    function changeCount() external view returns (uint256);

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
