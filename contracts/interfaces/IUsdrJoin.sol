// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IUSDR } from "./IUSDR.sol";
import { IVaultEngine } from "./IVaultEngine.sol";

/**
 * @title IUsdrJoin.
 * @author Rain Team.
 * @notice Interface for the USDR token adapter.
 */
interface IUsdrJoin {
    /* ========================== EVENTS ========================== */

    /// @notice Emitted when an account is granted authorization.
    event Rely(address indexed account);

    /// @notice Emitted when an account has its authorization revoked.
    event Deny(address indexed account);

    /// @notice Emitted when the adapter is shut down.
    event Cage();

    /// @notice Emitted when USDR tokens are converted into internal balance.
    event Join(address indexed user, uint256 wad);

    /// @notice Emitted when internal balance is converted into USDR tokens.
    event Exit(address indexed user, uint256 wad);

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Returns the Vault Engine this adapter reports to.
     * @return The Vault Engine.
     */
    function vaultEngine() external view returns (IVaultEngine);

    /**
     * @notice Returns the USDR token.
     * @return The USDR token.
     */
    function usdr() external view returns (IUSDR);

    /**
     * @notice Grants authorization to an account.
     * @param account Address to authorize.
     */
    function rely(address account) external;

    /**
     * @notice Revokes authorization from an account.
     * @param account Address to deauthorize.
     */
    function deny(address account) external;

    /**
     * @notice Shuts the adapter down, blocking further exits.
     */
    function cage() external;

    /**
     * @notice Burns USDR tokens and credits the equivalent internal balance.
     * @param user Account credited with internal USDR.
     * @param wad Amount of USDR [wad].
     */
    function join(address user, uint256 wad) external;

    /**
     * @notice Debits internal balance and mints the equivalent USDR tokens.
     * @param user Account that receives the USDR tokens.
     * @param wad Amount of USDR [wad].
     */
    function exit(address user, uint256 wad) external;
}
