// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { ILiquidationTrigger } from "./ILiquidationTrigger.sol";
import { IOracleSecurityModule } from "./IOracleSecurityModule.sol";
import { IPriceCurve } from "./IPriceCurve.sol";
import { IVaultEngine } from "./IVaultEngine.sol";

/**
 * @title IDutchAuction
 * @author Rain Team
 * @notice Interface for the descending-price auction house that sells seized collateral.
 */
interface IDutchAuction {
    /* ========================== TYPES ========================== */

    /**
     * @notice A live auction.
     * @param pos Index in the active auctions array.
     * @param tab USDR debt to recover, including the penalty [rad].
     * @param lot Collateral for sale [wad].
     * @param usr Vault owner who receives any leftover collateral.
     * @param tic Auction start time.
     * @param top Starting price [ray].
     */
    struct Sale {
        uint256 pos;
        uint256 tab;
        uint256 lot;
        address usr;
        uint96 tic;
        uint256 top;
    }

    /* ========================== EVENTS ========================== */

    /**
     * @dev Emitted when a numeric parameter is updated.
     * @param what Name of the parameter.
     * @param data New value.
     */
    event File(bytes32 indexed what, uint256 data);

    /**
     * @dev Emitted when an address dependency is updated.
     * @param what Name of the parameter.
     * @param addr New address.
     */
    event File(bytes32 indexed what, address addr);

    /**
     * @dev Emitted when a new auction opens.
     * @param id Identifier of the new auction.
     * @param top Starting price [ray].
     * @param tab USDR debt to recover, including the penalty [rad].
     * @param lot Collateral for sale [wad].
     * @param usr Vault owner who receives any leftover collateral.
     * @param kpr Keeper eligible for the kick reward.
     * @param coin Keeper reward created as backed-later debt [rad].
     */
    event Kick(
        uint256 indexed id,
        uint256 top,
        uint256 tab,
        uint256 lot,
        address indexed usr,
        address indexed kpr,
        uint256 coin
    );

    /**
     * @dev Emitted when a keeper buys from an auction.
     * @param id Identifier of the auction.
     * @param max Highest acceptable price stated by the keeper [ray].
     * @param price The price paid [ray].
     * @param owe USDR paid [rad].
     * @param tab Debt remaining [rad].
     * @param lot Collateral remaining [wad].
     * @param usr Vault owner who receives any leftover collateral.
     */
    event Take(
        uint256 indexed id,
        uint256 max,
        uint256 price,
        uint256 owe,
        uint256 tab,
        uint256 lot,
        address indexed usr
    );

    /**
     * @dev Emitted when a stale auction is reset.
     * @param id Identifier of the auction.
     * @param top Refreshed starting price [ray].
     * @param tab USDR debt to recover, including the penalty [rad].
     * @param lot Collateral for sale [wad].
     * @param usr Vault owner who receives any leftover collateral.
     * @param kpr Keeper eligible for the redo reward.
     * @param coin Keeper reward created as backed-later debt [rad].
     */
    event Redo(
        uint256 indexed id,
        uint256 top,
        uint256 tab,
        uint256 lot,
        address indexed usr,
        address indexed kpr,
        uint256 coin
    );

    /**
     * @dev Emitted when an auction is forcibly ended.
     * @param id Identifier of the auction.
     */
    event Yank(uint256 indexed id);

    /* ========================== ERRORS ========================== */

    /**
     * @dev Indicates that the auction debt is zero.
     */
    error ZeroTab();

    /**
     * @dev Indicates that the auction collateral is zero.
     */
    error ZeroLot();

    /**
     * @dev Indicates that the vault owner is the zero address.
     */
    error ZeroUser();

    /**
     * @dev Indicates that the computed starting price is zero.
     */
    error ZeroTopPrice();

    /**
     * @dev Indicates that the auction is not running.
     */
    error AuctionNotRunning();

    /**
     * @dev Indicates that the auction cannot be reset yet.
     */
    error CannotReset();

    /**
     * @dev Indicates that the auction needs a reset before it can be taken.
     */
    error NeedsReset();

    /**
     * @dev Indicates that the current price exceeds the keeper's stated maximum.
     */
    error TooExpensive();

    /**
     * @dev Indicates that a partial purchase would leave a dusty remainder.
     */
    error NoPartialPurchase();

    /**
     * @dev Indicates that the oracle price is invalid.
     */
    error InvalidPrice();

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Returns a live auction's details.
     * @param id Identifier of the auction.
     * @return pos Index in the active auctions array.
     * @return tab USDR debt to recover, including the penalty [rad].
     * @return lot Collateral for sale [wad].
     * @return usr Vault owner who receives any leftover collateral.
     * @return tic Auction start time.
     * @return top Starting price [ray].
     */
    function sales(
        uint256 id
    ) external view returns (uint256 pos, uint256 tab, uint256 lot, address usr, uint96 tic, uint256 top);

    /**
     * @notice Returns the Vault Engine this auction house reports to.
     */
    function VAULT_ENGINE() external view returns (IVaultEngine);

    /**
     * @notice Returns the identifier of the collateral type this auction house serves.
     */
    function ILK_ID() external view returns (bytes32);

    /**
     * @notice Returns the liquidation trigger.
     */
    function dog() external view returns (ILiquidationTrigger);

    /**
     * @notice Returns the collateral's Oracle Security Module, used for the starting price.
     */
    function pip() external view returns (IOracleSecurityModule);

    /**
     * @notice Returns the price curve calculator.
     */
    function calc() external view returns (IPriceCurve);

    /**
     * @notice Returns the balance sheet that receives auction proceeds.
     */
    function vow() external view returns (address);

    /**
     * @notice Returns the auction start markup [ray]. 5% = 1.05 * RAY.
     */
    function buf() external view returns (uint256);

    /**
     * @notice Returns the reset time in seconds, after which a stale auction may be reset.
     */
    function tail() external view returns (uint256);

    /**
     * @notice Returns the reset threshold [ray], below which a stale auction may be reset.
     */
    function cusp() external view returns (uint256);

    /**
     * @notice Returns the keeper reward as a fraction of tab [wad]. 2% = 0.02 * WAD.
     */
    function chip() external view returns (uint64);

    /**
     * @notice Returns the flat keeper reward [rad]. Zero for USDR, only the percentage is paid.
     */
    function tip() external view returns (uint192);

    /**
     * @notice Returns the auction id counter, the number of auctions started so far.
     */
    function kicks() external view returns (uint256);

    /**
     * @notice Returns the liveness flag. `1` while live, `0` after shutdown.
     */
    function live() external view returns (uint256);

    /**
     * @notice Returns the id of an active auction by its position.
     * @param index Position in the active auctions array.
     * @return The auction id.
     */
    function active(uint256 index) external view returns (uint256);

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

    /**
     * @notice Adjusts an auction parameter: "buf" (start markup), "tail" (reset time), "cusp" (reset threshold),
     *         "chip" (keeper reward) or "tip" (flat reward).
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
     * @dev Only the Liquidation Trigger can call this. The starting price is set to the current market price plus
     *      the markup.
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
     * @dev Supports flash-loan-style buying via the callback. Reverts if the auction needs a reset or if the current
     *      price exceeds the keeper's maximum.
     * @param id Identifier of the auction.
     * @param amt Maximum collateral amount to buy [wad].
     * @param max Highest acceptable price [ray].
     * @param who Recipient of the collateral (may be a callback contract).
     * @param data Callback payload. A non-empty value triggers the flash-loan-style callback.
     */
    function take(uint256 id, uint256 amt, uint256 max, address who, bytes calldata data) external;

    /**
     * @notice Forcibly ends an auction, used during emergency shutdown.
     * @dev Only governance may call this via authorization.
     * @param id Identifier of the auction.
     */
    function yank(uint256 id) external;
}
