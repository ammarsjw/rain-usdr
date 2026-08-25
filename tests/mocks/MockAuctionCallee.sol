// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IDutchAuctionCallee } from "../../contracts/interfaces/IDutchAuctionCallee.sol";
import { IVaultEngine } from "../../contracts/interfaces/IVaultEngine.sol";

/**
 * @title MockAuctionCallee
 * @author Rain Team
 * @notice Flash-take callback for tests: receives collateral mid-take and repays from a pre-funded internal balance.
 */
contract MockAuctionCallee is IDutchAuctionCallee {
    IVaultEngine public immutable VAULT_ENGINE;

    uint256 public calls;

    constructor(IVaultEngine vaultEngine_) {
        VAULT_ENGINE = vaultEngine_;
    }

    function clipperCall(address, uint256, uint256, bytes calldata) external {
        // The collateral has already arrived at this point; a real keeper would resell it here.
        ++calls;
    }
}
