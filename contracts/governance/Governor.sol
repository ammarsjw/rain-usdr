// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { Auth } from "../extensions/Auth.sol";
import { IGovernor } from "../interfaces/IGovernor.sol";
import { _WARD_ROLE } from "../shared/Constants.sol";
import { InvalidAddress, NotAuthorized, UnrecognizedParameter } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title Governor
 * @author Rain Team
 * @notice The controlled way to change the protocol's adjustable settings. Every change waits
 *         out a mandatory delay before it can take effect, giving the community time to review.
 *         Also holds the emergency pause. It can never touch the immutable core — only the risk
 *         parameters.
 * @dev Based on MakerDAO's Spell and Pause. The pause auto-expires after 72 hours and its scope
 *      is fixed at the moment of pausing.
 */
contract Governor is IGovernor, Auth {
    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc IGovernor
    mapping(uint256 changeId => Change change) public changes;

    /// @inheritdoc IGovernor
    uint256 public delay;

    /// @inheritdoc IGovernor
    uint256 public constant PAUSE_MAX = 72 hours;

    /// @inheritdoc IGovernor
    bool public paused;

    /// @inheritdoc IGovernor
    uint256 public pausedAt;

    /// @inheritdoc IGovernor
    bytes32 public pauseScope;

    /// @inheritdoc IGovernor
    uint256 public changeCount;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the governor with its timelock delay.
     * @param delay_ The mandatory delay in seconds.
     */
    constructor(uint256 delay_) {
        delay = delay_;
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IGovernor
     */
    function file(bytes32 what, uint256 data) external onlyRole(_WARD_ROLE) {
        if (what == "delay") {
            delay = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, data: data });
    }

    /**
     * @inheritdoc IGovernor
     */
    function schedule(address target, bytes calldata data) external onlyRole(_WARD_ROLE) returns (uint256 id) {
        if (target == address(0)) {
            _revert(InvalidAddress.selector);
        }

        id = ++changeCount;

        // The change is queued with an execution time of now plus the required delay. Its details are public
        // immediately, visible on the dashboard.
        changes[id] = Change({
            target: target,
            data: data,
            eta: block.timestamp + delay,
            executed: false,
            cancelled: false
        });

        emit Schedule({ id: id, target: target, data: data, eta: block.timestamp + delay });
    }

    /**
     * @inheritdoc IGovernor
     */
    function execute(uint256 id) external returns (bytes memory out) {
        Change storage change = changes[id];

        // The change must have been scheduled.
        require(change.target != address(0), "Governor/not-scheduled");
        // The change must not have been cancelled.
        require(!change.cancelled, "Governor/cancelled");
        // The change must not have already been executed.
        require(!change.executed, "Governor/already-executed");
        // The delay must have fully elapsed.
        require(block.timestamp >= change.eta, "Governor/delay-not-elapsed");

        change.executed = true;

        bool success;
        (success, out) = change.target.call(change.data);
        require(success, "Governor/execution-failed");

        emit Execute({ id: id });
    }

    /**
     * @inheritdoc IGovernor
     */
    function cancel(uint256 id) external onlyRole(_WARD_ROLE) {
        Change storage change = changes[id];

        require(change.target != address(0), "Governor/not-scheduled");
        require(!change.executed, "Governor/already-executed");

        change.cancelled = true;

        emit Cancel({ id: id });
    }

    /**
     * @inheritdoc IGovernor
     */
    function pause(bytes32 scope) external onlyRole(_WARD_ROLE) {
        // The system must not already be paused.
        require(!paused, "Governor/already-paused");

        // The scope is fixed at the moment of pausing and cannot be widened afterward.
        paused = true;
        pausedAt = block.timestamp;
        pauseScope = scope;

        emit Pause({ scope: scope, pausedAt: block.timestamp });
    }

    /**
     * @inheritdoc IGovernor
     */
    function unpause() external {
        require(paused, "Governor/not-paused");

        // Once 72 hours have passed since the pause began, anyone can lift it — no governance action required.
        // Before that, only governance can lift it early.
        if (block.timestamp < pausedAt + PAUSE_MAX) {
            if (!hasRole(_WARD_ROLE, msg.sender)) {
                _revert(NotAuthorized.selector);
            }
        }

        paused = false;
        pausedAt = 0;
        pauseScope = bytes32(0);

        emit Unpause();
    }
}
