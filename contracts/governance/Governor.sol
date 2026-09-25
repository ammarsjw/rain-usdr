// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

import { IGovernor } from "../interfaces/IGovernor.sol";
import { _WARD_ROLE } from "../shared/Constants.sol";
import { InvalidAddress, InvalidAmount, NotAuthorized, PauseCooldownActive } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title Governor
 * @author Rain Team
 * @notice The controlled way to change the protocol's adjustable settings. Every change waits out a mandatory
 *         delay before it can take effect, giving the community time to review. Also holds the emergency
 *         pause. It can never touch the immutable core, only the risk parameters.
 * @dev The timelock delay is immutable: it is fixed at construction and can never be changed, so the timelock
 *      can never be shortened or removed by a compromised governance key. The pause auto-expires after 72
 *      hours, that is {paused} returns false once the window elapses even without an {unpause} call. Pauses
 *      are SCOPED: consumers check {paused(scope)} against the bitmask recorded at pause time, so a PSM-only
 *      incident can leave liquidations running. A cooldown equal to {PAUSE_MAX} after each pause ends
 *      prevents a ward from chaining windows into an unbounded halt.
 */
contract Governor is IGovernor, AccessControl {
    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc IGovernor
    uint256 public constant PAUSE_MAX = 259_200;

    /// @inheritdoc IGovernor
    uint256 public constant PAUSE_COOLDOWN = 259_200;

    /// @inheritdoc IGovernor
    uint256 public immutable DELAY;

    /// @inheritdoc IGovernor
    uint256 public pausedAt;

    /// @inheritdoc IGovernor
    uint256 public pauseScope;

    /// @inheritdoc IGovernor
    uint256 public lastPauseEnd;

    /// @inheritdoc IGovernor
    uint256 public changeCount;

    /// @dev Raw pause flag. Read through {paused}, which also applies the 72-hour auto-expiry.
    bool private _paused;

    /// @inheritdoc IGovernor
    mapping(uint256 changeId => Change change) public changes;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the governor with its timelock delay.
     * @param delay_ The mandatory delay in seconds.
     */
    constructor(uint256 delay_) {
        if (delay_ == 0) {
            _revert(InvalidAmount.selector);
        }

        _setRoleAdmin(_WARD_ROLE, _WARD_ROLE);

        _grantRole(_WARD_ROLE, msg.sender);

        DELAY = delay_;
    }

    /* ========================== FUNCTIONS ========================== */

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
            eta: block.timestamp + DELAY,
            executed: false,
            cancelled: false
        });

        emit Schedule({ id: id, target: target, data: data, eta: block.timestamp + DELAY });
    }

    /**
     * @inheritdoc IGovernor
     */
    function execute(uint256 id) external returns (bytes memory out) {
        Change storage change = changes[id];

        // The change must have been scheduled.
        if (change.target == address(0)) {
            _revert(NotScheduled.selector);
        }

        // The change must not have been cancelled.
        if (change.cancelled) {
            _revert(ChangeCancelled.selector);
        }

        // The change must not have already been executed.
        if (change.executed) {
            _revert(AlreadyExecuted.selector);
        }

        // The delay must have fully elapsed.
        if (block.timestamp < change.eta) {
            _revert(DelayNotElapsed.selector);
        }

        change.executed = true;

        bool success;

        (success, out) = change.target.call(change.data);

        if (!success) {
            _revert(ExecutionFailed.selector);
        }

        emit Execute({ id: id });
    }

    /**
     * @inheritdoc IGovernor
     * @dev A scheduled change can be cancelled at any moment up to its execution, including after its delay
     *      has elapsed. Watchers should treat a queued change as final only once executed.
     */
    function cancel(uint256 id) external onlyRole(_WARD_ROLE) {
        Change storage change = changes[id];

        if (change.target == address(0)) {
            _revert(NotScheduled.selector);
        }

        if (change.executed) {
            _revert(AlreadyExecuted.selector);
        }

        change.cancelled = true;

        emit Cancel({ id: id });
    }

    /**
     * @inheritdoc IGovernor
     */
    function pause(uint256 scope) external onlyRole(_WARD_ROLE) {
        if (scope == 0) {
            _revert(InvalidAmount.selector);
        }

        // The system must not already be in an active pause window.
        if (paused()) {
            _revert(AlreadyPaused.selector);
        }

        // An expired raw flag still needs clearing so cooldown accounting sees the true end of the prior
        // window.
        if (_paused) {
            lastPauseEnd = pausedAt + PAUSE_MAX;
            _paused = false;
            pausedAt = 0;
        }

        if (lastPauseEnd != 0 && block.timestamp < lastPauseEnd + PAUSE_COOLDOWN) {
            _revert(PauseCooldownActive.selector);
        }

        _paused = true;
        pausedAt = block.timestamp;
        pauseScope = scope;

        emit Pause({ pausedAt: block.timestamp, scope: scope });
    }

    /**
     * @inheritdoc IGovernor
     */
    function unpause() external {
        // Checked against the RAW flag, not the auto-expiring view: after the window expires the system
        // already reads unpaused everywhere, but the stale storage must still be clearable.
        if (!_paused) {
            _revert(NotPaused.selector);
        }

        uint256 endedAt;

        // Once 72 hours have passed since the pause began, anyone can lift it with no governance action
        // required. Before that, only governance can lift it early.
        if (block.timestamp < pausedAt + PAUSE_MAX) {
            if (!hasRole(_WARD_ROLE, msg.sender)) {
                _revert(NotAuthorized.selector);
            }

            endedAt = block.timestamp;
        } else {
            endedAt = pausedAt + PAUSE_MAX;
        }

        _paused = false;
        pausedAt = 0;
        lastPauseEnd = endedAt;

        emit Unpause();
    }

    /**
     * @inheritdoc IGovernor
     */
    function paused(uint256 scope) external view returns (bool) {
        return paused() && (pauseScope & scope) != 0;
    }

    /**
     * @inheritdoc IGovernor
     */
    function paused() public view returns (bool) {
        // The pause auto-expires after PAUSE_MAX: once the window elapses the system is unpaused for every
        // consumer even if nobody has called {unpause} to clear the storage. This makes the "72h auto-expiry"
        // real rather than a relabelling of who may call unpause.
        return _paused && block.timestamp < pausedAt + PAUSE_MAX;
    }
}
