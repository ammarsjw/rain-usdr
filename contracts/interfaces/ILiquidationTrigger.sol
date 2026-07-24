// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/**
 * @title ILiquidationTrigger.
 * @author Rain Team.
 * @notice Interface for the contract that detects unsafe vaults and starts auctions.
 */
interface ILiquidationTrigger {
    /* ========================== EVENTS ========================== */

    /// @notice Emitted when a global numeric parameter is updated.
    event File(bytes32 indexed what, uint256 data);

    /// @notice Emitted when a global address dependency is updated.
    event File(bytes32 indexed what, address addr);

    /// @notice Emitted when a per-collateral numeric parameter is updated.
    event File(bytes32 indexed ilkId, bytes32 indexed what, uint256 data);

    /// @notice Emitted when a per-collateral address dependency is updated.
    event File(bytes32 indexed ilkId, bytes32 indexed what, address addr);

    /// @notice Emitted when the trigger is shut down.
    event Cage();

    /// @notice Emitted when an unsafe vault is liquidated.
    event Bark(
        bytes32 indexed ilkId,
        address indexed urn,
        uint256 ink,
        uint256 art,
        uint256 due,
        address clip,
        uint256 id
    );

    /// @notice Emitted when auction capacity is freed after an auction clears its debt.
    event Digs(bytes32 indexed ilkId, uint256 rad);

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Adjusts a global parameter: "Hole" (global cap) or "throttle".
     * @param what Name of the parameter.
     * @param data New value.
     */
    function file(bytes32 what, uint256 data) external;

    /**
     * @notice Sets a global address dependency: "balanceSheet" or "circuitBreaker".
     * @param what Name of the parameter.
     * @param data New address.
     */
    function file(bytes32 what, address data) external;

    /**
     * @notice Adjusts a per-collateral parameter: "chop" (penalty) or "hole" (cap).
     * @param ilkId Identifier of the collateral type.
     * @param what Name of the parameter.
     * @param data New value.
     */
    function file(bytes32 ilkId, bytes32 what, uint256 data) external;

    /**
     * @notice Assigns the Dutch auction contract for a collateral type ("clip").
     * @param ilkId Identifier of the collateral type.
     * @param what Name of the parameter.
     * @param clip_ Address of the Dutch auction contract.
     */
    function file(bytes32 ilkId, bytes32 what, address clip_) external;

    /**
     * @notice Shuts the trigger down.
     */
    function cage() external;

    /**
     * @notice Returns the liquidation penalty for a collateral type.
     * @param ilkId Identifier of the collateral type.
     * @return The penalty [wad].
     */
    function chop(bytes32 ilkId) external view returns (uint256);

    /**
     * @notice Seizes an under-collateralized vault and starts an auction for its collateral.
     * @dev Reverts if the vault is safe, if the liquidation caps are hit, or when the circuit
     *      breaker throttle leaves no room this period.
     * @param ilkId Identifier of the collateral type.
     * @param urn Vault to liquidate.
     * @param kpr Keeper eligible for the liquidation reward.
     * @return id Identifier of the started auction.
     */
    function bark(bytes32 ilkId, address urn, address kpr) external returns (uint256 id);

    /**
     * @notice Frees auction capacity when an auction clears its debt.
     * @param ilkId Identifier of the collateral type.
     * @param rad Amount of capacity to free [rad].
     */
    function digs(bytes32 ilkId, uint256 rad) external;
}
