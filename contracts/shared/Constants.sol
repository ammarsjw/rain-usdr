// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/* ========================== FREE VARIABLES ========================== */

/// @dev Reserved ilk identifier for USDR itself in the Collateral Adapter. USDR is not a collateral type in the Vault
///      Engine, so this id only selects the mint and burn code path.
bytes32 constant _USDR_ILK = "USDR";

// keccak256("BURNER_ROLE")
/// @dev Grants the right to burn USDR from any address without an allowance. Held only by the Collateral Adapter.
bytes32 constant _BURNER_ROLE = 0x3c11d16cbaffd01df69ce1c404f6340ee057498f5f00246190ea54220576a848;

// keccak256("COMMITTER_ROLE")
/// @dev Grants the right to update the committed escrow.
bytes32 constant _COMMITTER_ROLE = 0x0b60b5d7f7e737e4561eecda7c6a01e19e626c495c26e6f45e5b255f76a20106;

// keccak256("READER_ROLE")
/// @dev Grants price read access to the Oracle Security Module.
bytes32 constant _READER_ROLE = 0xc757f485a2bb9eadbad5c86f7618c2a7a2ecb41b29f8610fb0e8bea3ed5ab6cf;

// keccak256("RECORDER_ROLE")
/// @dev Grants the right to record reserve movements.
bytes32 constant _RECORDER_ROLE = 0xf996da754c790e95d5c7ca3330cfcad529487fe9d1d8edb7afc65076fdf9adb4;

// keccak256("WARD_ROLE")
/// @dev Core authorization role.
bytes32 constant _WARD_ROLE = 0xbafcd51963b0d7b3a3da265619edae46625d8c081f4c6ac796f4531050ac941f;

/// @dev Pause bit: blocks {VaultEngine.frob}.
uint256 constant _PAUSE_FROB = 1 << 0;

/// @dev Pause bit: blocks {PegStabilityModule} mint and redeem.
uint256 constant _PAUSE_PSM = 1 << 1;

/// @dev Pause bit: blocks {LiquidationTrigger.bark}.
uint256 constant _PAUSE_BARK = 1 << 2;

/// @dev Pause bit: blocks {DutchAuction} take and redo.
uint256 constant _PAUSE_AUCTION = 1 << 3;

/// @dev Convenience mask that pauses every gated module.
uint256 constant _PAUSE_ALL = _PAUSE_FROB | _PAUSE_PSM | _PAUSE_BARK | _PAUSE_AUCTION;

/// @dev Fixed point scalar with 18 decimals of precision. Used for token quantities.
uint256 constant _WAD = 10 ** 18;

/// @dev Fixed point scalar with 27 decimals of precision. Used for rates and price factors.
uint256 constant _RAY = 10 ** 27;

/// @dev Fixed point scalar with 45 decimals of precision. Used for internal debt units (wad times ray).
uint256 constant _RAD = 10 ** 45;
