// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { IReserveAccounting } from "./IReserveAccounting.sol";
import { IVaultEngine } from "./IVaultEngine.sol";

/**
 * @title IBalanceSheet
 * @author Rain Team
 * @notice Interface for the protocol's treasury and bad debt manager.
 */
interface IBalanceSheet {
    /* ========================== EVENTS ========================== */

    /**
     * @dev Emitted when a numeric parameter is updated.
     * @param what Name of the parameter.
     * @param data New value [rad].
     */
    event File(bytes32 indexed what, uint256 data);

    /**
     * @dev Emitted when an address dependency is updated.
     * @param what Name of the parameter.
     * @param addr New address.
     */
    event File(bytes32 indexed what, address addr);

    /**
     * @dev Emitted when uncovered debt is registered.
     * @param tab Amount of uncovered debt registered [rad].
     */
    event Fess(uint256 tab);

    /**
     * @dev Emitted when a queued era of bad debt is released after the wait period.
     * @param era Timestamp bucket that was released.
     * @param tab Amount released [rad].
     */
    event Flog(uint256 indexed era, uint256 tab);

    /**
     * @dev Emitted when surplus and bad debt are cancelled against each other.
     * @param rad Amount cancelled [rad].
     */
    event Heal(uint256 rad);

    /**
     * @dev Emitted when a keeper reward is funded.
     * @param kpr Keeper being rewarded.
     * @param rad Reward amount [rad].
     */
    event Suck(address indexed kpr, uint256 rad);

    /**
     * @dev Emitted when excess surplus is released toward RAIN buyback-and-burn.
     * @param excess Amount released [rad].
     */
    event DistributeSurplus(uint256 excess);

    /* ========================== ERRORS ========================== */

    /**
     * @dev Indicates that the surplus is too low to cover the requested amount.
     */
    error InsufficientSurplus();

    /**
     * @dev Indicates that the bad debt is too low to cover the requested amount.
     */
    error InsufficientDebt();

    /**
     * @dev Indicates that bad debt must be cleared before distributing surplus.
     */
    error OutstandingBadDebt();

    /**
     * @dev Indicates that a queued era's wait period has not yet elapsed.
     */
    error WaitNotElapsed();

    /**
     * @dev Indicates that no buyback receiver has been set.
     */
    error NoBuybackReceiver();

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Adjusts the surplus buffer floor {humpFloor} [rad], the dynamic buffer rate {humpRate} [wad], or the
     *         bad debt queue delay {wait} [seconds].
     * @param what Name of the parameter.
     * @param data New value.
     */
    function file(bytes32 what, uint256 data) external;

    /**
     * @notice Sets an address dependency {buybackReceiver} or {reserveAccounting}.
     * @param what Name of the parameter.
     * @param data New address.
     */
    function file(bytes32 what, address data) external;

    /**
     * @notice Registers bad debt when an auction fails to fully cover a vault's debt.
     * @dev Called by the Liquidation Trigger. The debt itself lands on this contract's `sin` balance in the Vault
     *      Engine via `grab`.
     * @param tab Amount of uncovered debt registered [rad].
     */
    function fess(uint256 tab) external;

    /**
     * @notice Releases a queued era of bad debt once its wait period has elapsed.
     * @dev Permissionless.
     * @param era Timestamp bucket to release.
     */
    function flog(uint256 era) external;

    /**
     * @notice Nets out equal amounts of surplus and bad debt so the balance sheet stays clean.
     * @param rad Amount to cancel [rad].
     */
    function heal(uint256 rad) external;

    /**
     * @notice Funds the keeper's reward during a liquidation as backed-later debt.
     * @dev Called by the Dutch Auction, covered later from surplus.
     * @param kpr Keeper being rewarded.
     * @param rad Reward amount [rad].
     */
    function suck(address kpr, uint256 rad) external;

    /**
     * @notice Sends the surplus above the buffer target toward RAIN buyback-and-burn.
     * @dev Returns 0 without effect when the buffer is at or below target, the strict "fill before burn" rule.
     * @return excess Amount released [rad].
     */
    function distributeSurplus() external returns (uint256 excess);

    /**
     * @notice Returns the current surplus buffer target: max of {humpFloor} and {humpRate} of the total reserve.
     * @return target The buffer target [rad].
     */
    function humpTarget() external view returns (uint256 target);

    /**
     * @notice Returns the Vault Engine this balance sheet reports to.
     */
    function VAULT_ENGINE() external view returns (IVaultEngine);

    /**
     * @notice Returns the static surplus buffer floor [rad].
     */
    function humpFloor() external view returns (uint256);

    /**
     * @notice Returns the dynamic buffer rate applied to the total reserve [wad]. 10% = 0.1 * WAD.
     */
    function humpRate() external view returns (uint256);

    /**
     * @notice Returns the bad debt queue delay in seconds.
     */
    function wait() external view returns (uint256);

    /**
     * @notice Returns the total bad debt still sitting in the queue [rad].
     */
    function totalQueuedSin() external view returns (uint256);

    /**
     * @notice Returns the queued bad debt for an era [rad].
     * @param era Timestamp bucket.
     */
    function sin(uint256 era) external view returns (uint256);

    /**
     * @notice Returns the reserve accounting contract used for the dynamic buffer target. Zero when unset.
     */
    function reserveAccounting() external view returns (IReserveAccounting);

    /**
     * @notice Returns the recipient of surplus distributions, the RAIN buyback-and-burn process.
     */
    function buybackReceiver() external view returns (address);
}
