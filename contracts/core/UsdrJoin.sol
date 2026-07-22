// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IUSDR } from "../interfaces/IUSDR.sol";
import { IUsdrJoin } from "../interfaces/IUsdrJoin.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { RAY } from "../shared/Constants.sol";
import { NotAuthorized, NotLive } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title UsdrJoin.
 * @author Rain Team.
 * @notice The adapter for the USDR token itself — moves USDR between the transferable ERC-20
 *         form and the system's internal accounting.
 * @dev Based on MakerDAO's DaiJoin. Internal balances use 45 decimals (rad); the token uses 18.
 */
contract UsdrJoin is IUsdrJoin {
    /* ========================== STATE VARIABLES ========================== */

    /// @notice Authorized accounts. `wards[account] == 1` grants authorization.
    mapping(address account => uint256 authorization) public wards;

    /// @notice The Vault Engine (core ledger).
    IVaultEngine public immutable vaultEngine;

    /// @notice The USDR token.
    IUSDR public immutable usdr;

    /// @notice Adapter liveness flag. `1` while live, `0` after shutdown.
    uint256 public live;

    /* ========================== MODIFIERS ========================== */

    /// @dev Restricts a function to authorized accounts.
    modifier auth() {
        if (wards[msg.sender] != 1) {
            _revert(NotAuthorized.selector);
        }
        _;
    }

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the adapter and marks it live.
     * @param vaultEngine_ Address of the Vault Engine.
     * @param usdr_ Address of the USDR token.
     */
    constructor(IVaultEngine vaultEngine_, IUSDR usdr_) {
        wards[msg.sender] = 1;
        live = 1;
        vaultEngine = vaultEngine_;
        usdr = usdr_;

        emit Rely({ account: msg.sender });
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IUsdrJoin
     */
    function rely(address account) external auth {
        wards[account] = 1;

        emit Rely({ account: account });
    }

    /**
     * @inheritdoc IUsdrJoin
     */
    function deny(address account) external auth {
        wards[account] = 0;

        emit Deny({ account: account });
    }

    /**
     * @inheritdoc IUsdrJoin
     */
    function cage() external auth {
        live = 0;

        emit Cage();
    }

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
