// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

import { IGovernor } from "../interfaces/IGovernor.sol";
import { ISolvencyEngine } from "../interfaces/ISolvencyEngine.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { Math } from "../libraries/Math.sol";
import { _RAY, _WARD_ROLE } from "../shared/Constants.sol";
import {
    FeeRecipientNotSet,
    IlkAlreadyInitialized,
    InvalidAddress,
    InvalidAssignment,
    InvalidDuty,
    NotLive,
    SolvencyGateActive,
    SystemPaused,
    UnrecognizedParameter
} from "../shared/Errors.sol";
import { Cage, Drip } from "../shared/Events.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title VaultEngine
 * @author Rain Team
 * @notice The immutable core ledger. Master record of every piece of collateral and every unit of debt in the
 *         system. Enforces the fundamental rule that no vault can mint more USDR than its collateral allows.
 *         Its rules can never be changed after deployment.
 * @dev Each ilk's `rate` is initialized to `RAY` (1.0) and grows as stability fees accrue: `duty` is a
 *      per-second compounding factor [ray] and the permissionless {drip} lazily folds
 *      `rpow(duty, now - rho) * rate` into the ilk, crediting the accrued fees to the {feeRecipient} (the
 *      Balance Sheet) as surplus. `frob` (when changing debt) and duty changes drip automatically; after
 *      `cage` the rate is frozen. Internal USDR balances are tracked in `rad` (45 decimals).
 */
contract VaultEngine is IVaultEngine, AccessControl {
    /* ========================== CONSTANTS ========================== */

    /// @dev Upper bound on a per-second stability-fee factor `duty` [ray]: `2^(1/31536000)` scaled to ray,
    ///      i.e. exactly 100% APY. Bounding `duty` at file time is what stops a single fat-fingered value
    ///      from making `rpow` overflow minutes later, after which `drip` reverts forever and every vault in
    ///      the ilk becomes unrepayable. Any value this bound accepts stays computable for centuries.
    uint256 private constant _MAX_DUTY = 1000000021979553151239153027;

    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc IVaultEngine
    uint256 public debt;

    /// @inheritdoc IVaultEngine
    uint256 public vice;

    /// @inheritdoc IVaultEngine
    uint256 public globalLine;

    /// @inheritdoc IVaultEngine
    uint256 public live;

    /// @inheritdoc IVaultEngine
    address public solvencyEngine;

    /// @inheritdoc IVaultEngine
    address public governor;

    /// @inheritdoc IVaultEngine
    address public feeRecipient;

    /// @inheritdoc IVaultEngine
    mapping(address owner => mapping(address operator => uint256 permission)) public can;

    /// @inheritdoc IVaultEngine
    mapping(bytes32 ilkId => Ilk collateralType) public ilks;

    /// @inheritdoc IVaultEngine
    bytes32[] public ilkIds;

    /// @inheritdoc IVaultEngine
    mapping(bytes32 ilkId => bool feeExempt) public noFee;

    /// @inheritdoc IVaultEngine
    mapping(bytes32 ilkId => address owner) public exclusiveTo;

    /// @inheritdoc IVaultEngine
    mapping(bytes32 ilkId => uint256 ink) public backedInk;

    /// @inheritdoc IVaultEngine
    uint256 public vaultCount;

    /// @inheritdoc IVaultEngine
    mapping(uint256 vaultId => address vaultOwner) public ownerOf;

    /// @inheritdoc IVaultEngine
    mapping(uint256 vaultId => bytes32 ilkId) public ilkOf;

    /// @inheritdoc IVaultEngine
    mapping(uint256 vaultId => Urn vault) public urns;

    /// @inheritdoc IVaultEngine
    mapping(bytes32 ilkId => mapping(address user => uint256 balance)) public collateral;

    /// @inheritdoc IVaultEngine
    mapping(address user => uint256 balance) public usdr;

    /// @inheritdoc IVaultEngine
    mapping(address debtSink => uint256 balance) public sin;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Authorizes the deployer and marks the ledger live.
     */
    constructor() {
        _setRoleAdmin(_WARD_ROLE, _WARD_ROLE);

        _grantRole(_WARD_ROLE, msg.sender);

        live = 1;
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IVaultEngine
     */
    function hope(address operator) external {
        can[msg.sender][operator] = 1;

        emit Hope({ owner: msg.sender, operator: operator });
    }

    /**
     * @inheritdoc IVaultEngine
     */
    function nope(address operator) external {
        can[msg.sender][operator] = 0;

        emit Nope({ owner: msg.sender, operator: operator });
    }

    /**
     * @inheritdoc IVaultEngine
     */
    function init(bytes32 ilkId) external onlyRole(_WARD_ROLE) {
        if (ilks[ilkId].rate != 0) {
            _revert(IlkAlreadyInitialized.selector);
        }

        ilks[ilkId].rate = _RAY;
        ilks[ilkId].duty = _RAY;
        ilks[ilkId].rho = block.timestamp;

        // Registered so `cage` can enumerate every ilk (dripping each one at shutdown). Ilks are never
        // removed.
        ilkIds.push(ilkId);

        emit Init({ ilkId: ilkId });
    }

    /**
     * @inheritdoc IVaultEngine
     */
    function file(bytes32 what, uint256 data) external onlyRole(_WARD_ROLE) {
        if (live != 1) {
            _revert(NotLive.selector);
        }

        if (what == "globalLine") {
            globalLine = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, data: data });
    }

    /**
     * @inheritdoc IVaultEngine
     */
    function file(bytes32 what, address data) external onlyRole(_WARD_ROLE) {
        if (live != 1) {
            _revert(NotLive.selector);
        }

        if (what == "solvencyEngine") {
            solvencyEngine = data;
        } else if (what == "governor") {
            governor = data;
        } else if (what == "feeRecipient") {
            if (data == address(0)) {
                _revert(InvalidAddress.selector);
            }

            feeRecipient = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, addr: data });
    }

    /**
     * @inheritdoc IVaultEngine
     */
    function file(bytes32 ilkId, bytes32 what, uint256 data) external onlyRole(_WARD_ROLE) {
        if (live != 1) {
            _revert(NotLive.selector);
        }

        if (what == "spot") {
            ilks[ilkId].spot = data;
        } else if (what == "line") {
            ilks[ilkId].line = data;
        } else if (what == "dust") {
            ilks[ilkId].dust = data;
        } else if (what == "duty") {
            // The collateral type must have been initialized. Checked explicitly: the drip below used to
            // provide this guard, but it is now non-fatal and would swallow the revert.
            if (ilks[ilkId].rate == 0) {
                _revert(IlkNotInitialized.selector);
            }

            if (data < _RAY) {
                _revert(InvalidDuty.selector);
            }

            // Upper bound: an unbounded duty (e.g. a fat-fingered 1.5e27 = 50%/second) makes `rpow` overflow
            // within minutes, after which drip reverts forever and every vault in the ilk becomes
            // unrepayable. Bounding at file time keeps every accepted duty safely computable for centuries.
            if (data > _MAX_DUTY) {
                _revert(InvalidDuty.selector);
            }

            // Fee-exempt guard: stable (PSM) ilks must never accrue a stability fee. The PSM moves debt 1:1
            // with its stable inventory and holds no internal USDR, so ANY rate above RAY strands the entire
            // reserve (redemptions underflow, deposits fail the safety check) and mints unbacked surplus.
            if (noFee[ilkId] && data != _RAY) {
                _revert(InvalidDuty.selector);
            }

            // Accrue at the OLD duty first: a duty change must never apply retroactively over the elapsed
            // window. The drip is non-fatal: if accrual itself reverts (e.g. rpow overflow from a legacy bad
            // duty), governance must still be able to file a sane duty as the escape hatch and a reverting
            // drip must never lock the one parameter that can fix it. The skipped window then accrues at the
            // NEW duty, which is the acceptable cost of keeping the ilk recoverable.
            try this.drip(ilkId) {} catch {}

            ilks[ilkId].duty = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ ilkId: ilkId, what: what, data: data });
    }

    /**
     * @inheritdoc IVaultEngine
     */
    function file(bytes32 ilkId, bytes32 what, address data) external onlyRole(_WARD_ROLE) {
        if (live != 1) {
            _revert(NotLive.selector);
        }

        if (what == "exclusiveTo") {
            // The collateral type must have been initialized.
            if (ilks[ilkId].rate == 0) {
                _revert(IlkNotInitialized.selector);
            }

            // Binding is only honest while no debt exists against the ilk: vaults opened before the binding
            // survive it (ownership is immutable), so a nonzero binding filed onto an ilk that already
            // carries debt would claim an exclusivity the ledger lacks.
            if (data != address(0) && ilks[ilkId].globalArt != 0) {
                _revert(InvalidAssignment.selector);
            }

            exclusiveTo[ilkId] = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ ilkId: ilkId, what: what, addr: data });
    }

    /**
     * @inheritdoc IVaultEngine
     */
    function ilkIdsLength() external view returns (uint256) {
        return ilkIds.length;
    }

    /**
     * @inheritdoc IVaultEngine
     */
    function exemptFee(bytes32 ilkId) external onlyRole(_WARD_ROLE) {
        // The collateral type must have been initialized.
        if (ilks[ilkId].rate == 0) {
            _revert(IlkNotInitialized.selector);
        }

        // Marking is one-way and requires the ilk to be fee-clean: a rate already above RAY means fees have
        // accrued and the PSM invariant (rate == RAY forever) is already broken for this ilk.
        if (ilks[ilkId].rate != _RAY || ilks[ilkId].duty != _RAY) {
            _revert(InvalidAssignment.selector);
        }

        noFee[ilkId] = true;

        emit ExemptFee({ ilkId: ilkId });
    }

    /**
     * @inheritdoc IVaultEngine
     */
    function open(bytes32 ilkId, address usr) external returns (uint256 vaultId) {
        // Vaults may only be opened while the system is live.
        if (live != 1) {
            _revert(NotLive.selector);
        }

        if (usr == address(0)) {
            _revert(InvalidAddress.selector);
        }

        // The collateral type must have been initialized: junk vaults against unknown ilks are rejected here
        // rather than later in frob, so indexers only ever see real positions.
        if (ilks[ilkId].rate == 0) {
            _revert(IlkNotInitialized.selector);
        }

        // Exclusive-ilk binding: an ilk bound to a single legitimate owner (a PSM stable ilk is bound to its
        // PSM) rejects every other vault owner. Without this, anyone could open a personal vault on a 1:1 ilk
        // and frob debt 1:1 that never passes through the PSM's recordIncrease, then redeem the minted USDR
        // against the module's genuine inventory and strand honest sellers.
        if (exclusiveTo[ilkId] != address(0) && (exclusiveTo[ilkId] != usr || exclusiveTo[ilkId] != msg.sender)) {
            _revert(IlkExclusive.selector);
        }

        // Vault ids are sequential and never reused. Ownership is immutable: transferring a position is not
        // supported.
        vaultId = ++vaultCount;

        ownerOf[vaultId] = usr;
        ilkOf[vaultId] = ilkId;

        emit Open({ ilkId: ilkId, owner: usr, vaultId: vaultId });
    }

    /**
     * @inheritdoc IVaultEngine
     */
    function drip(bytes32 ilkId) public returns (uint256 newRate) {
        Ilk storage ilk = ilks[ilkId];

        uint256 prev = ilk.rate;

        // The collateral type must have been initialized.
        if (prev == 0) {
            _revert(IlkNotInitialized.selector);
        }

        // After shutdown the rate is frozen: emergency settlement must see the rates as of cage time. A no-op
        // return (rather than a revert) keeps post-cage callers working.
        if (live != 1) {
            return prev;
        }

        // Idempotent within a block.
        if (block.timestamp == ilk.rho) {
            return prev;
        }

        newRate = Math.rmul(Math.rpow(ilk.duty, block.timestamp - ilk.rho, _RAY), prev);

        uint256 delta = newRate - prev;
        uint256 rad = Math.umul(ilk.globalArt, delta);

        // Fees are minted to the fee recipient (the Balance Sheet) as surplus at accrual time. Accruing a
        // nonzero fee without a configured recipient would burn it into an unreachable balance, so it is a
        // hard error.
        if (rad != 0) {
            if (feeRecipient == address(0)) {
                _revert(FeeRecipientNotSet.selector);
            }

            usdr[feeRecipient] += rad;
            debt += rad;
        }

        ilk.rate = newRate;
        ilk.rho = block.timestamp;

        emit Drip({ ilkId: ilkId, rate: newRate, rad: rad });

        // Soft solvency refresh: fee accrual raises outstanding debt and therefore the worst-case loss with
        // no user action. Recompute the breach flag so a breach surfaces even between keeper checks. This
        // NEVER reverts: accrual is measurement, not a voluntary risk increase, and drip must stay callable
        // (it is invoked inside frob and on every duty change). The call is wrapped so a mis-wired engine can
        // never brick accrual, and it is skipped when no fee accrued (rad == 0) since the loss is then
        // unchanged.
        if (rad != 0 && solvencyEngine != address(0)) {
            try ISolvencyEngine(solvencyEngine).checkInvariant() returns (uint256, uint256) {} catch {}
        }
    }

    /**
     * @inheritdoc IVaultEngine
     */
    function cage() external onlyRole(_WARD_ROLE) {
        // Settle every ilk's accrued fees BEFORE freezing: rates are frozen at cage time, so any fee still
        // undripped here would be silently forgiven, which would make it so every vault would settle against
        // less debt than it owes and the shortfall would land on redeemers through a lower redemption price.
        // Dripping in the contract (rather than trusting a shutdown spell to remember) makes the settlement
        // accounting exact by construction. Each drip is non-fatal so one pathological ilk can never block
        // the emergency shutdown itself.
        uint256 length = ilkIds.length;

        for (uint256 i; i < length; ++i) {
            try this.drip(ilkIds[i]) {} catch {}
        }

        live = 0;

        emit Cage();
    }

    /**
     * @inheritdoc IVaultEngine
     */
    function slip(bytes32 ilkId, address user, int256 wad) external onlyRole(_WARD_ROLE) {
        collateral[ilkId][user] = Math.add(collateral[ilkId][user], wad);

        emit Slip({ ilkId: ilkId, user: user, wad: wad });
    }

    /**
     * @inheritdoc IVaultEngine
     */
    function flux(bytes32 ilkId, address from, address to, uint256 wad) external {
        if (!_wish(from, msg.sender)) {
            _revert(NotAllowed.selector);
        }

        collateral[ilkId][from] -= wad;
        collateral[ilkId][to] += wad;

        emit Flux({ ilkId: ilkId, from: from, to: to, wad: wad });
    }

    /**
     * @inheritdoc IVaultEngine
     */
    function move(address from, address to, uint256 rad) external {
        if (!_wish(from, msg.sender)) {
            _revert(NotAllowed.selector);
        }

        usdr[from] -= rad;
        usdr[to] += rad;

        emit Move({ from: from, to: to, rad: rad });
    }

    /**
     * @inheritdoc IVaultEngine
     */
    function frob(uint256 vaultId, address v, address w, int256 dink, int256 dart) external {
        // System must be live.
        if (live != 1) {
            _revert(NotLive.selector);
        }

        // The vault must have been opened. Its owner and collateral type are fixed at open time.
        address owner = ownerOf[vaultId];

        if (owner == address(0)) {
            _revert(VaultNotFound.selector);
        }

        bytes32 ilkId = ilkOf[vaultId];

        // Accrue the stability fee before ANY vault change so tab and dtab are computed at the current rate:
        // the stale-rate window is impossible by construction. Unconditional: a pure collateral withdrawal
        // (dink < 0, dart == 0) prices the safety check with `tab = art * rate`, and a stale rate there
        // understates the debt by the entire undripped accrual. drip itself reverts on an uninitialized ilk
        // and is idempotent within a block, so the extra call costs one warm read when already fresh.
        drip(ilkId);

        Urn memory urn = urns[vaultId];
        Ilk memory ilk = ilks[ilkId];

        // The collateral type must have been initialized.
        if (ilk.rate == 0) {
            _revert(IlkNotInitialized.selector);
        }

        // Emergency pause check (full stop): when the Governor is wired and paused, all vault modifications
        // are blocked. Unlike the solvency gate below, this stops risk-decreasing operations too.
        if (governor != address(0) && IGovernor(governor).paused()) {
            _revert(SystemPaused.selector);
        }

        // Solvency gate (HARD breach): risk-increasing changes (drawing debt or withdrawing collateral)
        // against VOLATILE collateral are blocked while the reserve invariant is breached. The invariant is
        // RECOMPUTED here rather than trusting the keeper-maintained flag: a stale flag (keeper down during a
        // price collapse) would otherwise let a draw slip through against reserves that can no longer cover
        // the stressed loss. Repayment (dart < 0) and collateral top-ups (dink > 0) always remain available
        // because they reduce risk. Stable (PSM) ilks are exempt: PSM inflows are reserve-increasing and must
        // never be gated, while PSM redemptions are gated inside the PSM itself.
        if (
            (dart > 0 || dink < 0) && solvencyEngine != address(0) && ISolvencyEngine(solvencyEngine).isVolatile(ilkId)
        ) {
            ISolvencyEngine(solvencyEngine).checkInvariant();

            if (ISolvencyEngine(solvencyEngine).isBreached()) {
                _revert(SolvencyGateActive.selector);
            }
        }

        // Backed-ink tracking: only collateral in vaults that actually carry debt may count toward the
        // solvency stress calculation. Collateral in a debt-free vault can never pay another vault's debt
        // (liquidation surplus returns to the vault's own owner), so it must contribute nothing to the
        // recoverable value. The aggregate is maintained here on the debt-zero boundary crossings: the
        // vault's PRE-write ink leaves the aggregate when it was debted, and its POST-write ink enters when
        // it is debted after — which handles all four combinations (stay debted, enter, exit, stay
        // debt-free) uniformly, including a repay-and-withdraw in the same call.
        bool hadDebt = urn.art != 0;
        uint256 prevInk = urn.ink;

        urn.ink = Math.add(urn.ink, dink);
        urn.art = Math.add(urn.art, dart);
        ilk.globalArt = Math.add(ilk.globalArt, dart);
        ilk.globalInk = Math.add(ilk.globalInk, dink);

        if (hadDebt) {
            backedInk[ilkId] -= prevInk;
        }

        if (urn.art != 0) {
            backedInk[ilkId] += urn.ink;
        }

        // NOTE: With a variable `rate` (stability fees), `dtab`/`tab` are exact rad values but no longer
        // exact multiples of RAY. `tab = rate * art` [rad] is compared against `dust` [rad] directly, which
        // stays correct at any rate >= RAY and cannot be gamed by rounding.
        int256 dtab = Math.mul(ilk.rate, dart);
        uint256 tab = Math.umul(ilk.rate, urn.art);

        debt = Math.add(debt, dtab);

        // Ceiling check: either debt is being repaid (dart decreased), or both the ilk ceiling and the global
        // ceiling must hold after the change.
        if (!(dart <= 0 || Math.both(Math.umul(ilk.globalArt, ilk.rate) <= ilk.line, debt <= globalLine))) {
            _revert(CeilingExceeded.selector);
        }

        // Safety check: the urn is either less risky than before, or it is safe after the change. Uses the
        // delayed oracle price factor already stored in the system.
        if (!(Math.both(dart <= 0, dink >= 0) || tab <= Math.umul(urn.ink, ilk.spot))) {
            _revert(NotSafe.selector);
        }

        // Permission checks: the vault is either less risky than before, or its owner consents; collateral is
        // either not being taken, or its source consents; internal USDR is either not being drawn down, or
        // the destination consents.
        if (!(Math.both(dart <= 0, dink >= 0) || _wish(owner, msg.sender))) {
            _revert(NotAllowed.selector);
        }

        if (!(dink <= 0 || _wish(v, msg.sender))) {
            _revert(NotAllowed.selector);
        }

        if (!(dart >= 0 || _wish(w, msg.sender))) {
            _revert(NotAllowed.selector);
        }

        // Minimum size check: the urn either has no debt, or a non-dusty amount.
        if (!(urn.art == 0 || tab >= ilk.dust)) {
            _revert(DustAmount.selector);
        }

        collateral[ilkId][v] = Math.sub(collateral[ilkId][v], dink);
        usdr[w] = Math.add(usdr[w], dtab);

        urns[vaultId] = urn;
        ilks[ilkId] = ilk;

        emit Frob({ ilkId: ilkId, vaultId: vaultId, v: v, w: w, dink: dink, dart: dart });
    }

    /**
     * @inheritdoc IVaultEngine
     */
    function grab(uint256 vaultId, address v, address w, int256 dink, int256 dart) external onlyRole(_WARD_ROLE) {
        // NOTE: Deliberately callable after shutdown (no live check). The emergency settlement module (End)
        // seizes positions through this function after cage.
        if (ownerOf[vaultId] == address(0)) {
            _revert(VaultNotFound.selector);
        }

        bytes32 ilkId = ilkOf[vaultId];

        Urn storage urn = urns[vaultId];
        Ilk storage ilk = ilks[ilkId];

        // Backed-ink tracking: grab crosses the same debt-zero boundary as frob (a bark seizes the vault's
        // entire debt and collateral; emergency settlement seizes partials), so the eligible aggregate is
        // maintained identically: pre-write ink leaves when the vault was debted, post-write ink enters when
        // it is debted after.
        bool hadDebt = urn.art != 0;
        uint256 prevInk = urn.ink;

        urn.ink = Math.add(urn.ink, dink);
        urn.art = Math.add(urn.art, dart);
        ilk.globalArt = Math.add(ilk.globalArt, dart);
        ilk.globalInk = Math.add(ilk.globalInk, dink);

        if (hadDebt) {
            backedInk[ilkId] -= prevInk;
        }

        if (urn.art != 0) {
            backedInk[ilkId] += urn.ink;
        }

        int256 dtab = Math.mul(ilk.rate, dart);

        collateral[ilkId][v] = Math.sub(collateral[ilkId][v], dink);
        sin[w] = Math.sub(sin[w], dtab);
        vice = Math.sub(vice, dtab);

        emit Grab({ ilkId: ilkId, vaultId: vaultId, v: v, w: w, dink: dink, dart: dart });
    }

    /**
     * @inheritdoc IVaultEngine
     */
    function heal(uint256 rad) external {
        // NOTE: Deliberately callable after shutdown (no live check). Emergency settlement heals the Balance
        // Sheet's surplus against bad debt after cage (End.thaw() requires it).
        sin[msg.sender] -= rad;
        usdr[msg.sender] -= rad;
        vice -= rad;
        debt -= rad;

        emit Heal({ account: msg.sender, rad: rad });
    }

    /**
     * @inheritdoc IVaultEngine
     */
    function suck(address u, address v, uint256 rad) external onlyRole(_WARD_ROLE) {
        sin[u] += rad;
        usdr[v] += rad;
        vice += rad;
        debt += rad;

        emit Suck({ u: u, v: v, rad: rad });
    }

    /**
     * @dev Returns whether `operator` may manage the positions of `owner`.
     * @param owner Owner of the positions.
     * @param operator Account being queried.
     * @return hasPermission Whether the operator has management permission.
     */
    function _wish(address owner, address operator) private view returns (bool) {
        return owner == operator || can[owner][operator] == 1;
    }
}
