// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/**
 * @title IDutchAuctionCallee.
 * @author Rain Team.
 * @notice Callback interface for flash-loan-style auction buying: the keeper buys the
 *         collateral, resells it elsewhere, and pays for the purchase in a single transaction.
 */
interface IDutchAuctionCallee {
    /**
     * @notice Called by the Dutch auction after transferring collateral to the callee.
     * @param sender The keeper that initiated the purchase.
     * @param owe The USDR payment due [rad].
     * @param slice The collateral received [wad].
     * @param data Arbitrary payload forwarded from the keeper.
     */
    function clipperCall(address sender, uint256 owe, uint256 slice, bytes calldata data) external;
}
