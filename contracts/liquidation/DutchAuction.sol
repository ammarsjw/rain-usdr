// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IDutchAuction } from "../interfaces/IDutchAuction.sol";
import { IDutchAuctionCallee } from "../interfaces/IDutchAuctionCallee.sol";
import { IGovernor } from "../interfaces/IGovernor.sol";
import { ILiquidationTrigger } from "../interfaces/ILiquidationTrigger.sol";
import { IOracleSecurityModule } from "../interfaces/IOracleSecurityModule.sol";
import { IPriceCurve } from "../interfaces/IPriceCurve.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { _PAUSE_AUCTION, _RAY, _WAD, _WARD_ROLE } from "../shared/Constants.sol";
import { InvalidAddress, InvalidBytes, NotLive, SystemPaused, UnrecognizedParameter } from "../shared/Errors.sol";
import { Cage } from "../shared/Events.sol";
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
    bytes32 public immutable ILK_ID;

    /// @inheritdoc IDutchAuction
    IVaultEngine public immutable VAULT_ENGINE;

    /// @inheritdoc IDutchAuction
    uint64 public chip;

    /// @inheritdoc IDutchAuction
    uint192 public tip;

    /// @inheritdoc IDutchAuction
    uint256 public buf;

    /// @inheritdoc IDutchAuction
    uint256 public tail;

    /// @inheritdoc IDutchAuction
    uint256 public cusp;

    /// @inheritdoc IDutchAuction
    uint256 public kicks;

    /// @inheritdoc IDutchAuction
    uint256 public chost;

    /// @inheritdoc IDutchAuction
    uint256 public stopped;

    /// @inheritdoc IDutchAuction
    uint256 public live;

    /// @inheritdoc IDutchAuction
    address public vow;

    /// @inheritdoc IDutchAuction
    address public governor;

    /// @inheritdoc IDutchAuction
    ILiquidationTrigger public dog;

    /// @inheritdoc IDutchAuction
    IOracleSecurityModule public pip;

    /// @inheritdoc IDutchAuction
    IPriceCurve public calc;

    /// @inheritdoc IDutchAuction
    uint256[] public active;

    /// @inheritdoc IDutchAuction
    mapping(uint256 id => Sale sale) public sales;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the auction house and marks it live.
     * @param ilkId_ Identifier of the collateral type.
     * @param vaultEngine_ Address of the Vault Engine.
     */
    constructor(bytes32 ilkId_, IVaultEngine vaultEngine_) {
        if (ilkId_ == bytes32(0)) {
            _revert(InvalidBytes.selector);
        }

        if (address(vaultEngine_) == address(0)) {
            _revert(InvalidAddress.selector);
        }

        _setRoleAdmin(_WARD_ROLE, _WARD_ROLE);

        _grantRole(_WARD_ROLE, msg.sender);

        ILK_ID = ilkId_;
        VAULT_ENGINE = vaultEngine_;

        buf = _RAY;
        live = 1;
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IDutchAuction
     */
    function file(bytes32 what, uint256 data) external onlyRole(_WARD_ROLE) {
        if (live != 1) {
            _revert(NotLive.selector);
        }

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
        } else if (what == "stopped") {
            // Breaker levels: 0 = normal, 1 = no new kicks, 2 = no new kicks or takes, 3 = no kicks, takes or redos.
            // Yank always stays available for settlement.
            stopped = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, data: data });
    }

    /**
     * @inheritdoc IDutchAuction
     */
    function file(bytes32 what, address data) external onlyRole(_WARD_ROLE) {
        if (live != 1) {
            _revert(NotLive.selector);
        }

        if (what == "pip") {
            pip = IOracleSecurityModule(data);
        } else if (what == "dog") {
            dog = ILiquidationTrigger(data);
        } else if (what == "vow") {
            vow = data;
        } else if (what == "calc") {
            calc = IPriceCurve(data);
        } else if (what == "governor") {
            governor = data;
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
        uint256 vaultId,
        address usr,
        address kpr
    ) external onlyRole(_WARD_ROLE) nonReentrant returns (uint256 id) {
        if (live != 1) {
            _revert(NotLive.selector);
        }

        // Breaker level 1+ stops new auctions; the governance pause is a full stop for the auction house too.
        _requireRunning(1);

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
        sales[id].vaultId = vaultId;
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

        emit Kick({ id: id, top: top, tab: tab, lot: lot, vaultId: vaultId, usr: usr, kpr: kpr, coin: coin });
    }

    /**
     * @inheritdoc IDutchAuction
     */
    function redo(uint256 id, address kpr) external nonReentrant {
        if (live != 1) {
            _revert(NotLive.selector);
        }

        // Breaker level 3 stops resets.
        _requireRunning(3);

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

        // Whoever triggers the reset earns the keeper reward for doing so, but only when the auction is large enough
        // to be worth resetting: both the remaining debt and the collateral's market value must be at least the cached
        // dust-times-chop threshold (chost). This prevents reward farming on tiny auctions.
        uint256 coin;

        if (tip > 0 || chip > 0) {
            if (tab >= chost && lot * feedPrice >= chost) {
                coin = tip + (tab * chip) / _WAD;

                VAULT_ENGINE.suck(vow, kpr, coin);
            }
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

        // Breaker level 2 stops purchases: during an oracle incident governance must be able to stop keepers buying
        // collateral at bad-feed prices, in-flight auctions included. The governance pause does too.
        _requireRunning(2);

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
                // A partial purchase must leave a remainder of at least chost. Instead of reverting outright, the
                // purchase is adjusted down so the remainder is exactly chost; only when the whole tab is at or below
                // chost is a partial purchase impossible.
                if (tab - owe < chost) {
                    if (tab <= chost) {
                        // Any partial purchase would leave a remainder below chost.
                        _revert(NoPartialPurchase.selector);
                    }

                    // Adjusting the purchase down to leave exactly chost behind.
                    owe = tab - chost;
                    slice = owe / price;
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

        // The remaining debt is freed from the liquidation capacity and the remaining collateral moves to the CALLER:
        // during emergency settlement the caller is the End, which reclaims the collateral into the the seized vault
        // so the position settles like every other. Handing it to the vault owner here instead would erase the debt
        // side and leak value at settlement.
        dog.digs(ILK_ID, sales[id].tab);
        VAULT_ENGINE.flux(ILK_ID, address(this), msg.sender, sales[id].lot);

        _remove(id);

        emit Yank({ id: id });
    }

    /**
     * @inheritdoc IDutchAuction
     */
    function upchost() external {
        (, , , , , uint256 dust, , ) = VAULT_ENGINE.ilks(ILK_ID);

        // Caching dust [rad] times the liquidation penalty chop [wad], scaled back to rad: wmul(dust, chop).
        chost = (dust * dog.chop(ILK_ID)) / _WAD;

        emit Upchost({ chost: chost });
    }

    /**
     * @inheritdoc IDutchAuction
     */
    function cage() external onlyRole(_WARD_ROLE) {
        live = 0;

        emit Cage();
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
     * @dev Reverts when the breaker is at or above `level`, or when the governance pause is active. Yank is never
     *      gated: emergency settlement must always be able to reclaim auctions.
     * @param level Breaker level at which the calling operation is stopped.
     */
    function _requireRunning(uint256 level) private view {
        if (stopped >= level) {
            _revert(Stopped.selector);
        }

        if (governor != address(0) && IGovernor(governor).paused(_PAUSE_AUCTION)) {
            _revert(SystemPaused.selector);
        }
    }

    /**
     * @dev Removes an auction from the active list.
     * @param id Identifier of the auction to remove.
     */
    function _remove(uint256 id) private {
        uint256 move = active[active.length - 1];

        if (id != move) {
            uint256 pos = sales[id].pos;

            active[pos] = move;
            sales[move].pos = pos;
        }

        active.pop();

        delete sales[id];
    }

    /**
     * @dev Reads the current delayed price from the Oracle Security Module, scaled to ray.
     * @return feedPrice The current delayed price [ray].
     */
    function _getFeedPrice() private view returns (uint256 feedPrice) {
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
    function _status(uint96 tic, uint256 top) private view returns (bool done, uint256 price) {
        price = calc.price(top, block.timestamp - tic);
        done = (block.timestamp - tic > tail || (price * _RAY) / top < cusp);
    }
}
