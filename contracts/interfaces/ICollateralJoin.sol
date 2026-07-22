// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IVaultEngine } from "./IVaultEngine.sol";

/**
 * @title ICollateralJoin.
 * @author Rain Team.
 * @notice Interface for the collateral adapter that bridges real tokens and the internal ledger.
 */
interface ICollateralJoin {
    /* ========================== EVENTS ========================== */

    /// @notice Emitted when an account is granted authorization.
    event Rely(address indexed account);

    /// @notice Emitted when an account has its authorization revoked.
    event Deny(address indexed account);

    /// @notice Emitted when the adapter stops accepting deposits.
    event Cage();

    /// @notice Emitted when tokens are deposited into the system.
    event Join(address indexed user, uint256 amount);

    /// @notice Emitted when tokens are withdrawn from the system.
    event Exit(address indexed user, uint256 amount);

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Returns the Vault Engine this adapter reports to.
     * @return The Vault Engine.
     */
    function vaultEngine() external view returns (IVaultEngine);

    /**
     * @notice Returns the identifier of the collateral type this adapter serves.
     * @return The collateral type identifier.
     */
    function ilkId() external view returns (bytes32);

    /**
     * @notice Returns the collateral token held in custody.
     * @return The collateral token.
     */
    function gem() external view returns (IERC20Metadata);

    /**
     * @notice Returns the decimals of the collateral token.
     * @return The token decimals.
     */
    function dec() external view returns (uint256);

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
     * @notice Stops accepting new deposits while still allowing withdrawals.
     */
    function cage() external;

    /**
     * @notice Brings a token into the system so it can be used as collateral.
     * @dev The caller must have approved the adapter. Decimals are converted internally.
     * @param user Account credited with free collateral.
     * @param amount Token amount to deposit, in the token's native decimals.
     */
    function join(address user, uint256 amount) external;

    /**
     * @notice Takes a token back out of the system.
     * @dev The caller must have enough free (unlocked) collateral inside the system.
     * @param user Account that receives the released tokens.
     * @param amount Token amount to withdraw, in the token's native decimals.
     */
    function exit(address user, uint256 amount) external;
}
