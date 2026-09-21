// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @title IVaultEngine
 * @author Rain Team
 * @notice Interface for the immutable core ledger of the USDR system.
 */
interface IVaultEngine {
    /* ========================== TYPES ========================== */

    /**
     * @notice A collateral type and its risk settings.
     * @param globalArt Total normalized debt issued against this collateral [wad].
     * @param globalInk Total collateral locked in vaults of this collateral type [wad].
     * @param rate Debt multiplier. Starts at RAY (1.0) and grows as stability fees accrue via {drip} [ray].
     * @param spot Maximum USDR mintable per unit of collateral (price factor) [ray].
     * @param line Debt ceiling for this collateral type [rad].
     * @param dust Minimum vault debt size [rad].
     * @param duty Stability fee as a per-second compounding factor. RAY means zero fee [ray].
     * @param rho Timestamp of the last stability fee accrual ({drip}).
     */
    struct Ilk {
        uint256 globalArt;
        uint256 globalInk;
        uint256 rate;
        uint256 spot;
        uint256 line;
        uint256 dust;
        uint256 duty;
        uint256 rho;
    }

    /**
     * @notice A single collateralized position. Users may hold any number of vaults per collateral type; each
     *         vault is identified by a sequential id and is collateralized, drawn against and liquidated
     *         independently.
     * @param ink Amount of collateral locked in the vault [wad].
     * @param art Normalized debt of the vault [wad].
     */
    struct Urn {
        uint256 ink;
        uint256 art;
    }

    /* ========================== EVENTS ========================== */

    /**
     * @dev Emitted when an owner permits an operator to manage its positions.
     * @param owner Account granting permission.
     * @param operator Account being granted permission.
     */
    event Hope(address indexed owner, address indexed operator);

    /**
     * @dev Emitted when an owner revokes an operator's management permission.
     * @param owner Account revoking permission.
     * @param operator Account losing permission.
     */
    event Nope(address indexed owner, address indexed operator);

    /**
     * @dev Emitted when a new collateral type is registered.
     * @param ilkId Identifier of the collateral type.
     */
    event Init(bytes32 indexed ilkId);

    /**
     * @dev Emitted when a collateral type is permanently marked fee-exempt (its `duty` pinned to RAY).
     * @param ilkId Identifier of the collateral type.
     */
    event ExemptFee(bytes32 indexed ilkId);

    /**
     * @dev Emitted when a new vault is opened.
     * @param ilkId Identifier of the collateral type the vault is bound to.
     * @param owner Owner of the new vault.
     * @param vaultId Identifier of the new vault.
     */
    event Open(bytes32 indexed ilkId, address indexed owner, uint256 indexed vaultId);

    /**
     * @dev Emitted when a global parameter is updated.
     * @param what Name of the parameter.
     * @param data New value [rad].
     */
    event File(bytes32 indexed what, uint256 data);

    /**
     * @dev Emitted when a global address dependency is updated.
     * @param what Name of the parameter.
     * @param addr New address.
     */
    event File(bytes32 indexed what, address addr);

    /**
     * @dev Emitted when a per-collateral parameter is updated.
     * @param ilkId Identifier of the collateral type.
     * @param what Name of the parameter.
     * @param data New value.
     */
    event File(bytes32 indexed ilkId, bytes32 indexed what, uint256 data);

    /**
     * @dev Emitted when a user's free collateral balance is adjusted.
     * @param ilkId Identifier of the collateral type.
     * @param user Account whose balance is adjusted.
     * @param wad Signed change in balance [wad].
     */
    event Slip(bytes32 indexed ilkId, address indexed user, int256 wad);

    /**
     * @dev Emitted when free collateral moves between users.
     * @param ilkId Identifier of the collateral type.
     * @param from Source account.
     * @param to Destination account.
     * @param wad Amount moved [wad].
     */
    event Flux(bytes32 indexed ilkId, address indexed from, address indexed to, uint256 wad);

    /**
     * @dev Emitted when internal USDR moves between users.
     * @param from Source account.
     * @param to Destination account.
     * @param rad Amount moved [rad].
     */
    event Move(address indexed from, address indexed to, uint256 rad);

    /**
     * @dev Emitted when a vault is modified.
     * @param ilkId Identifier of the collateral type.
     * @param vaultId Identifier of the vault.
     * @param v Source or destination of collateral.
     * @param w Source or destination of internal USDR.
     * @param dink Signed change in locked collateral [wad].
     * @param dart Signed change in normalized debt [wad].
     */
    event Frob(bytes32 indexed ilkId, uint256 indexed vaultId, address v, address w, int256 dink, int256 dart);

    /**
     * @dev Emitted when a vault is seized during liquidation.
     * @param ilkId Identifier of the collateral type.
     * @param vaultId Identifier of the vault being seized.
     * @param v Recipient of the seized collateral.
     * @param w Debt sink that receives the bad debt.
     * @param dink Signed change in locked collateral [wad].
     * @param dart Signed change in normalized debt [wad].
     */
    event Grab(bytes32 indexed ilkId, uint256 indexed vaultId, address v, address w, int256 dink, int256 dart);

    /**
     * @dev Emitted when surplus and bad debt are cancelled against each other.
     * @param account Account whose balances are netted.
     * @param rad Amount cancelled [rad].
     */
    event Heal(address indexed account, uint256 rad);

    /**
     * @dev Emitted when backed-later debt is created.
     * @param u Account debited with bad debt.
     * @param v Account credited with internal USDR.
     * @param rad Amount created [rad].
     */
    event Suck(address indexed u, address indexed v, uint256 rad);

    /* ========================== ERRORS ========================== */

    /**
     * @dev Indicates that a collateral type has not been initialized.
     */
    error IlkNotInitialized();

    /**
     * @dev Indicates that the caller is not permitted to act on the position.
     */
    error NotAllowed();

    /**
     * @dev Indicates that the change would leave a vault unsafe.
     */
    error NotSafe();

    /**
     * @dev Indicates that a debt ceiling would be exceeded.
     */
    error CeilingExceeded();

    /**
     * @dev Indicates that a vault would carry debt below the minimum size.
     */
    error DustAmount();

    /**
     * @dev Indicates that the vault id has not been opened.
     */
    error VaultNotFound();

    /* ========================== SOLVENCY GATE / PAUSE ========================== */

    /**
     * @notice Updates an address dependency {solvencyEngine} or {governor}. Set via `file` to avoid circular
     *         constructor dependencies. When unset (`address(0)`), the corresponding check is skipped.
     * @param what Name of the parameter.
     * @param data New address.
     */
    function file(bytes32 what, address data) external;

    /**
     * @notice Returns the Solvency Engine consulted before risk-increasing frobs. Zero when unset.
     */
    function solvencyEngine() external view returns (address);

    /**
     * @notice Returns the Governor consulted for the emergency pause. Zero when unset.
     */
    function governor() external view returns (address);

    /* ========================== FUNCTIONS ========================== */

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
     * @notice Registers a new collateral type with its debt multiplier set to 1.0, a zero stability fee
     *         (`duty = RAY`) and its fee accrual clock started at the current timestamp.
     * @dev Only governance can call this. Reverts if the collateral type already exists.
     * @param ilkId Identifier of the collateral type.
     */
    function init(bytes32 ilkId) external;

    /**
     * @notice Permanently marks a collateral type fee-exempt: filing any `duty` other than RAY on it reverts
     *         from then on. Required for every PSM (stable) ilk, the PSM's 1:1 accounting is only sound at
     *         `rate == RAY`, and any accrued fee would strand the stable reserve and mint unbacked surplus.
     * @dev Only governance can call this. One-way: there is deliberately no un-exempt path. Reverts if the
     *      ilk is uninitialized or if its rate or duty has already left RAY (the invariant it pins is already
     *      broken).
     * @param ilkId Identifier of the collateral type.
     */
    function exemptFee(bytes32 ilkId) external;

    /**
     * @notice Returns whether a collateral type is fee-exempt (its `duty` permanently pinned to RAY).
     * @param ilkId Identifier of the collateral type.
     */
    function noFee(bytes32 ilkId) external view returns (bool);

    /**
     * @notice Returns the registered collateral type identifier at `index`. Ilks are appended at {init} and
     *         never removed; the array lets {cage} (and off-chain consumers) enumerate every ilk.
     * @param index Position in the registration order.
     */
    function ilkIds(uint256 index) external view returns (bytes32);

    /**
     * @notice Returns the number of registered collateral types.
     */
    function ilkIdsLength() external view returns (uint256);

    /**
     * @notice Accrues the stability fee for a collateral type: compounds `duty` over the time elapsed since
     *         the last accrual (`rho`), folds the resulting delta into the ilk's `rate`, and credits the
     *         accrued fees to the {feeRecipient} as internal USDR surplus (with total {debt} increased
     *         equally).
     * @dev Permissionless and lazy: anyone may call at any time; `frob` (when changing debt), `bark` and duty
     *      changes drip automatically. Idempotent within a block. After `cage`, drip is a no-op that returns
     *      the frozen rate so settlement math is unaffected. Reverts if the ilk is uninitialized, or if fees
     *      would accrue while no fee recipient is set.
     * @param ilkId Identifier of the collateral type.
     * @return newRate The debt multiplier after accrual [ray].
     */
    function drip(bytes32 ilkId) external returns (uint256 newRate);

    /**
     * @notice Returns the recipient of accrued stability fees (the Balance Sheet). Zero when unset.
     */
    function feeRecipient() external view returns (address);

    /**
     * @notice Updates a global parameter. Currently only the global debt ceiling {globalLine}.
     * @param what Name of the parameter.
     * @param data New value [rad].
     */
    function file(bytes32 what, uint256 data) external;

    /**
     * @notice Updates a per-collateral parameter {spot}, {line}, {dust} or {duty}.
     * @dev Only governance, or the Price Converter for {spot}, can call this. Filing {duty} first accrues the
     *      pending fee at the old duty ({drip}), so a new duty is never applied retroactively. {duty} must be
     *      at least RAY.
     * @param ilkId Identifier of the collateral type.
     * @param what Name of the parameter.
     * @param data New value.
     */
    function file(bytes32 ilkId, bytes32 what, uint256 data) external;

    /**
     * @notice Opens a new vault bound to a collateral type and returns its id.
     * @dev Permissionless. Vault ids are sequential and never reused; ownership is fixed at open time. `usr`
     *      lets periphery contracts open vaults on behalf of users (the vault belongs to `usr`, not the
     *      caller).
     * @param ilkId Identifier of the collateral type the vault is bound to.
     * @param usr Owner of the new vault.
     * @return vaultId Identifier of the new vault.
     */
    function open(bytes32 ilkId, address usr) external returns (uint256 vaultId);

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
     * @dev Enforces the over-collateralization rule, debt ceilings, the minimum vault size and caller
     *      permissions. Uses the delayed oracle price factor already stored in the system.
     * @param vaultId Identifier of the vault being modified. The collateral type is the one fixed at open
     *        time.
     * @param v Source or destination of collateral.
     * @param w Source or destination of internal USDR.
     * @param dink Signed change in locked collateral [wad].
     * @param dart Signed change in normalized debt [wad].
     */
    function frob(uint256 vaultId, address v, address w, int256 dink, int256 dart) external;

    /**
     * @notice Seizes an unsafe vault's collateral and debt during liquidation.
     * @dev Only callable by the authorized liquidation contract.
     * @param vaultId Identifier of the vault being seized.
     * @param v Recipient of the seized collateral (the auction contract).
     * @param w Debt sink that receives the bad debt (the Balance Sheet).
     * @param dink Signed change in locked collateral [wad].
     * @param dart Signed change in normalized debt [wad].
     */
    function grab(uint256 vaultId, address v, address w, int256 dink, int256 dart) external;

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

    /**
     * @notice Returns the total USDR issued [rad].
     */
    function debt() external view returns (uint256);

    /**
     * @notice Returns the total bad debt [rad].
     */
    function vice() external view returns (uint256);

    /**
     * @notice Returns the global debt ceiling [rad].
     */
    function globalLine() external view returns (uint256);

    /**
     * @notice Returns the system liveness flag. `1` while live, `0` after shutdown.
     */
    function live() external view returns (uint256);

    /**
     * @notice Returns whether an operator may manage an owner's positions.
     * @param owner Owner of the positions.
     * @param operator Account being queried.
     * @return flag Permission flag. `1` grants permission.
     */
    function can(address owner, address operator) external view returns (uint256);

    /**
     * @notice Returns a collateral type's settings and totals.
     * @param ilkId Identifier of the collateral type.
     * @return globalArt Total normalized debt issued against this collateral [wad].
     * @return globalInk Total collateral locked in vaults of this collateral type [wad].
     * @return rate Debt multiplier [ray].
     * @return spot Maximum USDR mintable per unit of collateral [ray].
     * @return line Debt ceiling for this collateral type [rad].
     * @return dust Minimum vault debt size [rad].
     * @return duty Stability fee per-second compounding factor [ray].
     * @return rho Timestamp of the last stability fee accrual.
     */
    function ilks(
        bytes32 ilkId
    )
        external
        view
        returns (
            uint256 globalArt,
            uint256 globalInk,
            uint256 rate,
            uint256 spot,
            uint256 line,
            uint256 dust,
            uint256 duty,
            uint256 rho
        );

    /**
     * @notice Returns a vault's locked collateral and normalized debt.
     * @param vaultId Identifier of the vault.
     * @return ink Locked collateral [wad].
     * @return art Normalized debt [wad].
     */
    function urns(uint256 vaultId) external view returns (uint256 ink, uint256 art);

    /**
     * @notice Returns the total number of vaults ever opened. The latest vault id.
     */
    function vaultCount() external view returns (uint256);

    /**
     * @notice Returns the owner of a vault. Zero when the vault has not been opened.
     * @param vaultId Identifier of the vault.
     */
    function ownerOf(uint256 vaultId) external view returns (address);

    /**
     * @notice Returns the collateral type a vault is bound to. Zero when the vault has not been opened.
     * @param vaultId Identifier of the vault.
     */
    function ilkOf(uint256 vaultId) external view returns (bytes32);

    /**
     * @notice Returns a user's free collateral balance.
     * @param ilkId Identifier of the collateral type.
     * @param user Account being queried.
     * @return collateral The free collateral balance [wad].
     */
    function collateral(bytes32 ilkId, address user) external view returns (uint256);

    /**
     * @notice Returns a user's internal USDR balance.
     * @param user Account being queried.
     * @return usdrBalance The internal USDR balance [rad].
     */
    function usdr(address user) external view returns (uint256);

    /**
     * @notice Returns a debt sink's bad debt balance.
     * @param debtSink Account being queried.
     * @return badDebtBalance The bad debt balance [rad].
     */
    function sin(address debtSink) external view returns (uint256);
}
