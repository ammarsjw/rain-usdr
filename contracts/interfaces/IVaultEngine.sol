// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/**
 * @title IVaultEngine.
 * @author Rain Team.
 * @notice Interface for the immutable core ledger of the USDR system.
 */
interface IVaultEngine {
    /* ========================== TYPES ========================== */

    /**
     * @notice A collateral type and its risk settings.
     * @param Art Total normalized debt issued against this collateral [wad].
     * @param rate Debt multiplier. Fixed at RAY (1.0) since USDR charges no stability fee [ray].
     * @param spot Maximum USDR mintable per unit of collateral (price factor) [ray].
     * @param line Debt ceiling for this collateral type [rad].
     * @param dust Minimum vault debt size [rad].
     */
    struct Ilk {
        uint256 Art;
        uint256 rate;
        uint256 spot;
        uint256 line;
        uint256 dust;
    }

    /**
     * @notice A single user's collateralized position.
     * @param ink Amount of collateral locked in the vault [wad].
     * @param art Normalized debt of the vault [wad].
     */
    struct Urn {
        uint256 ink;
        uint256 art;
    }

    /* ========================== EVENTS ========================== */

    /// @notice Emitted when an owner permits an operator to manage its positions.
    event Hope(address indexed owner, address indexed operator);

    /// @notice Emitted when an owner revokes an operator's management permission.
    event Nope(address indexed owner, address indexed operator);

    /// @notice Emitted when a new collateral type is registered.
    event Init(bytes32 indexed ilkId);

    /// @notice Emitted when a global parameter is updated.
    event File(bytes32 indexed what, uint256 data);

    /// @notice Emitted when a per-collateral parameter is updated.
    event File(bytes32 indexed ilkId, bytes32 indexed what, uint256 data);

    /// @notice Emitted when the ledger is shut down.
    event Cage();

    /// @notice Emitted when a user's free collateral balance is adjusted.
    event Slip(bytes32 indexed ilkId, address indexed user, int256 wad);

    /// @notice Emitted when free collateral moves between users.
    event Flux(bytes32 indexed ilkId, address indexed from, address indexed to, uint256 wad);

    /// @notice Emitted when internal USDR moves between users.
    event Move(address indexed from, address indexed to, uint256 rad);

    /// @notice Emitted when a vault is modified.
    event Frob(bytes32 indexed ilkId, address indexed u, address v, address w, int256 dink, int256 dart);

    /// @notice Emitted when a vault is seized during liquidation.
    event Grab(bytes32 indexed ilkId, address indexed u, address v, address w, int256 dink, int256 dart);

    /// @notice Emitted when surplus and bad debt are cancelled against each other.
    event Heal(address indexed account, uint256 rad);

    /// @notice Emitted when backed-later debt is created.
    event Suck(address indexed u, address indexed v, uint256 rad);

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Returns a collateral type's settings and totals.
     * @param ilkId Identifier of the collateral type.
     * @return Art Total normalized debt issued against this collateral [wad].
     * @return rate Debt multiplier [ray].
     * @return spot Maximum USDR mintable per unit of collateral [ray].
     * @return line Debt ceiling for this collateral type [rad].
     * @return dust Minimum vault debt size [rad].
     */
    function ilks(
        bytes32 ilkId
    ) external view returns (uint256 Art, uint256 rate, uint256 spot, uint256 line, uint256 dust);

    /**
     * @notice Returns a vault's locked collateral and normalized debt.
     * @param ilkId Identifier of the collateral type.
     * @param vaultOwner Owner of the vault.
     * @return ink Locked collateral [wad].
     * @return art Normalized debt [wad].
     */
    function urns(bytes32 ilkId, address vaultOwner) external view returns (uint256 ink, uint256 art);

    /**
     * @notice Returns a user's free collateral balance.
     * @param ilkId Identifier of the collateral type.
     * @param user Account being queried.
     * @return The free collateral balance [wad].
     */
    function collateral(bytes32 ilkId, address user) external view returns (uint256);

    /**
     * @notice Returns a user's internal USDR balance.
     * @param user Account being queried.
     * @return The internal USDR balance [rad].
     */
    function usdr(address user) external view returns (uint256);

    /**
     * @notice Returns a debt sink's bad debt balance.
     * @param debtSink Account being queried.
     * @return The bad debt balance [rad].
     */
    function sin(address debtSink) external view returns (uint256);

    /**
     * @notice Permits an operator to manage the caller's positions.
     * @param operator Address being granted permission.
     */
    function hope(address operator) external;

    /**
     * @notice Revokes an operator's permission to manage the caller's positions.
     * @param operator Address losing permission.
     */
    function nope(address operator) external;

    /**
     * @notice Registers a new collateral type with its debt multiplier set to 1.0.
     * @dev Only governance can call this. Reverts if the collateral type already exists.
     * @param ilkId Identifier of the collateral type.
     */
    function init(bytes32 ilkId) external;

    /**
     * @notice Updates a global parameter. Currently only the global debt ceiling ("Line").
     * @param what Name of the parameter.
     * @param data New value [rad].
     */
    function file(bytes32 what, uint256 data) external;

    /**
     * @notice Updates a per-collateral parameter: "spot", "line" or "dust".
     * @dev Only governance (or the Price Converter, for "spot") can call this.
     * @param ilkId Identifier of the collateral type.
     * @param what Name of the parameter.
     * @param data New value.
     */
    function file(bytes32 ilkId, bytes32 what, uint256 data) external;

    /**
     * @notice Freezes the core ledger during an emergency shutdown.
     */
    function cage() external;

    /**
     * @notice Adjusts a user's free (unlocked) collateral balance.
     * @dev Called by the Collateral Adapter on deposit and withdrawal.
     * @param ilkId Identifier of the collateral type.
     * @param user Account whose balance is adjusted.
     * @param wad Signed change in balance [wad].
     */
    function slip(bytes32 ilkId, address user, int256 wad) external;

    /**
     * @notice Moves free collateral between users inside the system.
     * @param ilkId Identifier of the collateral type.
     * @param from Source account.
     * @param to Destination account.
     * @param wad Amount to move [wad].
     */
    function flux(bytes32 ilkId, address from, address to, uint256 wad) external;

    /**
     * @notice Moves internal USDR between users.
     * @param from Source account.
     * @param to Destination account.
     * @param rad Amount to move [rad].
     */
    function move(address from, address to, uint256 rad) external;

    /**
     * @notice The core vault operation: lock or free collateral and mint or repay USDR.
     * @dev Enforces the over-collateralization rule, debt ceilings, the minimum vault size and
     *      caller permissions. Uses the delayed oracle price factor already stored in the system.
     * @param ilkId Identifier of the collateral type.
     * @param u Vault owner.
     * @param v Source or destination of collateral.
     * @param w Source or destination of internal USDR.
     * @param dink Signed change in locked collateral [wad].
     * @param dart Signed change in normalized debt [wad].
     */
    function frob(bytes32 ilkId, address u, address v, address w, int256 dink, int256 dart) external;

    /**
     * @notice Seizes an unsafe vault's collateral and debt during liquidation.
     * @dev Only callable by the authorized liquidation contract.
     * @param ilkId Identifier of the collateral type.
     * @param u Vault being seized.
     * @param v Recipient of the seized collateral (the auction contract).
     * @param w Debt sink that receives the bad debt (the Balance Sheet).
     * @param dink Signed change in locked collateral [wad].
     * @param dart Signed change in normalized debt [wad].
     */
    function grab(bytes32 ilkId, address u, address v, address w, int256 dink, int256 dart) external;

    /**
     * @notice Cancels equal amounts of the caller's bad debt and surplus.
     * @param rad Amount to cancel [rad].
     */
    function heal(uint256 rad) external;

    /**
     * @notice Creates USDR paired with an equal record of bad debt (backed-later debt).
     * @dev Used to pay keeper rewards, covered later from surplus. Called by the Balance Sheet.
     * @param u Account debited with bad debt.
     * @param v Account credited with internal USDR.
     * @param rad Amount to create [rad].
     */
    function suck(address u, address v, uint256 rad) external;
}
