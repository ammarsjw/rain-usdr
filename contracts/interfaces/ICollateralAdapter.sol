// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IVaultEngine } from "./IVaultEngine.sol";

/**
 * @title ICollateralAdapter
 * @author Rain Team
 * @notice Interface for the token adapter bridging real tokens and the internal ledger from a single deployed
 *         instance. Collateral ilks custody deposits. The USDR ilk mints and burns the token.
 */
interface ICollateralAdapter {
    /* ========================== EVENTS ========================== */

    /**
     * @dev Emitted when an ilk is registered.
     * @param ilkId Identifier of the ilk.
     * @param token Address of the token the ilk bridges.
     */
    event Init(bytes32 indexed ilkId, address indexed token);

    /**
     * @dev Emitted when tokens are deposited into the system.
     * @param ilkId Identifier of the ilk.
     * @param user Account credited inside the system.
     * @param amount Token amount deposited, in the token's native decimals.
     */
    event Join(bytes32 indexed ilkId, address indexed user, uint256 amount);

    /**
     * @dev Emitted when tokens are withdrawn from the system.
     * @param ilkId Identifier of the ilk.
     * @param user Account that receives the tokens.
     * @param amount Token amount withdrawn, in the token's native decimals.
     */
    event Exit(bytes32 indexed ilkId, address indexed user, uint256 amount);

    /**
     * @dev Emitted when an ilk is shut down.
     * @param ilkId Identifier of the ilk.
     */
    event Cage(bytes32 indexed ilkId);

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Returns the Vault Engine this adapter reports to.
     */
    function VAULT_ENGINE() external view returns (IVaultEngine);

    /**
     * @notice Returns the configuration and state of an ilk.
     * @param ilkId Identifier of the ilk.
     * @return token The token the ilk bridges.
     * @return dec Decimals of the token.
     * @return isUsdr Whether the ilk is the USDR ilk.
     * @return live `1` while live, `0` after shutdown.
     */
    function ilks(bytes32 ilkId) external view returns (IERC20Metadata token, uint8 dec, bool isUsdr, uint256 live);

    /**
     * @notice Registers an ilk with its token. This is how new tokens are added to the module. Registering under
     *         {_USDR_ILK} marks the ilk as the USDR ilk (mint and burn behaviour).
     * @param ilkId Identifier of the ilk.
     * @param token_ Address of the token the ilk bridges.
     */
    function init(bytes32 ilkId, IERC20Metadata token_) external;

    /**
     * @notice Shuts an ilk down. Blocks deposits on collateral ilks and minting on the USDR ilk. The opposite
     *         direction keeps working.
     * @param ilkId Identifier of the ilk.
     */
    function cage(bytes32 ilkId) external;

    /**
     * @notice Brings a token into the system.
     * @dev Collateral ilks credit free collateral, and the caller must have approved the adapter. The USDR ilk burns
     *      the caller's USDR and credits internal balance. Decimals are converted internally.
     * @param ilkId Identifier of the ilk.
     * @param user Account credited inside the system.
     * @param amount Token amount to deposit, in the token's native decimals.
     */
    function join(bytes32 ilkId, address user, uint256 amount) external;

    /**
     * @notice Takes a token back out of the system.
     * @dev Collateral ilks release custodied tokens, and the caller must have enough free collateral. The USDR ilk
     *      debits internal balance and mints USDR.
     * @param ilkId Identifier of the ilk.
     * @param user Account that receives the tokens.
     * @param amount Token amount to withdraw, in the token's native decimals.
     */
    function exit(bytes32 ilkId, address user, uint256 amount) external;
}
