// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IBalanceSheet } from "../interfaces/IBalanceSheet.sol";
import { IDutchAuction } from "../interfaces/IDutchAuction.sol";
import { IDutchAuctionCallee } from "../interfaces/IDutchAuctionCallee.sol";
import { ILiquidationTrigger } from "../interfaces/ILiquidationTrigger.sol";
import { IOracleSecurityModule } from "../interfaces/IOracleSecurityModule.sol";
import { IPriceCurve } from "../interfaces/IPriceCurve.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { RAY, WAD } from "../shared/Constants.sol";
import { NotAuthorized, NotLive, UnrecognizedParameter } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title DutchAuction.
 * @author Rain Team.
 * @notice The auction house. Runs each liquidation as a Dutch auction: the collateral starts at
 *         a price above market and falls over time until a keeper buys it. It settles instantly,
 *         needs no locked capital from bidders, and supports flash-loan-style buying where the
 *         keeper buys and resells in one transaction.
 * @dev Based on MakerDAO's Clipper (Liquidation 2.0). One instance per collateral type.
 */
contract DutchAuction is IDutchAuction {
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

    /* ========================== STATE VARIABLES ========================== */

    /// @notice Authorized accounts. `wards[account] == 1` grants authorization.
    mapping(address account => uint256 authorization) public wards;

    /// @notice Live auctions, keyed by id.
    mapping(uint256 id => Sale sale) public sales;

    /// @notice The Vault Engine (core ledger).
    IVaultEngine public immutable vaultEngine;

    /// @notice Identifier of the collateral type this auction house serves.
    bytes32 public immutable ilkId;

    /// @notice The liquidation trigger.
    ILiquidationTrigger public dog;

    /// @notice The balance sheet that receives auction proceeds.
    address public vow;

    /// @notice The collateral's Oracle Security Module, used for the starting price.
    IOracleSecurityModule public pip;

    /// @notice The price curve calculator.
    IPriceCurve public calc;

    /// @notice Auction start markup [ray]. 5% = 1.05 * RAY.
    uint256 public buf;

    /// @notice Reset time in seconds — a stale auction may be reset after this long.
    uint256 public tail;

    /// @notice Reset threshold [ray] — a stale auction may be reset below this fraction of start.
    uint256 public cusp;

    /// @notice Keeper reward as a fraction of tab [wad]. 2% = 0.02 * WAD.
    uint64 public chip;

    /// @notice Flat keeper reward [rad]. Zero for USDR — only the percentage is paid.
    uint192 public tip;

    /// @notice Auction id counter.
    uint256 public kicks;

    /// @notice Ids of active auctions.
    uint256[] public active;

    /// @notice Liveness flag. `1` while live, `0` after shutdown.
    uint256 public live;

    /* ========================== MODIFIERS ========================== */

    /// @dev Restricts a function to authorized accounts.
    modifier auth() {
        if (wards[msg.sender] != 1) {
            _revert(NotAuthorized.selector);
        }
        _;
    }

    /// @dev Reentrancy guard.
    uint256 private locked;

    modifier lock() {
        require(locked == 0, "DutchAuction/system-locked");

        locked = 1;
        _;
        locked = 0;
    }

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the auction house and marks it live.
     * @param vaultEngine_ Address of the Vault Engine.
     * @param ilkId_ Identifier of the collateral type.
     */
    constructor(IVaultEngine vaultEngine_, bytes32 ilkId_) {
        wards[msg.sender] = 1;
        vaultEngine = vaultEngine_;
        ilkId = ilkId_;
        buf = RAY;
        live = 1;

        emit Rely({ account: msg.sender });
    }

    /* ========================== ADMINISTRATION ========================== */

    /**
     * @inheritdoc IDutchAuction
     */
    function rely(address account) external auth {
        wards[account] = 1;

        emit Rely({ account: account });
    }

    /**
     * @inheritdoc IDutchAuction
     */
    function deny(address account) external auth {
        wards[account] = 0;

        emit Deny({ account: account });
    }

    /**
     * @inheritdoc IDutchAuction
     */
    function file(bytes32 what, uint256 data) external auth {
        if (what == "buf") {
            buf = data;
        } else if (what == "tail") {
            tail = data;
        } else if (what == "cusp") {
            cusp = data;
        } else if (what == "chip") {
            chip = uint64(data);
        } else if (what == "tip") {
            tip = uint192(data);
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, data: data });
    }

    /**
     * @inheritdoc IDutchAuction
     */
    function file(bytes32 what, address data) external auth {
        if (what == "pip") {
            pip = IOracleSecurityModule(data);
        } else if (what == "dog") {
            dog = ILiquidationTrigger(data);
        } else if (what == "vow") {
            vow = data;
        } else if (what == "calc") {
            calc = IPriceCurve(data);
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, addr: data });
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IDutchAuction
     */
    function kick(uint256 tab, uint256 lot, address usr, address kpr) external auth lock returns (uint256 id) {
        if (live != 1) {
            _revert(NotLive.selector);
        }
        require(tab > 0, "DutchAuction/zero-tab");
        require(lot > 0, "DutchAuction/zero-lot");
        require(usr != address(0), "DutchAuction/zero-usr");

        id = ++kicks;
        active.push(id);

        sales[id].pos = active.length - 1;
        sales[id].tab = tab;
        sales[id].lot = lot;
        sales[id].usr = usr;
        sales[id].tic = uint96(block.timestamp);

        // The starting price is the current market price plus the markup (5%).
        uint256 top = (_getFeedPrice() * buf) / RAY;
        require(top > 0, "DutchAuction/zero-top-price");
        sales[id].top = top;

        // Incentive to kick the auction: the keeper reward is created as backed-later debt.
        uint256 coin;
        if (tip > 0 || chip > 0) {
            coin = tip + (tab * chip) / WAD;
            vaultEngine.suck(vow, kpr, coin);
        }

        emit Kick({ id: id, top: top, tab: tab, lot: lot, usr: usr, kpr: kpr, coin: coin });
    }

    /**
     * @inheritdoc IDutchAuction
     */
    function redo(uint256 id, address kpr) external lock {
        if (live != 1) {
            _revert(NotLive.selector);
        }

        address usr = sales[id].usr;
        uint96 tic = sales[id].tic;
        uint256 top = sales[id].top;

        require(usr != address(0), "DutchAuction/not-running-auction");

        // At least one reset condition must hold: the auction has run past its reset time, or
        // its price has dropped below the reset threshold of the starting price.
        (bool done, ) = status(tic, top);
        require(done, "DutchAuction/cannot-reset");

        uint256 tab = sales[id].tab;
        uint256 lot = sales[id].lot;
        sales[id].tic = uint96(block.timestamp);

        // The starting price is refreshed to the current market price plus the markup.
        uint256 feedPrice = _getFeedPrice();
        top = (feedPrice * buf) / RAY;
        require(top > 0, "DutchAuction/zero-top-price");
        sales[id].top = top;

        // Whoever triggers the reset earns the keeper reward for doing so.
        uint256 coin;
        if (tip > 0 || chip > 0) {
            coin = tip + (tab * chip) / WAD;
            vaultEngine.suck(vow, kpr, coin);
        }

        emit Redo({ id: id, top: top, tab: tab, lot: lot, usr: usr, kpr: kpr, coin: coin });
    }

    /**
     * @inheritdoc IDutchAuction
     */
    function take(uint256 id, uint256 amt, uint256 max, address who, bytes calldata data) external lock {
        if (live != 1) {
            _revert(NotLive.selector);
        }

        address usr = sales[id].usr;
        uint96 tic = sales[id].tic;

        require(usr != address(0), "DutchAuction/not-running-auction");

        uint256 price_;
        {
            bool done;
            (done, price_) = status(tic, sales[id].top);

            // The auction must still be running and the price must be greater than zero.
            require(!done, "DutchAuction/needs-reset");
        }

        // The current price must not exceed the keeper's stated maximum price.
        require(max >= price_, "DutchAuction/too-expensive");

        uint256 lot = sales[id].lot;
        uint256 tab = sales[id].tab;
        uint256 owe;

        {
            // The amount requested must not exceed the collateral remaining.
            uint256 slice = _min(lot, amt);

            // The keeper pays the current price times the amount.
            owe = slice * price_;

            if (owe > tab) {
                // Never collecting more than the outstanding debt.
                owe = tab;
                slice = owe / price_;
            } else if (owe < tab && slice < lot) {
                // A partial purchase must leave a non-dusty remainder.
                (, , , , uint256 dust) = vaultEngine.ilks(ilkId);

                require(tab - owe >= dust, "DutchAuction/no-partial-purchase");
            }

            tab -= owe;
            lot -= slice;

            // Sending the collateral to the keeper (or their callback contract).
            vaultEngine.flux(ilkId, address(this), who, slice);

            // Flash-loan-style buying: the callback can resell the collateral and pay in the
            // same transaction.
            if (data.length > 0 && who != address(vaultEngine) && who != address(dog)) {
                IDutchAuctionCallee(who).clipperCall(msg.sender, owe, slice, data);
            }

            // Collecting payment from the keeper and covering the corresponding debt.
            vaultEngine.move(msg.sender, vow, owe);

            // Freeing auction capacity for the covered portion.
            dog.digs(ilkId, lot == 0 ? tab + owe : owe);

            emit Take({ id: id, max: max, price: price_, owe: owe, tab: tab, lot: lot, usr: usr });
        }

        if (lot == 0) {
            _remove(id);
        } else if (tab == 0) {
            // All the debt is covered and collateral remains: the leftover is returned to the
            // original vault owner.
            vaultEngine.flux(ilkId, address(this), usr, lot);
            _remove(id);
        } else {
            sales[id].tab = tab;
            sales[id].lot = lot;
        }
    }

    /**
     * @inheritdoc IDutchAuction
     */
    function yank(uint256 id) external auth lock {
        require(sales[id].usr != address(0), "DutchAuction/not-running-auction");

        // The remaining debt goes back to the balance sheet and the remaining collateral
        // returns to the vault owner.
        dog.digs(ilkId, sales[id].tab);
        vaultEngine.flux(ilkId, address(this), sales[id].usr, sales[id].lot);
        _remove(id);

        emit Yank({ id: id });
    }

    /**
     * @inheritdoc IDutchAuction
     */
    function count() external view returns (uint256) {
        return active.length;
    }

    /**
     * @inheritdoc IDutchAuction
     */
    function list() external view returns (uint256[] memory) {
        return active;
    }

    /**
     * @inheritdoc IDutchAuction
     */
    function getStatus(uint256 id) external view returns (bool needsRedo, uint256 price_, uint256 lot, uint256 tab) {
        address usr = sales[id].usr;
        uint96 tic = sales[id].tic;
        bool done;

        (done, price_) = status(tic, sales[id].top);

        needsRedo = usr != address(0) && done;
        lot = sales[id].lot;
        tab = sales[id].tab;
    }

    /// @dev Returns whether an auction is done (needs reset) and its current price.
    function status(uint96 tic, uint256 top) internal view returns (bool done, uint256 price_) {
        price_ = calc.price(top, block.timestamp - tic);
        done = (block.timestamp - tic > tail || (price_ * RAY) / top < cusp);
    }

    /* ========================== INTERNAL HELPERS ========================== */

    /// @dev Reads the current delayed price from the Oracle Security Module, scaled to ray.
    function _getFeedPrice() internal view returns (uint256 feedPrice) {
        (bytes32 val, bool has) = pip.peek();
        require(has, "DutchAuction/invalid-price");

        feedPrice = (uint256(val) * RAY) / WAD;
    }

    /// @dev Removes an auction from the active list.
    function _remove(uint256 id) internal {
        uint256 move_ = active[active.length - 1];

        if (id != move_) {
            uint256 pos = sales[id].pos;
            active[pos] = move_;
            sales[move_].pos = pos;
        }

        active.pop();
        delete sales[id];
    }

    /// @dev Returns the smaller of two numbers.
    function _min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x <= y ? x : y;
    }
}
