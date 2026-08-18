// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

import { IGovernor } from "../interfaces/IGovernor.sol";
import { ISolvencyEngine } from "../interfaces/ISolvencyEngine.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { Math } from "../libraries/Math.sol";
import { _RAY, _WARD_ROLE } from "../shared/Constants.sol";
import {
    IlkAlreadyInitialized,
    NotLive,
    SolvencyGateActive,
    SystemPaused,
    UnrecognizedParameter
} from "../shared/Errors.sol";
import { Cage } from "../shared/Events.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title VaultEngine
 * @author Rain Team
 * @notice The immutable core ledger. Master record of every piece of collateral and every unit of debt in the system.
 *         Enforces the fundamental rule that no vault can mint more USDR than its collateral allows. Its rules can
 *         never be changed after deployment.
 * @dev USDR charges no stability fee, so each ilk's `rate` is initialized to `RAY` (1.0) and never changes. Internal
 *      USDR balances are tracked in `rad` (45 decimals).
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
    mapping(address owner => mapping(address operator => uint256 permission)) public can;

    /// @inheritdoc IVaultEngine
    mapping(bytes32 ilkId => Ilk collateralType) public ilks;

    /// @inheritdoc IVaultEngine
    mapping(bytes32 ilkId => mapping(address vaultOwner => Urn vault)) public urns;

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
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ ilkId: ilkId, what: what, data: data });
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
    function frob(bytes32 ilkId, address u, address v, address w, int256 dink, int256 dart) external {
        // System must be live.
        if (live != 1) {
            _revert(NotLive.selector);
        }

        Urn memory urn = urns[ilkId][u];
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

        // NOTE: `rate` is fixed at RAY forever (USDR charges no stability fee), so `dtab`/`tab` are exact rad values
        // and the dust/tab comparisons below remain correct only under that assumption. If a stability fee is ever
        // introduced, this arithmetic must be revisited.
        int256 dtab = Math.mul(ilk.rate, dart);
        uint256 tab = ilk.rate * urn.art;

        debt = Math.add(debt, dtab);

        // Ceiling check: either debt is being repaid (dart decreased), or both the ilk ceiling and the global ceiling
        // must hold after the change.
        if (!(dart <= 0 || Math.both(ilk.globalArt * ilk.rate <= ilk.line, debt <= globalLine))) {
            _revert(CeilingExceeded.selector);
        }

        // Safety check: the urn is either less risky than before, or it is safe after the change. Uses the delayed
        // oracle price factor already stored in the system.
        if (!(Math.both(dart <= 0, dink >= 0) || tab <= urn.ink * ilk.spot)) {
            _revert(NotSafe.selector);
        }

        // Permission checks: the urn is either less risky than before, or its owner consents; collateral is either not
        // being taken, or its source consents; internal USDR is either not being drawn down, or the destination
        // consents.
        if (!(Math.both(dart <= 0, dink >= 0) || _wish(u, msg.sender))) {
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

        urns[ilkId][u] = urn;
        ilks[ilkId] = ilk;

        emit Frob({ ilkId: ilkId, u: u, v: v, w: w, dink: dink, dart: dart });
    }

    /**
     * @inheritdoc IVaultEngine
     */
    function grab(
        bytes32 ilkId,
        address u,
        address v,
        address w,
        int256 dink,
        int256 dart
    ) external onlyRole(_WARD_ROLE) {
        // TODO: H-7 stopgap. There is no End.sol port yet, so `grab` is simply unavailable after shutdown. Once an
        // End equivalent exists, this must be revisited so its settlement path can seize positions.
        if (live != 1) {
            _revert(NotLive.selector);
        }

        Urn storage urn = urns[ilkId][u];
        Ilk storage ilk = ilks[ilkId];

        urn.ink = Math.add(urn.ink, dink);
        urn.art = Math.add(urn.art, dart);
        ilk.globalArt = Math.add(ilk.globalArt, dart);
        ilk.globalInk = Math.add(ilk.globalInk, dink);

        int256 dtab = Math.mul(ilk.rate, dart);

        collateral[ilkId][v] = Math.sub(collateral[ilkId][v], dink);
        sin[w] = Math.sub(sin[w], dtab);
        vice = Math.sub(vice, dtab);

        emit Grab({ ilkId: ilkId, u: u, v: v, w: w, dink: dink, dart: dart });
    }

    /**
     * @inheritdoc IVaultEngine
     */
    function heal(uint256 rad) external {
        // TODO: H-7 stopgap. There is no End.sol port yet, so `heal` is unavailable after shutdown.
        if (live != 1) {
            _revert(NotLive.selector);
        }

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
