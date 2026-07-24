// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IUSDR } from "../interfaces/IUSDR.sol";
import { IUsdrJoin } from "../interfaces/IUsdrJoin.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { AdapterBase } from "./AdapterBase.sol";
import { RAY } from "../shared/Constants.sol";
import { NotLive } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title UsdrJoin.
 * @author Rain Team.
 * @notice The adapter for the USDR token itself — moves USDR between the transferable ERC-20
 *         form and the system's internal accounting.
 * @dev Based on MakerDAO's DaiJoin. Internal balances use 45 decimals (rad); the token uses 18.
 *      Shares its authorization and liveness machinery with the collateral adapter through
 *      {AdapterBase}. Unlike the collateral adapter, this contract mints and burns USDR, so only
 *      this single instance is ever granted USDR mint authority.
 */
contract UsdrJoin is IUsdrJoin, AdapterBase {
    /* ========================== STATE VARIABLES ========================== */

    /// @notice The Vault Engine (core ledger).
    IVaultEngine public immutable vaultEngine;

    /// @notice The USDR token.
    IUSDR public immutable usdr;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the adapter and marks it live.
     * @param vaultEngine_ Address of the Vault Engine.
     * @param usdr_ Address of the USDR token.
     */
    constructor(IVaultEngine vaultEngine_, IUSDR usdr_) {
        vaultEngine = vaultEngine_;
        usdr = usdr_;

        _initAdapter();
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IUsdrJoin
     */
    function join(address user, uint256 wad) external {
        vaultEngine.move(address(this), user, RAY * wad);
        usdr.burn(msg.sender, wad);

        emit Join({ user: user, wad: wad });
    }

    /**
     * @inheritdoc IUsdrJoin
     */
    function exit(address user, uint256 wad) external {
        if (live != 1) {
            _revert(NotLive.selector);
        }

        vaultEngine.move(msg.sender, address(this), RAY * wad);
        usdr.mint(user, wad);

        emit Exit({ user: user, wad: wad });
    }
}
