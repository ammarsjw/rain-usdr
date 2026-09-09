// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { IBalanceSheet } from "./IBalanceSheet.sol";
import { ILiquidationTrigger } from "./ILiquidationTrigger.sol";
import { IPriceConverter } from "./IPriceConverter.sol";
import { IVaultEngine } from "./IVaultEngine.sol";

/**
 * @title IEnd
 * @author Rain Team
 * @notice Interface for the emergency settlement module that winds the system down and lets every USDR holder redeem
 *         collateral pro-rata.
 */
interface IEnd {
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
     * @dev Emitted when a collateral type's settlement price is fixed.
     * @param ilkId Identifier of the collateral type.
     * @param tag Settlement price factor [ray].
     * @param art Total normalized debt snapshotted for the collateral type [wad].
     */
    event CageIlk(bytes32 indexed ilkId, uint256 tag, uint256 art);

    /**
     * @dev Emitted when an in-flight auction is reclaimed into its vault.
     * @param ilkId Identifier of the collateral type.
     * @param auctionId Identifier of the reclaimed auction.
     * @param vaultId Identifier of the vault restored.
     * @param lot Collateral returned to the vault [wad].
     * @param art Normalized debt returned to the vault [wad].
     */
    event Skip(bytes32 indexed ilkId, uint256 indexed auctionId, uint256 indexed vaultId, uint256 lot, uint256 art);

    /**
     * @dev Emitted when a vault is settled against the settlement price.
     * @param ilkId Identifier of the collateral type.
     * @param vaultId Identifier of the settled vault.
     * @param wad Collateral confiscated to back circulating USDR [wad].
     * @param art Normalized debt cancelled [wad].
     */
    event Skim(bytes32 indexed ilkId, uint256 indexed vaultId, uint256 wad, uint256 art);

    /**
     * @dev Emitted when a vault owner reclaims leftover collateral after settlement.
     * @param ilkId Identifier of the collateral type.
     * @param vaultId Identifier of the vault freed.
     * @param owner Owner receiving the collateral.
     * @param ink Collateral released [wad].
     */
    event Free(bytes32 indexed ilkId, uint256 indexed vaultId, address indexed owner, uint256 ink);

    /**
     * @dev Emitted when the total outstanding debt is fixed for redemption.
     * @param debt The fixed total debt [rad].
     */
    event Thaw(uint256 debt);

    /**
     * @dev Emitted when a collateral type's final redemption price is computed.
     * @param ilkId Identifier of the collateral type.
     * @param fix Collateral per USDR redeemed [ray].
     */
    event Flow(bytes32 indexed ilkId, uint256 fix);

    /**
     * @dev Emitted when a holder deposits USDR for redemption.
     * @param usr Depositing holder.
     * @param wad USDR deposited [wad].
     */
    event Pack(address indexed usr, uint256 wad);

    /**
     * @dev Emitted when a holder redeems collateral against their bag.
     * @param ilkId Identifier of the collateral type.
     * @param usr Redeeming holder.
     * @param wad USDR portion redeemed against this collateral [wad].
     * @param ink Collateral received [wad].
     */
    event Cash(bytes32 indexed ilkId, address indexed usr, uint256 wad, uint256 ink);

    /* ========================== ERRORS ========================== */

    /**
     * @dev Indicates that settlement has already been triggered.
     */
    error AlreadyCaged();

    /**
     * @dev Indicates that settlement has not been triggered yet.
     */
    error StillLive();

    /**
     * @dev Indicates that the collateral type's settlement price has already been fixed.
     */
    error TagAlreadyDefined();

    /**
     * @dev Indicates that the collateral type's settlement price has not been fixed yet.
     */
    error TagNotDefined();

    /**
     * @dev Indicates that the vault still carries debt.
     */
    error ArtNotZero();

    /**
     * @dev Indicates that the cooldown period has not elapsed yet.
     */
    error WaitNotElapsed();

    /**
     * @dev Indicates that the Balance Sheet still holds surplus that must be healed or distributed first.
     */
    error SurplusNotZero();

    /**
     * @dev Indicates that the total debt has already been fixed.
     */
    error DebtAlreadyFixed();

    /**
     * @dev Indicates that the total debt has not been fixed yet.
     */
    error DebtNotFixed();

    /**
     * @dev Indicates that the redemption price has already been computed.
     */
    error FixAlreadyDefined();

    /**
     * @dev Indicates that the redemption price has not been computed yet.
     */
    error FixNotDefined();

    /**
     * @dev Indicates that a redemption exceeds the holder's deposited bag.
     */
    error InsufficientBag();

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Updates the settlement cooldown {wait}.
     * @param what Name of the parameter.
     * @param data New value.
     */
    function file(bytes32 what, uint256 data) external;

    /**
     * @notice Updates an address dependency {liquidationTrigger}, {balanceSheet} or {priceConverter}.
     * @param what Name of the parameter.
     * @param data New address.
     */
    function file(bytes32 what, address data) external;

    /**
     * @notice Phase 3a: reclaims an in-flight Dutch auction, returning its collateral and debt to the vault it was
     *         seized from so the vault settles like every other.
     * @param ilkId Identifier of the collateral type.
     * @param auctionId Identifier of the auction to reclaim.
     */
    function skip(bytes32 ilkId, uint256 auctionId) external;

    /**
     * @notice Phase 3b: settles a vault. Confiscates exactly the collateral needed to back its debt at the settlement
     *         price and cancels the debt. Any shortfall is recorded in the collateral's gap.
     * @param vaultId Identifier of the vault to settle.
     */
    function skim(uint256 vaultId) external;

    /**
     * @notice Phase 4: lets a vault owner reclaim leftover collateral once the vault carries no debt.
     * @param vaultId Identifier of the vault to free.
     */
    function free(uint256 vaultId) external;

    /**
     * @notice Phase 5: fixes the total outstanding debt after the cooldown, opening redemption.
     * @dev The Balance Sheet's surplus must be fully healed away first.
     */
    function thaw() external;

    /**
     * @notice Phase 6: computes a collateral type's final redemption price (collateral per USDR).
     * @param ilkId Identifier of the collateral type.
     */
    function flow(bytes32 ilkId) external;

    /**
     * @notice Phase 7: deposits internal USDR into the caller's redemption bag.
     * @dev USDR ERC-20 holders first convert through the Collateral Adapter's USDR join.
     * @param wad Amount of USDR to deposit [wad].
     */
    function pack(uint256 wad) external;

    /**
     * @notice Phase 8: redeems collateral pro-rata against the caller's bag.
     * @param ilkId Identifier of the collateral type.
     * @param wad USDR portion of the bag to redeem against this collateral [wad].
     */
    function cash(bytes32 ilkId, uint256 wad) external;

    /**
     * @notice Phase 1: freezes the system. Cages the Vault Engine, the Liquidation Trigger and the Price Converter,
     *         and starts the settlement clock.
     * @dev Only governance may call this.
     */
    function cage() external;

    /**
     * @notice Phase 2: fixes a collateral type's settlement price from its last delayed oracle price and snapshots its
     *         total debt.
     * @dev Permissionless once settlement has been triggered. Fixed-price ilks settle at exactly $1.
     * @param ilkId Identifier of the collateral type.
     */
    function cage(bytes32 ilkId) external;

    /**
     * @notice Returns the Vault Engine being settled.
     */
    function VAULT_ENGINE() external view returns (IVaultEngine);

    /**
     * @notice Returns the timestamp at which settlement was triggered.
     */
    function when() external view returns (uint256);

    /**
     * @notice Returns the cooldown in seconds between settlement trigger and debt fixing.
     */
    function wait() external view returns (uint256);

    /**
     * @notice Returns the fixed total debt for redemption [rad]. Zero until {thaw}.
     */
    function debt() external view returns (uint256);

    /**
     * @notice Returns the liveness flag. `1` while live, `0` once settlement is triggered.
     */
    function live() external view returns (uint256);

    /**
     * @notice Returns the Liquidation Trigger.
     */
    function liquidationTrigger() external view returns (ILiquidationTrigger);

    /**
     * @notice Returns the Balance Sheet (the debt sink for settlement).
     */
    function balanceSheet() external view returns (IBalanceSheet);

    /**
     * @notice Returns the Price Converter (the oracle router for settlement prices).
     */
    function priceConverter() external view returns (IPriceConverter);

    /**
     * @notice Returns a collateral type's settlement price factor [ray]. Zero until its {cage}.
     * @param ilkId Identifier of the collateral type.
     */
    function tag(bytes32 ilkId) external view returns (uint256);

    /**
     * @notice Returns a collateral type's collateral shortfall accumulated during {skim} [wad].
     * @param ilkId Identifier of the collateral type.
     */
    function gap(bytes32 ilkId) external view returns (uint256);

    /**
     * @notice Returns a collateral type's total normalized debt snapshotted at its {cage} [wad].
     * @param ilkId Identifier of the collateral type.
     */
    function art(bytes32 ilkId) external view returns (uint256);

    /**
     * @notice Returns a collateral type's final redemption price [ray]. Zero until {flow}.
     * @param ilkId Identifier of the collateral type.
     */
    function fix(bytes32 ilkId) external view returns (uint256);

    /**
     * @notice Returns a holder's deposited redemption bag [wad].
     * @param usr Holder being queried.
     */
    function bag(address usr) external view returns (uint256);

    /**
     * @notice Returns how much of a holder's bag has been redeemed against a collateral type [wad].
     * @param ilkId Identifier of the collateral type.
     * @param usr Holder being queried.
     */
    function out(bytes32 ilkId, address usr) external view returns (uint256);
}
