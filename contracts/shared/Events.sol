// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/* ========================== FREE EVENTS ========================== */

/**
 * @dev Emitted when an account is granted authorization.
 * @param account Address that gained authorization.
 */
event Rely(address indexed account);

/**
 * @dev Emitted when an account has its authorization revoked.
 * @param account Address that lost authorization.
 */
event Deny(address indexed account);

/**
 * @dev Emitted when a contract is shut down.
 */
event Cage();
