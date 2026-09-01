// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

import { IGovernor } from "../interfaces/IGovernor.sol";
import { _WARD_ROLE } from "../shared/Constants.sol";
import { InvalidAddress, InvalidAmount, NotAuthorized } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title Governor
 * @author Rain Team
 * @notice The controlled way to change the protocol's adjustable settings. Every change waits out a mandatory delay
 *         before it can take effect, giving the community time to review. Also holds the emergency pause. It can never
 *         touch the immutable core, only the risk parameters.
 * @dev The timelock delay is immutable: it is fixed at construction and can never be changed, so the timelock can
 *      never be shortened or removed by a compromised governance key. The pause auto-expires after 72 hours, that is
 *      {paused} returns false once the window elapses even without an {unpause} call. The pause is deliberately
 *      UNSCOPED: every consumer reads the same boolean, so a pause always halts everything that is pausable. A scoped
 *      pause was considered and removed (audit M-3) — recording a scope that no consumer enforces gives governance a
 *      scalpel-shaped handle on a sledgehammer, which is how a "PSM-only" pause silently freezes liquidations too.
 */
contract Governor is IGovernor, AccessControl {
    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc IGovernor
    uint256 public constant PAUSE_MAX = 72 hours;

    /// @inheritdoc IGovernor
    uint256 public immutable delay;

    /// @inheritdoc IGovernor
    uint256 public pausedAt;

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

        delay = delay_;
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
     * @dev A scheduled change can be cancelled at any moment up to its execution, including after its delay has
     *      elapsed. Watchers should treat a queued change as final only once executed.
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
    function pause() external onlyRole(_WARD_ROLE) {
        // The system must not already be paused.
        if (paused()) {
            _revert(AlreadyPaused.selector);
        }

        // NOTE: a ward can re-pause after expiry (or after an early unpause), chaining windows beyond 72 hours. The
        // auto-expiry bounds a SINGLE pause, not governance's total authority; repeated pauses are visible on-chain
        // and are a matter for governance process, not contract code.
        _paused = true;
        pausedAt = block.timestamp;

        emit Pause({ pausedAt: block.timestamp });
    }

    /**
     * @inheritdoc IGovernor
     */
    function unpause() external {
        // Checked against the RAW flag, not the auto-expiring view: after the window expires the system already reads
        // unpaused everywhere, but the stale storage must still be clearable.
        if (!_paused) {
            _revert(NotPaused.selector);
        }

        // Once 72 hours have passed since the pause began, anyone can lift it with no governance action required.
        // Before that, only governance can lift it early.
        if (block.timestamp < pausedAt + PAUSE_MAX) {
            if (!hasRole(_WARD_ROLE, msg.sender)) {
                _revert(NotAuthorized.selector);
            }
        }

        _paused = false;
        pausedAt = 0;

        emit Unpause();
    }

    /**
     * @inheritdoc IGovernor
     */
    function paused() public view returns (bool) {
        // The pause auto-expires after PAUSE_MAX: once the window elapses the system is unpaused for every consumer
        // even if nobody has called {unpause} to clear the storage. This makes the "72h auto-expiry" real rather than
        // a relabelling of who may call unpause.
        return _paused && block.timestamp < pausedAt + PAUSE_MAX;
    }
}
