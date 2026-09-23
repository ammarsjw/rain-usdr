// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

import { IBalanceSheet } from "../interfaces/IBalanceSheet.sol";
import { IReserveAccounting } from "../interfaces/IReserveAccounting.sol";
import { ISolvencyEngine } from "../interfaces/ISolvencyEngine.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { _RAY, _WAD, _WARD_ROLE } from "../shared/Constants.sol";
import { InvalidAddress, InvalidAmount, NotLive, SolvencyGateActive, UnrecognizedParameter } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title BalanceSheet
 * @author Rain Team
 * @notice The protocol's treasury and debt manager. Receives revenue as surplus, holds a safety buffer, and
 *         absorbs bad debt through an ordered waterfall. When the surplus buffer is full, the excess goes
 *         toward buying back and burning RAIN.
 * @dev Uses no surplus or debt auctions. USDR uses a RAIN buyback-and-burn for surplus and a controlled
 *      backstop for bad debt instead. The strict "fill before burn" rule is enforced in `distributeSurplus`.
 *      Bad debt entering via `fess` sits in a time-indexed queue for `wait` seconds before it can be healed
 *      so surplus cannot be netted against debt whose auction is still running.
 */
contract BalanceSheet is IBalanceSheet, AccessControl {
    /* ========================== CONSTANTS ========================== */

    /// @dev Minimum age of the lagged reserve snapshot used by {humpTarget}. A day is long enough that
    ///      shrinking the dynamic term requires genuinely parking capital outside the reserve, not a flash
    ///      round trip.
    uint256 private constant _RESERVE_LAG = 1 days;

    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc IBalanceSheet
    IVaultEngine public immutable VAULT_ENGINE;

    /// @inheritdoc IBalanceSheet
    uint256 public humpFloor;

    /// @inheritdoc IBalanceSheet
    uint256 public humpRate;

    /// @inheritdoc IBalanceSheet
    uint256 public wait;

    /// @inheritdoc IBalanceSheet
    uint256 public totalQueuedSin;

    /// @inheritdoc IBalanceSheet
    uint256 public laggedReserve;

    /// @inheritdoc IBalanceSheet
    uint256 public laggedReserveAt;

    /// @inheritdoc IBalanceSheet
    uint256 public prevLaggedReserve;

    /// @inheritdoc IBalanceSheet
    uint256 public laggedReserveBlock;

    /// @inheritdoc IBalanceSheet
    address public buybackReceiver;

    /// @inheritdoc IBalanceSheet
    address public solvencyEngine;

    /// @inheritdoc IBalanceSheet
    IReserveAccounting public reserveAccounting;

    /// @inheritdoc IBalanceSheet
    mapping(uint256 era => uint256 tab) public sin;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the balance sheet.
     * @param vaultEngine_ Address of the Vault Engine.
     */
    constructor(IVaultEngine vaultEngine_) {
        if (address(vaultEngine_) == address(0)) {
            _revert(InvalidAddress.selector);
        }

        _setRoleAdmin(_WARD_ROLE, _WARD_ROLE);

        _grantRole(_WARD_ROLE, msg.sender);

        VAULT_ENGINE = vaultEngine_;
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IBalanceSheet
     */
    function file(bytes32 what, uint256 data) external onlyRole(_WARD_ROLE) {
        if (what == "humpFloor") {
            humpFloor = data;
        } else if (what == "humpRate") {
            // The buffer rate lives in (0, WAD] (audit L10): humpTarget scales the reserve by humpRate/WAD,
            // so a value far above WAD (e.g. a ray mistyped for a wad) produces a target no surplus can ever
            // reach — distributeSurplus then silently returns zero forever, a no-op that monitoring built on
            // failed transactions never sees. Zero would make the dynamic term vanish, silently reducing the
            // buffer to the static floor alone.
            if (data == 0 || data > _WAD) {
                _revert(InvalidAmount.selector);
            }

            humpRate = data;
        } else if (what == "wait") {
            // The bad-debt queue delay is bounded to one year (audit L10): wait gates flog, so a
            // fat-fingered value (e.g. seconds mistyped as milliseconds) would strand every queued sin
            // until the value is refiled.
            if (data > 365 days) {
                _revert(InvalidAmount.selector);
            }

            wait = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, data: data });
    }

    /**
     * @inheritdoc IBalanceSheet
     */
    function file(bytes32 what, address data) external onlyRole(_WARD_ROLE) {
        if (what == "buybackReceiver") {
            buybackReceiver = data;
        } else if (what == "reserveAccounting") {
            reserveAccounting = IReserveAccounting(data);
        } else if (what == "solvencyEngine") {
            solvencyEngine = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, addr: data });
    }

    /**
     * @inheritdoc IBalanceSheet
     */
    function fess(uint256 tab) external onlyRole(_WARD_ROLE) {
        // Queueing the bad debt by its era so it cannot be healed (or shipped out as surplus) until `wait`
        // seconds have passed and `flog` releases it.
        sin[block.timestamp] += tab;
        totalQueuedSin += tab;

        emit Fess({ tab: tab });
    }

    /**
     * @inheritdoc IBalanceSheet
     */
    function flog(uint256 era) external {
        if (block.timestamp < era + wait) {
            _revert(WaitNotElapsed.selector);
        }

        uint256 tab = sin[era];

        totalQueuedSin -= tab;
        sin[era] = 0;

        emit Flog({ era: era, tab: tab });
    }

    /**
     * @inheritdoc IBalanceSheet
     */
    function heal(uint256 rad) external {
        if (rad > VAULT_ENGINE.usdr(address(this))) {
            _revert(InsufficientSurplus.selector);
        }

        // Only debt released from the queue may be healed. USDR has no debt auctions, so there is no
        // on-auction term to subtract, only the queued portion.
        if (rad > VAULT_ENGINE.sin(address(this)) - totalQueuedSin) {
            _revert(InsufficientDebt.selector);
        }

        VAULT_ENGINE.heal(rad);

        emit Heal({ rad: rad });
    }

    /**
     * @inheritdoc IBalanceSheet
     */
    function suck(address kpr, uint256 rad) external onlyRole(_WARD_ROLE) {
        // Creating the reward as a small piece of bad debt, to be covered later from surplus.
        VAULT_ENGINE.suck(address(this), kpr, rad);

        emit Suck({ kpr: kpr, rad: rad });
    }

    /**
     * @inheritdoc IBalanceSheet
     */
    function distributeSurplus() external returns (uint256 excess) {
        // Shutdown guard (audit M04): after emergency settlement begins, End.pack retires redeemed USDR by
        // moving it onto this contract — to the surplus accounting below it is indistinguishable from
        // revenue, so a post-cage distribution would ship retired USDR out to the buyback receiver instead
        // of leaving it retired. The Vault Engine's own live flag is read directly (rather than adding a
        // Balance Sheet flag a shutdown spell would have to remember to set), in the same spirit as the
        // Vault Engine dripping every ilk inside its cage.
        if (VAULT_ENGINE.live() != 1) {
            _revert(NotLive.selector);
        }

        uint256 surplus = VAULT_ENGINE.usdr(address(this));
        uint256 badDebt = VAULT_ENGINE.sin(address(this));

        // Unqueued bad debt must be healed before any distribution. This is a routine keeper race (a
        // liquidation window always carries some sin), not an error, so it no-ops instead of reverting which
        // is the same philosophy as the below-target case: keepers retry, automation stays quiet, nothing is
        // lost. When the queue exceeds the engine sin (a fess without matched engine debt), unqueued debt is
        // zero and the queue reservation below still holds back the full queued amount.
        if (badDebt > totalQueuedSin) {
            return 0;
        }

        uint256 target = humpTarget();

        // Queued sin cannot be healed yet, but it is real bad debt: the surplus that will heal it once the
        // queue releases must never be shipped out. It is reserved on top of the buffer target.
        target += totalQueuedSin;

        // Reserve-backing assertion: every fee-exempt (PSM stable) ilk's debt is the bookkeeping counterpart
        // of stablecoins in the reserve, so the reserve must cover that debt before ANY surplus leaves the
        // protocol. A shortfall means unbacked USDR was minted somewhere (e.g. a fee accrued on a stable
        // ilk): distributing in that state converts the hole into permanently burned RAIN. Unlike the cases
        // above this is a genuine alarm, not a keeper race, so it reverts loudly.
        if (address(reserveAccounting) != address(0)) {
            uint256 stableDebt;
            uint256 length = VAULT_ENGINE.ilkIdsLength();

            for (uint256 i; i < length; ++i) {
                bytes32 ilkId = VAULT_ENGINE.ilkIds(i);

                if (VAULT_ENGINE.noFee(ilkId)) {
                    (uint256 globalArt, , uint256 rate, , , , , ) = VAULT_ENGINE.ilks(ilkId);

                    stableDebt += globalArt * rate;
                }
            }

            if (reserveAccounting.totalReserve() * _RAY < stableDebt) {
                _revert(ReserveBackingShortfall.selector);
            }
        }

        // The strict "fill before burn" rule: the surplus buffer must be above its target first. When the
        // buffer is below target, no distribution happens and all revenue stays, and because this is a
        // routine keeper no-op, not an error, it returns 0 instead of reverting.
        if (surplus <= target) {
            return 0;
        }

        // Solvency gate (HARD breach): a distribution ships value out of the protocol, so it is blocked while
        // the reserve invariant is breached. The invariant is RECOMPUTED here rather than trusting the
        // keeper-maintained flag, the same lazy gate as PSM redemption: surplus must never leave toward
        // buyback while the stressed loss exceeds what the reserve can cover.
        if (solvencyEngine != address(0)) {
            ISolvencyEngine(solvencyEngine).checkInvariant();

            if (ISolvencyEngine(solvencyEngine).isBreached()) {
                _revert(SolvencyGateActive.selector);
            }
        }

        if (buybackReceiver == address(0)) {
            _revert(NoBuybackReceiver.selector);
        }

        // Only the amount above the buffer target is released to the RAIN buyback process.
        excess = surplus - target;

        VAULT_ENGINE.move(address(this), buybackReceiver, excess);

        // Refreshing the lagged reserve snapshot AFTER the distribution: the snapshot a distribution is
        // measured against is always at least {_RESERVE_LAG} old, so a redeem-shrink-distribute round trip
        // inside one transaction (or one snapshot window) cannot lower the target it faces.
        _snapshotReserve();

        emit DistributeSurplus({ excess: excess });
    }

    /**
     * @inheritdoc IBalanceSheet
     */
    function snapshotReserve() external {
        _snapshotReserve();
    }

    /**
     * @dev Records the current total reserve as the lagged snapshot, at most once per {_RESERVE_LAG}.
     *      Permissionless via {snapshotReserve} (keepers keep it fresh) and called after every distribution.
     *      Because the snapshot can only move once per lag window, a distribution never faces a target shrunk
     *      by same-window PSM outflow.
     */
    function _snapshotReserve() private {
        if (block.timestamp >= laggedReserveAt + _RESERVE_LAG && address(reserveAccounting) != address(0)) {
            // The outgoing anchor is retained (audit M05): a snapshot taken in the CURRENT block must not
            // benefit the transaction that took it, so humpTarget falls back to this previous anchor until
            // the next block. Without it, an attacker could shrink the reserve via buyStable, re-anchor with
            // the permissionless snapshotReserve, and distribute against the shrunken target — all in one
            // transaction, defeating the lag entirely.
            prevLaggedReserve = laggedReserve;
            laggedReserveBlock = block.number;

            laggedReserve = reserveAccounting.totalReserve();
            laggedReserveAt = block.timestamp;

            emit SnapshotReserve({ reserve: laggedReserve });
        }
    }

    /**
     * @inheritdoc IBalanceSheet
     */
    function humpTarget() public view returns (uint256 target) {
        // Dynamic buffer target: the greater of the static floor and `humpRate` of the total stable reserve.
        // The reserve is tracked in wad, the buffer in rad, so the rate product is scaled up by RAY. The
        // dynamic term reads the LARGER of the live reserve and a snapshot at least {_RESERVE_LAG} old :
        // `totalReserve` moves with permissionless PSM flows, so without the lag a user could redeem first,
        // shrink the target, and drain more surplus in the same transaction. Growing the target (selling
        // stables in) takes effect immediately and only shrinking it is lagged. The floor remains the
        // authoritative lower bound.
        target = humpFloor;

        if (address(reserveAccounting) != address(0)) {
            uint256 reserve = reserveAccounting.totalReserve();

            // A snapshot taken in the CURRENT block must not benefit the transaction that took it (audit
            // M05): the anchor exists so the figure a distribution is measured against predates the
            // transaction performing it. When the anchor was re-taken this block, the MAX of the previous
            // and current anchors is judged — a two-deep ring: a same-block re-anchor can only RAISE the
            // judged figure (a growing reserve counts immediately, as documented), never lower it, so a
            // shrink-reanchor-distribute round trip still faces the old, higher figure. From the next block
            // onward the fresh anchor applies normally.
            uint256 anchor = laggedReserve;

            if (block.number == laggedReserveBlock && prevLaggedReserve > anchor) {
                anchor = prevLaggedReserve;
            }

            if (anchor > reserve) {
                reserve = anchor;
            }

            uint256 dynamic = ((reserve * humpRate) / _WAD) * _RAY;

            if (dynamic > target) {
                target = dynamic;
            }
        }
    }
}
