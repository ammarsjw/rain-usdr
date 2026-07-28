// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/**
 * @title IBalanceSheet
 * @author Rain Team
 * @notice Interface for the protocol's treasury and bad debt manager.
 */
interface IBalanceSheet {
    /* ========================== EVENTS ========================== */

    /// @notice Emitted when a numeric parameter is updated.
    event File(bytes32 indexed what, uint256 data);

    /// @notice Emitted when an address dependency is updated.
    event File(bytes32 indexed what, address addr);

    /// @notice Emitted when uncovered debt is registered.
    event Fess(uint256 tab);

    /// @notice Emitted when surplus and bad debt are cancelled against each other.
    event Heal(uint256 rad);

    /// @notice Emitted when a keeper reward is funded.
    event Suck(address indexed kpr, uint256 rad);

    /// @notice Emitted when excess surplus is released toward RAIN buyback-and-burn.
    event DistributeSurplus(uint256 excess);

    /* ========================== FUNCTIONS ========================== */

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
     * @dev Called by the Liquidation Trigger; the debt itself lands on this contract's `sin`
     *      balance in the Vault Engine via `grab`.
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
