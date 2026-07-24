// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/**
 * @title IDutchAuction.
 * @author Rain Team.
 * @notice Interface for the descending-price auction house that sells seized collateral.
 */
interface IDutchAuction {
    /* ========================== EVENTS ========================== */

    /// @notice Emitted when a numeric parameter is updated.
    event File(bytes32 indexed what, uint256 data);

    /// @notice Emitted when an address dependency is updated.
    event File(bytes32 indexed what, address addr);

    /// @notice Emitted when a new auction opens.
    event Kick(
        uint256 indexed id,
        uint256 top,
        uint256 tab,
        uint256 lot,
        address indexed usr,
        address indexed kpr,
        uint256 coin
    );

    /// @notice Emitted when a keeper buys from an auction.
    event Take(
        uint256 indexed id,
        uint256 max,
        uint256 price,
        uint256 owe,
        uint256 tab,
        uint256 lot,
        address indexed usr
    );

    /// @notice Emitted when a stale auction is reset.
    event Redo(
        uint256 indexed id,
        uint256 top,
        uint256 tab,
        uint256 lot,
        address indexed usr,
        address indexed kpr,
        uint256 coin
    );

    /// @notice Emitted when an auction is forcibly ended.
    event Yank(uint256 indexed id);

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Adjusts an auction parameter: "buf" (start markup), "tail" (reset time),
     *         "cusp" (reset threshold), "chip" (keeper reward) or "tip" (flat reward).
     * @param what Name of the parameter.
     * @param data New value.
     */
    function file(bytes32 what, uint256 data) external;

    /**
     * @notice Sets an address dependency: "pip", "dog", "vow" or "calc".
     * @param what Name of the parameter.
     * @param data New address.
     */
    function file(bytes32 what, address data) external;

    /**
     * @notice Opens a new auction for a seized vault's collateral.
     * @dev Only the Liquidation Trigger can call this. The starting price is set to the current
     *      market price plus the markup.
     * @param tab USDR debt to recover, including the penalty [rad].
     * @param lot Collateral for sale [wad].
     * @param usr Vault owner who receives any leftover collateral.
     * @param kpr Keeper eligible for the kick reward.
     * @return id Identifier of the new auction.
     */
    function kick(uint256 tab, uint256 lot, address usr, address kpr) external returns (uint256 id);

    /**
     * @notice Restarts an auction that has gone too long or fallen too far without a buyer.
     * @dev Reverts unless a reset condition holds. Whoever triggers the reset earns the reward.
     * @param id Identifier of the auction.
     * @param kpr Keeper eligible for the redo reward.
     */
    function redo(uint256 id, address kpr) external;

    /**
     * @notice Lets a keeper buy some or all of the collateral at the current descending price.
     * @dev Supports flash-loan-style buying via the callback. Reverts if the auction needs a
     *      reset or if the current price exceeds the keeper's maximum.
     * @param id Identifier of the auction.
     * @param amt Maximum collateral amount to buy [wad].
     * @param max Highest acceptable price [ray].
     * @param who Recipient of the collateral (may be a callback contract).
     * @param data Callback payload; non-empty triggers the flash-loan-style callback.
     */
    function take(uint256 id, uint256 amt, uint256 max, address who, bytes calldata data) external;

    /**
     * @notice Forcibly ends an auction, used during emergency shutdown.
     * @dev Only governance may call this via authorization.
     * @param id Identifier of the auction.
     */
    function yank(uint256 id) external;

    /**
     * @notice Returns the number of active auctions.
     * @return The active auction count.
     */
    function count() external view returns (uint256);

    /**
     * @notice Returns the ids of all active auctions.
     * @return Array of active auction ids.
     */
    function list() external view returns (uint256[] memory);

    /**
     * @notice Returns the status of an auction.
     * @param id Identifier of the auction.
     * @return needsRedo Whether the auction needs a reset.
     * @return price_ The current price [ray].
     * @return lot Collateral remaining [wad].
     * @return tab Debt remaining [rad].
     */
    function getStatus(uint256 id) external view returns (bool needsRedo, uint256 price_, uint256 lot, uint256 tab);
}
