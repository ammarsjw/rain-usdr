// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

import { IGovernor } from "../interfaces/IGovernor.sol";
import { ISolvencyEngine } from "../interfaces/ISolvencyEngine.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { Math } from "../libraries/Math.sol";
import { _RAY, _WARD_ROLE } from "../shared/Constants.sol";
import { FeeRecipientNotSet, IlkAlreadyInitialized, InvalidAddress, InvalidDuty, NotLive, SolvencyGateActive, SystemPaused, UnrecognizedParameter } from "../shared/Errors.sol";
import { Cage, Drip } from "../shared/Events.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title VaultEngine
 * @author Rain Team
 * @notice The immutable core ledger. Master record of every piece of collateral and every unit of debt in the system.
 *         Enforces the fundamental rule that no vault can mint more USDR than its collateral allows. Its rules can
 *         never be changed after deployment.
 * @dev Each ilk's `rate` is initialized to `RAY` (1.0) and grows as stability fees accrue: `duty` is a per-second
 *      compounding factor [ray] and the permissionless {drip} lazily folds `rpow(duty, now - rho) * rate` into the
 *      ilk, crediting the accrued fees to the {feeRecipient} (the Balance Sheet) as surplus. `frob` (when changing
 *      debt) and duty changes drip automatically; after `cage` the rate is frozen. Internal USDR balances are
 *      tracked in `rad` (45 decimals).
 */
contract VaultEngine is IVaultEngine, AccessControl {
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
            if (data < _RAY) {
                _revert(InvalidDuty.selector);
            }

            // Accrue at the OLD duty first: a duty change must never apply retroactively over the elapsed window.
            drip(ilkId);

            ilks[ilkId].duty = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ ilkId: ilkId, what: what, data: data });
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

        // The collateral type must have been initialized: junk vaults against unknown ilks are rejected here rather
        // than later in frob, so indexers only ever see real positions.
        if (ilks[ilkId].rate == 0) {
            _revert(IlkNotInitialized.selector);
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

        // After shutdown the rate is frozen: emergency settlement must see the rates as of cage time. A no-op return
        // (rather than a revert) keeps post-cage callers working.
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

        // Fees are minted to the fee recipient (the Balance Sheet) as surplus at accrual time. Accruing a nonzero
        // fee without a configured recipient would burn it into an unreachable balance, so it is a hard error.
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
    }

    /**
     * @inheritdoc IVaultEngine
     */
    function cage() external onlyRole(_WARD_ROLE) {
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

        // Accrue the stability fee before any debt change so tab and dtab are computed at the current rate: the
        // stale-rate window is impossible by construction. drip itself reverts on an uninitialized ilk.
        if (dart != 0) {
            drip(ilkId);
        }

        Urn memory urn = urns[vaultId];
        Ilk memory ilk = ilks[ilkId];

        // The collateral type must have been initialized.
        if (ilk.rate == 0) {
            _revert(IlkNotInitialized.selector);
        }

        // Emergency pause check (full stop): when the Governor is wired and paused, all vault modifications are
        // blocked. Unlike the solvency gate below, this stops risk-decreasing operations too.
        if (governor != address(0) && IGovernor(governor).paused()) {
            _revert(SystemPaused.selector);
        }

        // Solvency gate: when the Solvency Engine is wired and reports a breach of the reserve invariant,
        // risk-increasing changes (drawing debt or withdrawing collateral) against VOLATILE collateral are blocked.
        // Repayment (dart < 0) and collateral top-ups (dink > 0) always remain available because they reduce risk.
        // Stable (PSM) ilks are exempt here: PSM inflows are reserve-increasing and must never be gated, while PSM
        // redemptions are gated inside the PSM itself.
        if (
            (dart > 0 || dink < 0) &&
            solvencyEngine != address(0) &&
            ISolvencyEngine(solvencyEngine).isBreached() &&
            ISolvencyEngine(solvencyEngine).isVolatile(ilkId)
        ) {
            _revert(SolvencyGateActive.selector);
        }

        urn.ink = Math.add(urn.ink, dink);
        urn.art = Math.add(urn.art, dart);
        ilk.globalArt = Math.add(ilk.globalArt, dart);
        ilk.globalInk = Math.add(ilk.globalInk, dink);

        // NOTE: with a variable `rate` (stability fees), `dtab`/`tab` are exact rad values but no longer exact
        // multiples of RAY. This mirrors Maker's vat semantics: `tab = rate * art` [rad] is compared against `dust`
        // [rad] directly, which stays correct at any rate >= RAY and cannot be gamed by rounding.
        int256 dtab = Math.mul(ilk.rate, dart);
        uint256 tab = Math.umul(ilk.rate, urn.art);

        debt = Math.add(debt, dtab);

        // Ceiling check: either debt is being repaid (dart decreased), or both the ilk ceiling and the global ceiling
        // must hold after the change.
        if (!(dart <= 0 || Math.both(Math.umul(ilk.globalArt, ilk.rate) <= ilk.line, debt <= globalLine))) {
            _revert(CeilingExceeded.selector);
        }

        // Safety check: the urn is either less risky than before, or it is safe after the change. Uses the delayed
        // oracle price factor already stored in the system.
        if (!(Math.both(dart <= 0, dink >= 0) || tab <= Math.umul(urn.ink, ilk.spot))) {
            _revert(NotSafe.selector);
        }

        // Permission checks: the vault is either less risky than before, or its owner consents; collateral is either
        // not being taken, or its source consents; internal USDR is either not being drawn down, or the destination
        // consents.
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
        // NOTE: deliberately callable after shutdown (no live check). The emergency settlement module (End) seizes
        // positions through this function after cage.
        if (ownerOf[vaultId] == address(0)) {
            _revert(VaultNotFound.selector);
        }

        bytes32 ilkId = ilkOf[vaultId];

        Urn storage urn = urns[vaultId];
        Ilk storage ilk = ilks[ilkId];

        urn.ink = Math.add(urn.ink, dink);
        urn.art = Math.add(urn.art, dart);
        ilk.globalArt = Math.add(ilk.globalArt, dart);
        ilk.globalInk = Math.add(ilk.globalInk, dink);

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
        // NOTE: deliberately callable after shutdown (no live check). Emergency settlement heals the Balance Sheet's
        // surplus against bad debt after cage (End.thaw() requires it).
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
