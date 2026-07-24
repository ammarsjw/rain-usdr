// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/**
 * @title IPegStabilityModule.
 * @author Rain Team.
 * @notice Interface for the module that swaps stablecoins for USDR at 1:1.
 */
interface IPegStabilityModule {
    /* ========================== EVENTS ========================== */

    /// @notice Emitted when a fee parameter is updated.
    event File(bytes32 indexed what, uint256 data);

    /// @notice Emitted when a user converts stablecoins into USDR.
    event SellStable(address indexed user, uint256 stableAmt, uint256 usdrAmt);

    /// @notice Emitted when a user redeems USDR for stablecoins.
    event BuyStable(address indexed user, uint256 stableAmt, uint256 usdrAmt);

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Adjusts the mint fee ("tin") or the redeem fee ("tout"). Both zero at launch.
     * @param what Name of the parameter.
     * @param data New value [wad].
     */
    function file(bytes32 what, uint256 data) external;

    /**
     * @notice Converts stablecoins into USDR at a 1:1 rate.
     * @dev The mint must not push the stablecoin's total past its debt ceiling.
     * @param user Account that receives the USDR.
     * @param stableAmt Stablecoin amount, in the token's native decimals.
     */
    function sellStable(address user, uint256 stableAmt) external;

    /**
     * @notice Converts USDR back into stablecoins at 1:1 — when reserves allow.
     * @dev Best-effort by design: reverts if the amount exceeds the current free slack.
     * @param user Account that receives the stablecoins.
     * @param stableAmt Stablecoin amount, in the token's native decimals.
     */
    function buyStable(address user, uint256 stableAmt) external;
}
