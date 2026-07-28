// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/**
 * @title IPegStabilityModule
 * @author Rain Team
 * @notice Interface for the module that swaps stablecoins for USDR at 1:1, serving every
 *         stablecoin from a single deployed instance.
 */
interface IPegStabilityModule {
    /* ========================== EVENTS ========================== */

    /// @notice Emitted when a stablecoin ilk is registered.
    event Init(bytes32 indexed ilkId, address indexed token);

    /// @notice Emitted when a fee parameter is updated.
    event File(bytes32 indexed ilkId, bytes32 indexed what, uint256 data);

    /// @notice Emitted when a user converts stablecoins into USDR.
    event SellStable(bytes32 indexed ilkId, address indexed user, uint256 stableAmt, uint256 usdrAmt);

    /// @notice Emitted when a user redeems USDR for stablecoins.
    event BuyStable(bytes32 indexed ilkId, address indexed user, uint256 stableAmt, uint256 usdrAmt);

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Registers a stablecoin ilk. This is how new stablecoins are added to the module.
     * @dev The ilk must already be registered with the Collateral Adapter, and must not be the
     *      USDR ilk. The token and its decimals are read from the adapter.
     * @param ilkId Identifier of the stablecoin's collateral type.
     */
    function init(bytes32 ilkId) external;

    /**
     * @notice Adjusts a stablecoin's mint fee ("tin") or redeem fee ("tout"). Both zero at
     *         launch.
     * @param ilkId Identifier of the stablecoin's collateral type.
     * @param what Name of the parameter.
     * @param data New value [wad].
     */
    function file(bytes32 ilkId, bytes32 what, uint256 data) external;

    /**
     * @notice Converts stablecoins into USDR at a 1:1 rate.
     * @dev The mint must not push the stablecoin's total past its debt ceiling.
     * @param ilkId Identifier of the stablecoin's collateral type.
     * @param user Account that receives the USDR.
     * @param stableAmt Stablecoin amount, in the token's native decimals.
     */
    function sellStable(bytes32 ilkId, address user, uint256 stableAmt) external;

    /**
     * @notice Converts USDR back into stablecoins at 1:1 — when reserves allow.
     * @dev Best-effort by design: reverts if the amount exceeds the current free slack.
     * @param ilkId Identifier of the stablecoin's collateral type.
     * @param user Account that receives the stablecoins.
     * @param stableAmt Stablecoin amount, in the token's native decimals.
     */
    function buyStable(bytes32 ilkId, address user, uint256 stableAmt) external;
}
