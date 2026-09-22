// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { IBalanceSheet } from "./IBalanceSheet.sol";
import { ICircuitBreaker } from "./ICircuitBreaker.sol";
import { IVaultEngine } from "./IVaultEngine.sol";

/**
 * @title ILiquidationTrigger
 * @author Rain Team
 * @notice Interface for the contract that detects unsafe vaults and starts auctions.
 */
interface ILiquidationTrigger {
    /* ========================== TYPES ========================== */

    /**
     * @notice Liquidation settings for a collateral type.
     * @param clip The Dutch auction contract for this collateral.
     * @param chop The liquidation penalty [wad]. 13% = 1.13 * WAD.
     * @param hole The maximum active liquidation size for this collateral [rad].
     * @param dirt The amount currently being auctioned for this collateral [rad].
     * @param barkFactor Fraction of the required collateral ratio at which a vault becomes liquidatable
     *        [wad]. 65% = 0.65 * WAD.
     */
    struct IlkLiquidation {
        address clip;
        uint256 chop;
        uint256 hole;
        uint256 dirt;
        uint256 barkFactor;
    }

    /* ========================== EVENTS ========================== */

    /**
     * @dev Emitted when a global numeric parameter is updated.
     * @param what Name of the parameter.
     * @param data New value.
     */
    event File(bytes32 indexed what, uint256 data);

    /**
     * @dev Emitted when a global address dependency is updated.
     * @param what Name of the parameter.
     * @param addr New address.
     */
    event File(bytes32 indexed what, address addr);

    /**
     * @dev Emitted when a per-collateral numeric parameter is updated.
     * @param ilkId Identifier of the collateral type.
     * @param what Name of the parameter.
     * @param data New value.
     */
    event File(bytes32 indexed ilkId, bytes32 indexed what, uint256 data);

    /**
     * @dev Emitted when a per-collateral address dependency is updated.
     * @param ilkId Identifier of the collateral type.
     * @param what Name of the parameter.
     * @param addr New address.
     */
    event File(bytes32 indexed ilkId, bytes32 indexed what, address addr);

    /**
     * @dev Emitted when an unsafe vault is liquidated.
     * @param ilkId Identifier of the collateral type.
     * @param vaultId Identifier of the vault that was liquidated.
     * @param urn Owner of the liquidated vault (receives any leftover collateral).
     * @param ink Collateral seized [wad].
     * @param art Normalized debt seized [wad].
     * @param due Debt to recover before the penalty [rad].
     * @param clip Auction contract the collateral was sent to.
     * @param id Identifier of the started auction.
     */
    event Bark(
        bytes32 indexed ilkId,
        uint256 indexed vaultId,
        address indexed urn,
        uint256 ink,
        uint256 art,
        uint256 due,
        address clip,
        uint256 id
    );

    /**
     * @dev Emitted when auction capacity is freed after an auction clears its debt.
     * @param ilkId Identifier of the collateral type.
     * @param rad Amount of capacity freed [rad].
     */
    event Digs(bytes32 indexed ilkId, uint256 rad);

    /* ========================== ERRORS ========================== */

    /**
     * @dev Indicates that a liquidation penalty below one was supplied.
     */
    error ChopBelowOne();

    /**
     * @dev Indicates that a bark factor outside (0, 1] was supplied.
     */
    error InvalidBarkFactor();

    /**
     * @dev Indicates that a circuit breaker throttle outside (0, 1] was supplied.
     */
    error InvalidThrottle();

    /**
     * @dev Indicates that the vault is not unsafe and cannot be liquidated.
     */
    error NotUnsafe();

    /**
     * @dev Indicates that the ilk's liquidation parameters (clip, chop, barkFactor) are not fully
     *      configured, so no vault on it can be liquidated.
     */
    error IlkNotConfigured();

    /**
     * @dev Indicates that the vault id has not been opened.
     */
    error VaultNotFound();

    /**
     * @dev Indicates that the liquidation limit has been reached.
     */
    error LiquidationLimitHit();

    /**
     * @dev Indicates that a partial liquidation would leave a dusty auction.
     */
    error DustyAuction();

    /**
     * @dev Indicates that the liquidation would produce a null auction.
     */
    error NullAuction();

    /**
     * @dev Indicates that a liquidation amount overflowed the signed range.
     */
    error Overflow();

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Adjusts a global parameter {globalHole} or {throttle}.
     * @param what Name of the parameter.
     * @param data New value.
     */
    function file(bytes32 what, uint256 data) external;

    /**
     * @notice Sets a global address dependency {balanceSheet} or {circuitBreaker}.
     * @param what Name of the parameter.
     * @param data New address.
     */
    function file(bytes32 what, address data) external;

    /**
     * @notice Adjusts a per-collateral parameter {chop}, {hole} or {barkFactor}.
     * @param ilkId Identifier of the collateral type.
     * @param what Name of the parameter.
     * @param data New value.
     */
    function file(bytes32 ilkId, bytes32 what, uint256 data) external;

    /**
     * @notice Assigns the Dutch auction contract for a collateral type {clip}.
     * @param ilkId Identifier of the collateral type.
     * @param what Name of the parameter.
     * @param clip Address of the Dutch auction contract.
     */
    function file(bytes32 ilkId, bytes32 what, address clip) external;

    /**
     * @notice Shuts the trigger down.
     */
    function cage() external;

    /**
     * @notice Seizes an under-collateralized vault and starts an auction for its collateral.
     * @dev Reverts if the vault is safe, if the liquidation caps are hit, or when the circuit breaker
     *      throttle leaves no room this period. Each vault id is assessed independently against the bark
     *      threshold.
     * @param vaultId Identifier of the vault to liquidate.
     * @param kpr Keeper eligible for the liquidation reward.
     * @return id Identifier of the started auction.
     */
    function bark(uint256 vaultId, address kpr) external returns (uint256 id);

    /**
     * @notice Frees auction capacity when an auction clears its debt.
     * @param ilkId Identifier of the collateral type.
     * @param rad Amount of capacity to free [rad].
     */
    function digs(bytes32 ilkId, uint256 rad) external;

    /**
     * @notice Returns the liquidation penalty for a collateral type.
     * @param ilkId Identifier of the collateral type.
     * @return penalty The penalty [wad].
     */
    function chop(bytes32 ilkId) external view returns (uint256);

    /**
     * @notice Returns the Vault Engine this trigger reports to.
     */
    function VAULT_ENGINE() external view returns (IVaultEngine);

    /**
     * @notice Returns the maximum active liquidation size across all collateral types [rad].
     */
    function globalHole() external view returns (uint256);

    /**
     * @notice Returns the amount currently being auctioned across all collateral types [rad].
     */
    function globalDirt() external view returns (uint256);

    /**
     * @notice Returns the throttled liquidation rate while the breaker is active [wad].
     */
    function throttle() external view returns (uint256);

    /**
     * @notice Returns the liveness flag. `1` while live, `0` after shutdown.
     */
    function live() external view returns (uint256);

    /**
     * @notice Returns the Balance Sheet that receives seized debt.
     */
    function balanceSheet() external view returns (IBalanceSheet);

    /**
     * @notice Returns the circuit breaker that throttles liquidations during abnormal price moves.
     */
    function circuitBreaker() external view returns (ICircuitBreaker);

    /**
     * @notice Returns the Governor consulted for the emergency pause. Zero when unset.
     */
    function governor() external view returns (address);

    /**
     * @notice Returns the liquidation settings for a collateral type.
     * @param ilkId Identifier of the collateral type.
     * @return clip The Dutch auction contract for this collateral.
     * @return chop The liquidation penalty [wad].
     * @return hole The maximum active liquidation size for this collateral [rad].
     * @return dirt The amount currently being auctioned for this collateral [rad].
     * @return barkFactor Fraction of the required collateral ratio at which a vault becomes liquidatable
     *         [wad].
     */
    function ilks(
        bytes32 ilkId
    ) external view returns (address clip, uint256 chop, uint256 hole, uint256 dirt, uint256 barkFactor);
}
