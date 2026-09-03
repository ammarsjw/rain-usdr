// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { VaultEngine } from "../../contracts/core/VaultEngine.sol";

/// @dev Bare VaultEngine deployment used to exercise the unset-feeRecipient error path.
contract VaultEngineHarness is VaultEngine {}
