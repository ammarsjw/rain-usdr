// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/* ========================== FREE VARIABLES ========================== */

/// @dev Fixed point scalar with 18 decimals of precision. Used for token quantities.
uint256 constant _WAD = 10 ** 18;

/// @dev Fixed point scalar with 27 decimals of precision. Used for rates and price factors.
uint256 constant _RAY = 10 ** 27;

/// @dev Fixed point scalar with 45 decimals of precision. Used for internal debt units (wad * ray).
uint256 constant _RAD = 10 ** 45;

/// @dev Reserved ilk identifier for USDR itself in the Collateral Adapter. USDR is not a collateral type in the
///      Vault Engine; this id only selects the mint/burn code path.
bytes32 constant _USDR_ILK = "USDR";

// keccak256("WARD_ROLE")
/// @dev Core authorization role. A holder may `rely`/`deny`.
bytes32 constant _WARD_ROLE = 0xbafcd51963b0d7b3a3da265619edae46625d8c081f4c6ac796f4531050ac941f;

// keccak256("RECORDER_ROLE")
/// @dev Grants the right to record reserve movements.
bytes32 constant _RECORDER_ROLE = 0xf996da754c790e95d5c7ca3330cfcad529487fe9d1d8edb7afc65076fdf9adb4;

// keccak256("COMMITTER_ROLE")
/// @dev Grants the right to update the committed escrow.
bytes32 constant _COMMITTER_ROLE = 0x0b60b5d7f7e737e4561eecda7c6a01e19e626c495c26e6f45e5b255f76a20106;

// keccak256("READER_ROLE")
/// @dev Grants price read access to the Oracle Security Module.
bytes32 constant _READER_ROLE = 0xc757f485a2bb9eadbad5c86f7618c2a7a2ecb41b29f8610fb0e8bea3ed5ab6cf;
