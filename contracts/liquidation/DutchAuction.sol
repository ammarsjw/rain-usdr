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
import { _RAY, _WAD, _WARD_ROLE } from "../shared/Constants.sol";
import { InvalidAddress, InvalidAmount, InvalidBytes, NotLive, SystemPaused, UnrecognizedParameter } from "../shared/Errors.sol";
import { Cage } from "../shared/Events.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title DutchAuction
 * @author Rain Team
 * @notice The auction house. Runs each liquidation as a Dutch auction. The collateral starts at a price above
 *         market and falls over time until a keeper buys it. It settles instantly, needs no locked capital
 *         from bidders, and supports flash-loan-style buying where the keeper buys and resells in one
 *         transaction.
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
    uint256 public live;

    /// @inheritdoc IDutchAuction
    uint256 public stopped;

    /// @notice Fraction of an auction's initial tab available as its lifetime redo-reward budget [wad]
    ///         (audit M17): every redo pays tip + tab * chip without reducing tab, so an untaken auction —
    ///         breaker level 2, a keeper outage, or an illiquid market — would otherwise mint the same reward
    ///         after every tail interval without bound (50 resets at the launch chip of 2% mint 100% of the
    ///         auction debt as bad debt). The budget caps only the PAYOUT: resets themselves stay callable so
    ///         a stale auction can always refresh its price. Defaults to 10% of the initial tab.
    uint256 public redoRewardCap;

    /// @dev Lifetime redo-reward budget per auction, fixed at kick (audit M17). Cleared in _remove.
    mapping(uint256 id => uint256 budget) private _redoBudget;

    /// @dev Cumulative redo rewards paid per auction (audit M17). Cleared in _remove.
    mapping(uint256 id => uint256 paid) private _redoPaid;

    /// @inheritdoc IDutchAuction
    uint256 public totalTab;

    /// @inheritdoc IDutchAuction
    uint256 public totalLot;

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

        // The starting-price markup defaults to the documented 5% (audit R05): kick and redo document the
        // starting price as market plus markup, and a buf of exactly RAY silently starts every auction AT
        // market — each moment of decay then sells below it, costing vault owners residual collateral and
        // the protocol recovery, with no signal distinguishing that from a deliberate no-markup house.
        buf = (_RAY * 105) / 100;

        // Lifetime redo-reward budget default (audit M17): 10% of the initial tab.
        redoRewardCap = _WAD / 10;

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
            // The markup must be at least RAY (audit L10 + R05): a buf below RAY would START every auction
            // below market, guaranteeing under-recovery, and a zero buf makes kick revert ZeroTopPrice for
            // every liquidation.
            if (data < _RAY) {
                _revert(InvalidAmount.selector);
            }

            buf = data;
        } else if (what == "redoRewardCap") {
            // The lifetime redo-reward budget fraction lives in [0, WAD] (audit M17): above WAD would budget
            // more than the auction's own tab. Zero is allowed — it disables redo rewards entirely while
            // resets stay callable.
            if (data > _WAD) {
                _revert(InvalidAmount.selector);
            }

            redoRewardCap = data;
        } else if (what == "tail") {
            // A zero tail would leave the reset-time disjunct of done permanently false at configuration
            // level (audit M06 hardening): tail is the auction's lifetime bound and must be set.
            if (data == 0) {
                _revert(InvalidAmount.selector);
            }

            tail = data;
        } else if (what == "cusp") {
            // cusp must be in (0, _RAY) (audit M06): a zero cusp makes the price-collapse disjunct of done
            // read 0 < 0 = false, so a zero curve price would not mark the auction done — the exact gap the
            // direct price check in take also closes; belt and braces at the configuration layer. A cusp at
            // or above RAY would mark every auction done the moment it starts.
            if (data == 0 || data >= _RAY) {
                _revert(InvalidAmount.selector);
            }

            cusp = data;
        } else if (what == "chip") {
            // Checked narrowing (audit L10): an out-of-range value is rejected rather than silently truncated
            // to an unrelated number while the File event reports the value that was requested — leaving
            // monitoring showing a parameter the contract does not hold.
            if (data > type(uint64).max) {
                _revert(InvalidAmount.selector);
            }

            chip = uint64(data);
        } else if (what == "tip") {
            // Checked narrowing (audit L10), same rationale as chip.
            if (data > type(uint192).max) {
                _revert(InvalidAmount.selector);
            }

            tip = uint192(data);
        } else if (what == "stopped") {
            // Breaker levels: 0 = normal, 1 = no new kicks, 2 = no new kicks or takes, 3 = no kicks, takes or
            // redos. Yank always stays available for settlement. Values above 3 are outside the documented
            // range and rejected (audit L10).
            if (data > 3) {
                _revert(InvalidAmount.selector);
            }

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

        // Recorded on the active-time clock (audit M08), the same clock _status measures against.
        sales[id].tic = uint96(_clock());

        // The starting price is the current market price plus the markup (5%).
        uint256 top = (_getFeedPrice() * buf) / _RAY;

        if (top == 0) {
            _revert(ZeroTopPrice.selector);
        }

        sales[id].top = top;

        // Fixing the auction's lifetime redo-reward budget from its initial tab (audit M17): every redo pays
        // from this budget and _remove clears it, so an untaken auction can never mint more than the
        // configured fraction of its own debt in cumulative reset rewards.
        _redoBudget[id] = (tab * redoRewardCap) / _WAD;

        // Tracking aggregate in-auction exposure so the Solvency Engine can price seized-but-unsettled risk.
        totalTab += tab;
        totalLot += lot;

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

        // At least one reset condition must hold: the auction has run past its reset time, or its price has
        // dropped below the reset threshold of the starting price.
        (bool done, ) = _status(tic, top);

        if (!done) {
            _revert(CannotReset.selector);
        }

        uint256 tab = sales[id].tab;
        uint256 lot = sales[id].lot;

        // Refreshed on the active-time clock (audit M08), the same clock _status measures against.
        sales[id].tic = uint96(_clock());

        // The starting price is refreshed to the current market price plus the markup.
        uint256 feedPrice = _getFeedPrice();

        top = (feedPrice * buf) / _RAY;

        if (top == 0) {
            _revert(ZeroTopPrice.selector);
        }

        sales[id].top = top;

        // Whoever triggers the reset earns the keeper reward for doing so, but only when the auction is large
        // enough to be worth resetting: both the remaining debt and the collateral's market value must be at
        // least the cached dust-times-chop threshold (chost). This prevents reward farming on tiny auctions.
        uint256 coin;

        if (tip > 0 || chip > 0) {
            if (tab >= chost && lot * feedPrice >= chost) {
                coin = tip + (tab * chip) / _WAD;

                // Lifetime budget cap (audit M17): the payout is bounded by what remains of the budget fixed
                // at kick, so repeated resets of one untaken auction (breaker level 2, keeper outage,
                // illiquid market) cannot mint unbounded USDR and matching bad debt. Only the PAYOUT is
                // capped — the reset itself proceeds so a stale auction can always refresh its price, and a
                // zero coin simply skips the suck.
                uint256 remaining = _redoBudget[id] > _redoPaid[id] ? _redoBudget[id] - _redoPaid[id] : 0;

                if (coin > remaining) {
                    coin = remaining;
                }

                if (coin > 0) {
                    _redoPaid[id] += coin;

                    VAULT_ENGINE.suck(vow, kpr, coin);
                }
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

        // Breaker level 2 stops purchases: during an oracle incident governance must be able to stop keepers
        // buying collateral at bad-feed prices, in-flight auctions included. The governance pause does too.
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

            // The auction must still be running.
            if (done) {
                _revert(NeedsReset.selector);
            }
        }

        // The price is checked DIRECTLY rather than inferred from done (audit M06): the zero-price disjunct
        // in _status is (price * RAY) / top < cusp, which with an unfiled cusp of zero evaluates 0 < 0 =
        // false — so when the curve reaches zero (dur >= tau) while still inside tail, take would proceed at
        // price 0: owe = slice * 0 = 0 skips both adjustment branches, the FULL lot fluxes to the keeper,
        // zero moves to the vow, and the sale is deleted. The guarantee must not depend on a parameter being
        // configured.
        if (price == 0) {
            _revert(ZeroPrice.selector);
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
                // A partial purchase must leave a remainder of at least chost. Instead of reverting outright,
                // the purchase is adjusted down so the remainder is exactly chost; only when the whole tab is
                // at or below chost is a partial purchase impossible.
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

            // The covered debt and sold collateral leave the aggregate in-auction exposure.
            totalTab -= owe;
            totalLot -= slice;

            // Sending the collateral to the keeper (or their callback contract).
            VAULT_ENGINE.flux(ILK_ID, address(this), who, slice);

            // Flash-loan-style buying: the callback can resell the collateral and pay in the same
            // transaction.
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
            // The lot is exhausted: any unrecovered tab leaves the in-auction exposure here and lands on the
            // balance sheet as bad debt, where the absorption waterfall (not the solvency term) owns it.
            totalTab -= tab;

            _remove(id);
        } else if (tab == 0) {
            // All the debt is covered and collateral remains: the leftover is returned to the original vault
            // owner and leaves the in-auction exposure.
            totalLot -= lot;

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

        // The remaining debt is freed from the liquidation capacity and the remaining collateral moves to the
        // CALLER: during emergency settlement the caller is the End, which reclaims the collateral into the
        // the seized vault so the position settles like every other. Handing it to the vault owner here
        // instead would erase the debt side and leak value at settlement.
        totalTab -= sales[id].tab;
        totalLot -= sales[id].lot;

        dog.digs(ILK_ID, sales[id].tab);
        VAULT_ENGINE.flux(ILK_ID, address(this), msg.sender, sales[id].lot);

        _remove(id);

        emit Yank({ id: id });
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
    function upchost() external {
        (, , , , , uint256 dust, , ) = VAULT_ENGINE.ilks(ILK_ID);

        // Caching dust [rad] times the liquidation penalty chop [wad], scaled back to rad: wmul(dust, chop).
        chost = (dust * dog.chop(ILK_ID)) / _WAD;

        emit Upchost({ chost: chost });
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
     * @dev Reverts when the breaker is at or above `level`, or when the governance pause is active. Yank is
     *      never gated: emergency settlement must always be able to reclaim auctions.
     * @param level Breaker level at which the calling operation is stopped.
     */
    function _requireRunning(uint256 level) private view {
        if (stopped >= level) {
            _revert(Stopped.selector);
        }

        if (governor != address(0) && IGovernor(governor).paused()) {
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

        // Clearing the redo-reward budget accounting with the sale (audit M17): auction ids are never
        // reused, but stale entries would still bloat state forever.
        delete _redoBudget[id];
        delete _redoPaid[id];

        delete sales[id];
    }

    /**
     * @dev Returns the active-time clock (audit M08): the Governor's monotonic clock that excludes paused
     *      intervals, so auction price decay and expiry do not advance while every auction action (kick,
     *      take, redo) is pause-blocked. Falls back to wall time when no Governor is wired — the two clocks
     *      only ever diverge by settled pause spans, and tic values are recorded and measured on the SAME
     *      clock throughout. NOTE (migration): replacing the Governor changes the clock baseline; do so only
     *      with no active auctions, or their ages jump by the difference in accumulated pause time.
     * @return time The current active-time reading [seconds].
     */
    function _clock() private view returns (uint256 time) {
        return governor != address(0) ? IGovernor(governor).clock() : block.timestamp;
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
        // Elapsed time is measured on the active-time clock (audit M08): tic is recorded on the same clock
        // in kick/redo, so the age excludes paused intervals — the curve does not decay and tail does not
        // elapse while every auction action is forbidden.
        uint256 dur = _clock() - tic;

        price = calc.price(top, dur);
        done = (dur > tail || (price * _RAY) / top < cusp);
    }
}
