// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/* ========================== FREE ERRORS ========================== */

/**
 * @dev Indicates that an ilk has already been initialized.
 */
error IlkAlreadyInitialized();

/**
 * @dev Indicates a failure with an address, for example, `address(0)`.
 */
error InvalidAddress();

/**
 * @dev Indicates a failure with an amount. For example, `0`.
 */
error InvalidAmount();

/**
 * @dev Indicates a failure with an assignment. For example, `stateVariable == newVariable`.
 */
error InvalidAssignment();

/**
 * @dev Indicates a failure with a bytes. For example, `bytes32(0)`.
 */
error InvalidBytes();

/**
 * @dev Indicates a failure with the caller's authorization. For example, missing a required role.
 */
error NotAuthorized();

/**
 * @dev Indicates that the contract has been shut down and the operation is unavailable.
 */
error NotLive();

/**
 * @dev Indicates a failure with an unrecognized parameter name in a `file` call.
 */
error UnrecognizedParameter();

/**
 * @dev Indicates that the Governor's emergency pause is active and the operation is unavailable.
 */
error SystemPaused();

/**
 * @dev Indicates that a stability fee `duty` value below RAY (a negative rate) was filed.
 */
error InvalidDuty();

/**
 * @dev Indicates that stability fees accrued while no fee recipient is configured to receive them.
 */
error FeeRecipientNotSet();

/**
 * @dev Indicates that the solvency invariant is breached and reserve-decreasing operations are gated.
 */
error SolvencyGateActive();
