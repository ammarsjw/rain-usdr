// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IDutchAuction } from "../interfaces/IDutchAuction.sol";
import { IDutchAuctionCallee } from "../interfaces/IDutchAuctionCallee.sol";
import { ILiquidationTrigger } from "../interfaces/ILiquidationTrigger.sol";
import { IOracleSecurityModule } from "../interfaces/IOracleSecurityModule.sol";
import { IPriceCurve } from "../interfaces/IPriceCurve.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { _RAY, _WAD, _WARD_ROLE } from "../shared/Constants.sol";
import { NotLive, UnrecognizedParameter } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title DutchAuction
 * @author Rain Team
 * @notice The auction house. Runs each liquidation as a Dutch auction. The collateral starts at a price above market
 *         and falls over time until a keeper buys it. It settles instantly, needs no locked capital from bidders, and
 *         supports flash-loan-style buying where the keeper buys and resells in one transaction.
 * @dev One instance per collateral type.
 */
contract DutchAuction is IDutchAuction, AccessControl, ReentrancyGuard {
    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc IDutchAuction
    IVaultEngine public immutable VAULT_ENGINE;

    /// @inheritdoc IDutchAuction
    bytes32 public immutable ILK_ID;

    /// @inheritdoc IDutchAuction
    ILiquidationTrigger public dog;

    /// @inheritdoc IDutchAuction
    IOracleSecurityModule public pip;

    /// @inheritdoc IDutchAuction
    IPriceCurve public calc;

    /// @inheritdoc IDutchAuction
    address public vow;

    /// @inheritdoc IDutchAuction
    uint256 public buf;

    /// @inheritdoc IDutchAuction
    uint256 public tail;

    /// @inheritdoc IDutchAuction
    uint256 public cusp;

    /// @inheritdoc IDutchAuction
    uint64 public chip;

    /// @inheritdoc IDutchAuction
    uint192 public tip;

    /// @inheritdoc IDutchAuction
    uint256 public kicks;

    /// @inheritdoc IDutchAuction
    uint256 public live;

    /// @inheritdoc IDutchAuction
    uint256[] public active;

    /// @inheritdoc IDutchAuction
    mapping(uint256 id => Sale sale) public sales;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the auction house and marks it live.
     * @param vaultEngine_ Address of the Vault Engine.
     * @param ilkId_ Identifier of the collateral type.
     */
    constructor(IVaultEngine vaultEngine_, bytes32 ilkId_) {
        _setRoleAdmin(_WARD_ROLE, _WARD_ROLE);
        _grantRole(_WARD_ROLE, msg.sender);

        VAULT_ENGINE = vaultEngine_;
        ILK_ID = ilkId_;
        buf = _RAY;
        live = 1;
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IDutchAuction
     */
    function file(bytes32 what, uint256 data) external onlyRole(_WARD_ROLE) {
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
    function file(bytes32 what, address data) external onlyRole(_WARD_ROLE) {
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

    /**
     * @inheritdoc IDutchAuction
     */
    function kick(
        uint256 tab,
        uint256 lot,
        address usr,
        address kpr
    ) external onlyRole(_WARD_ROLE) nonReentrant returns (uint256 id) {
        if (live != 1) {
            _revert(NotLive.selector);
        }
        if (tab == 0) {
            _revert(ZeroTab.selector);
        }
        if (lot == 0) {
            _revert(ZeroLot.selector);
        }
        if (usr == address(0)) {
            _revert(ZeroUser.selector);
        }

        id = ++kicks;
        active.push(id);

        sales[id].pos = active.length - 1;
        sales[id].tab = tab;
        sales[id].lot = lot;
        sales[id].usr = usr;
        sales[id].tic = uint96(block.timestamp);

        // The starting price is the current market price plus the markup (5%).
        uint256 top = (_getFeedPrice() * buf) / _RAY;
        if (top == 0) {
            _revert(ZeroTopPrice.selector);
        }
        sales[id].top = top;

        // Incentive to kick the auction: the keeper reward is created as backed-later debt.
        uint256 coin;
        if (tip > 0 || chip > 0) {
            coin = tip + (tab * chip) / _WAD;
            VAULT_ENGINE.suck(vow, kpr, coin);
        }

        emit Kick({ id: id, top: top, tab: tab, lot: lot, usr: usr, kpr: kpr, coin: coin });
    }

    /**
     * @inheritdoc IDutchAuction
     */
    function redo(uint256 id, address kpr) external nonReentrant {
        if (live != 1) {
            _revert(NotLive.selector);
        }

        address usr = sales[id].usr;
        uint96 tic = sales[id].tic;
        uint256 top = sales[id].top;

        if (usr == address(0)) {
            _revert(AuctionNotRunning.selector);
        }

        // At least one reset condition must hold: the auction has run past its reset time, or its price has dropped
        // below the reset threshold of the starting price.
        (bool done, ) = _status(tic, top);
        if (!done) {
            _revert(CannotReset.selector);
        }

        uint256 tab = sales[id].tab;
        uint256 lot = sales[id].lot;
        sales[id].tic = uint96(block.timestamp);

        // The starting price is refreshed to the current market price plus the markup.
        uint256 feedPrice = _getFeedPrice();
        top = (feedPrice * buf) / _RAY;
        if (top == 0) {
            _revert(ZeroTopPrice.selector);
        }
        sales[id].top = top;

        // Whoever triggers the reset earns the keeper reward for doing so.
        uint256 coin;
        if (tip > 0 || chip > 0) {
            coin = tip + (tab * chip) / _WAD;
            VAULT_ENGINE.suck(vow, kpr, coin);
        }

        emit Redo({ id: id, top: top, tab: tab, lot: lot, usr: usr, kpr: kpr, coin: coin });
    }

    /**
     * @inheritdoc IDutchAuction
     */
    function take(uint256 id, uint256 amt, uint256 max, address who, bytes calldata data) external nonReentrant {
        if (live != 1) {
            _revert(NotLive.selector);
        }

        address usr = sales[id].usr;
        uint96 tic = sales[id].tic;

        if (usr == address(0)) {
            _revert(AuctionNotRunning.selector);
        }

        uint256 price;
        {
            bool done;
            (done, price) = _status(tic, sales[id].top);

            // The auction must still be running and the price must be greater than zero.
            if (done) {
                _revert(NeedsReset.selector);
            }
        }

        // The current price must not exceed the keeper's stated maximum price.
        if (max < price) {
            _revert(TooExpensive.selector);
        }

        uint256 lot = sales[id].lot;
        uint256 tab = sales[id].tab;
        uint256 owe;

        {
            // The amount requested must not exceed the collateral remaining.
            uint256 slice = Math.min(lot, amt);

            // The keeper pays the current price times the amount.
            owe = slice * price;

            if (owe > tab) {
                // Never collecting more than the outstanding debt.
                owe = tab;
                slice = owe / price;
            } else if (owe < tab && slice < lot) {
                // A partial purchase must leave a non-dusty remainder.
                (, , , , uint256 dust) = VAULT_ENGINE.ilks(ILK_ID);

                if (tab - owe < dust) {
                    _revert(NoPartialPurchase.selector);
                }
            }

            tab -= owe;
            lot -= slice;

            // Sending the collateral to the keeper (or their callback contract).
            VAULT_ENGINE.flux(ILK_ID, address(this), who, slice);

            // Flash-loan-style buying: the callback can resell the collateral and pay in the same transaction.
            if (data.length > 0 && who != address(VAULT_ENGINE) && who != address(dog)) {
                IDutchAuctionCallee(who).clipperCall(msg.sender, owe, slice, data);
            }

            // Collecting payment from the keeper and covering the corresponding debt.
            VAULT_ENGINE.move(msg.sender, vow, owe);

            // Freeing auction capacity for the covered portion.
            dog.digs(ILK_ID, lot == 0 ? tab + owe : owe);

            emit Take({ id: id, max: max, price: price, owe: owe, tab: tab, lot: lot, usr: usr });
        }

        if (lot == 0) {
            _remove(id);
        } else if (tab == 0) {
            // All the debt is covered and collateral remains: the leftover is returned to the original vault owner.
            VAULT_ENGINE.flux(ILK_ID, address(this), usr, lot);
            _remove(id);
        } else {
            sales[id].tab = tab;
            sales[id].lot = lot;
        }
    }

    /**
     * @inheritdoc IDutchAuction
     */
    function yank(uint256 id) external onlyRole(_WARD_ROLE) nonReentrant {
        if (sales[id].usr == address(0)) {
            _revert(AuctionNotRunning.selector);
        }

        // The remaining debt goes back to the balance sheet and the remaining collateral returns to the vault owner.
        dog.digs(ILK_ID, sales[id].tab);
        VAULT_ENGINE.flux(ILK_ID, address(this), sales[id].usr, sales[id].lot);
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
    function getStatus(uint256 id) external view returns (bool needsRedo, uint256 price, uint256 lot, uint256 tab) {
        address usr = sales[id].usr;
        uint96 tic = sales[id].tic;
        bool done;

        (done, price) = _status(tic, sales[id].top);

        needsRedo = usr != address(0) && done;
        lot = sales[id].lot;
        tab = sales[id].tab;
    }

    /**
     * @dev Removes an auction from the active list.
     * @param id Identifier of the auction to remove.
     */
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

    /**
     * @dev Reads the current delayed price from the Oracle Security Module, scaled to ray.
     * @return feedPrice The current delayed price [ray].
     */
    function _getFeedPrice() internal view returns (uint256 feedPrice) {
        (bytes32 val, bool has) = pip.peek(ILK_ID);
        if (!has) {
            _revert(InvalidPrice.selector);
        }

        feedPrice = (uint256(val) * _RAY) / _WAD;
    }

    /**
     * @dev Returns whether an auction is done (needs reset) and its current price.
     * @param tic Auction start time.
     * @param top Starting price [ray].
     * @return done Whether the auction needs a reset.
     * @return price The current price [ray].
     */
    function _status(uint96 tic, uint256 top) internal view returns (bool done, uint256 price) {
        price = calc.price(top, block.timestamp - tic);
        done = (block.timestamp - tic > tail || (price * _RAY) / top < cusp);
    }
}
