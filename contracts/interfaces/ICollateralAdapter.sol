// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IVaultEngine } from "./IVaultEngine.sol";

/**
 * @title ICollateralAdapter.
 * @author Rain Team.
 * @notice Interface for the token adapter that bridges real tokens and the internal ledger.
 *         Collateral instances custody deposits; the USDR instance mints and burns the token.
 */
interface ICollateralAdapter {
    /* ========================== EVENTS ========================== */

    /// @notice Emitted when tokens are deposited into the system.
    event Join(address indexed user, uint256 amount);

    /// @notice Emitted when tokens are withdrawn from the system.
    event Exit(address indexed user, uint256 amount);

    /// @notice Emitted when the adapter is shut down.
    event Cage();

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Returns the Vault Engine this adapter reports to.
     * @return The Vault Engine.
     */
    function vaultEngine() external view returns (IVaultEngine);

    /**
     * @notice Returns the identifier of the collateral type this adapter serves.
     * @return The collateral type identifier. Zero for the USDR instance.
     */
    function ilkId() external view returns (bytes32);

    /**
     * @notice Returns the token this adapter bridges.
     * @return The token — held in custody, or minted/burned for USDR.
     */
    function token() external view returns (IERC20Metadata);

    /**
     * @notice Returns the decimals of the token.
     * @return The token decimals.
     */
    function dec() external view returns (uint256);

    /**
     * @notice Returns whether this instance is the USDR adapter.
     * @return `true` for the USDR instance, `false` for a collateral instance.
     */
    function isUsdrAdapter() external view returns (bool);

    /**
     * @notice Returns the adapter liveness flag.
     * @return `1` while live, `0` after shutdown.
     */
    function live() external view returns (uint256);

    /**
     * @notice Shuts the adapter down. Blocks deposits on collateral instances and minting on the
     *         USDR instance; the opposite direction keeps working.
     */
    function cage() external;

    /**
     * @notice Brings a token into the system.
     * @dev Collateral instances credit free collateral (the caller must have approved the
     *      adapter); the USDR instance burns the caller's USDR and credits internal balance.
     *      Decimals are converted internally.
     * @param user Account credited inside the system.
     * @param amount Token amount to deposit, in the token's native decimals.
     */
    function join(address user, uint256 amount) external;

    /**
     * @notice Takes a token back out of the system.
     * @dev Collateral instances release custodied tokens (the caller must have enough free
     *      collateral); the USDR instance debits internal balance and mints USDR.
     * @param user Account that receives the tokens.
     * @param amount Token amount to withdraw, in the token's native decimals.
     */
    function exit(address user, uint256 amount) external;
}
