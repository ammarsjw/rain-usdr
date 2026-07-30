// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/**
 * @dev Indicates a failure with the caller's authorization. For example, missing a required role.
 */
error NotAuthorized();

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
 * @dev Indicates a failure with an unrecognized parameter name in a `file` call.
 */
error UnrecognizedParameter();

/**
 * @dev Indicates that the contract has been shut down and the operation is unavailable.
 */
error NotLive();

/**
 * @dev Indicates that an ilk has already been initialized.
 */
error IlkAlreadyInitialized();
