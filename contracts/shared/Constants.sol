// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/* ========================== FREE VARIABLES ========================== */

/// @dev Fixed point scalar with 18 decimals of precision. Used for token quantities.
uint256 constant WAD = 10 ** 18;

/// @dev Fixed point scalar with 27 decimals of precision. Used for rates and price factors.
uint256 constant RAY = 10 ** 27;

/// @dev Fixed point scalar with 45 decimals of precision. Used for internal debt units (wad * ray).
uint256 constant RAD = 10 ** 45;
