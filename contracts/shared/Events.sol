// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/* ========================== FREE EVENTS ========================== */

/**
 * @dev Emitted when a contract is shut down.
 */
event Cage();

/**
 * @dev Emitted when stability fees are accrued for a collateral type.
 * @param ilkId Identifier of the collateral type.
 * @param rate New debt multiplier after accrual [ray].
 * @param rad Fee amount credited to the fee recipient [rad].
 */
event Drip(bytes32 indexed ilkId, uint256 rate, uint256 rad);
