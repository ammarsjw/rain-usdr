// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/* ========================== FREE VARIABLES ========================== */

/// @dev Fixed point scalar with 18 decimals of precision. Used for token quantities.
uint256 constant WAD = 10 ** 18;

/// @dev Fixed point scalar with 27 decimals of precision. Used for rates and price factors.
uint256 constant RAY = 10 ** 27;

/// @dev Fixed point scalar with 45 decimals of precision. Used for internal debt units (wad * ray).
uint256 constant RAD = 10 ** 45;

/// @dev Reserved ilk identifier for USDR itself in the Collateral Adapter. USDR is not a
///      collateral type in the Vault Engine; this id only selects the mint/burn code path.
bytes32 constant USDR_ILK = "USDR";

/// @dev Core authorization role. Replaces the legacy `wards` mapping; a holder may `rely`/`deny`.
bytes32 constant WARD_ROLE = keccak256("WARD_ROLE");

/// @dev Grants the right to record reserve movements (held by the Peg Stability Modules).
bytes32 constant RECORDER_ROLE = keccak256("RECORDER_ROLE");

/// @dev Grants the right to update the committed escrow (held by the Solvency Engine).
bytes32 constant COMMITTER_ROLE = keccak256("COMMITTER_ROLE");

/// @dev Grants price read access to the Oracle Security Module (the legacy `bud` whitelist).
bytes32 constant READER_ROLE = keccak256("READER_ROLE");
