// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

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

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Returns the Vault Engine this balance sheet reports to.
     * @return The Vault Engine.
     */
    function VAULT_ENGINE() external view returns (IVaultEngine);

    /**
     * @notice Returns the recipient of surplus distributions (the RAIN buyback-and-burn process).
     * @return The buyback receiver address.
     */
    function buybackReceiver() external view returns (address);

    /**
     * @notice Returns the surplus buffer target.
     * @return The surplus buffer target [rad].
     */
    function hump() external view returns (uint256);

    /**
     * @notice Adjusts the surplus buffer target ("hump").
     * @param what Name of the parameter.
     * @param data New value [rad].
     */
    function file(bytes32 what, uint256 data) external;

    /**
     * @notice Sets an address dependency: "buybackReceiver".
     * @param what Name of the parameter.
     * @param data New address.
     */
    function file(bytes32 what, address data) external;

    /**
     * @notice Registers bad debt when an auction fails to fully cover a vault's debt.
     * @dev Called by the Liquidation Trigger; the debt itself lands on this contract's `sin` balance in the Vault
     *      Engine via `grab`.
     * @param tab Amount of uncovered debt registered [rad].
     */
    function fess(uint256 tab) external;

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
     * @dev Reverts if the buffer is below target — the strict "fill before burn" rule.
     * @return excess Amount released [rad].
     */
    function distributeSurplus() external returns (uint256 excess);
}
