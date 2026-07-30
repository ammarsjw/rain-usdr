// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { Math } from "../libraries/Math.sol";
import { _RAY, _WARD_ROLE } from "../shared/Constants.sol";
import { NotLive, UnrecognizedParameter } from "../shared/Errors.sol";
import { Cage } from "../shared/Events.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title VaultEngine
 * @author Rain Team
 * @notice The immutable core ledger. Master record of every piece of collateral and every unit of debt in the
 *         system. Enforces the fundamental rule that no vault can mint more USDR than its collateral allows. Its
 *         rules can never be changed after deployment.
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
        require(ilks[ilkId].rate == 0, "VaultEngine/ilk-already-init");

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
        require(_wish(from, msg.sender), "VaultEngine/not-allowed");

        collateral[ilkId][from] -= wad;
        collateral[ilkId][to] += wad;

        emit Flux({ ilkId: ilkId, from: from, to: to, wad: wad });
    }

    /**
     * @inheritdoc IVaultEngine
     */
    function move(address from, address to, uint256 rad) external {
        require(_wish(from, msg.sender), "VaultEngine/not-allowed");

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
        require(ilk.rate != 0, "VaultEngine/ilk-not-init");

        urn.ink = Math.add(urn.ink, dink);
        urn.art = Math.add(urn.art, dart);
        ilk.globalArt = Math.add(ilk.globalArt, dart);

        int256 dtab = Math.mul(ilk.rate, dart);
        uint256 tab = ilk.rate * urn.art;
        debt = Math.add(debt, dtab);

        // Ceiling check: either debt is being repaid, or both the ilk ceiling and the global ceiling must hold
        // after the change.
        require(
            dart <= 0 || (ilk.globalArt * ilk.rate <= ilk.line && debt <= globalLine),
            "VaultEngine/ceiling-exceeded"
        );
        // Safety check: the vault must be either safer than before, or safe after the change. Uses the delayed
        // oracle price factor already stored in the system.
        require(Math.both(dart <= 0, dink >= 0) || tab <= urn.ink * ilk.spot, "VaultEngine/not-safe");

        // Permission checks: positions may only be worsened with the owner's consent, collateral may only be taken
        // with its source's consent, and internal USDR may only be drawn from a consenting destination.
        require(Math.both(dart <= 0, dink >= 0) || _wish(u, msg.sender), "VaultEngine/not-allowed-u");
        require(dink <= 0 || _wish(v, msg.sender), "VaultEngine/not-allowed-v");
        require(dart >= 0 || _wish(w, msg.sender), "VaultEngine/not-allowed-w");

        // Minimum size check: a vault must either carry zero debt or at least the minimum size.
        require(urn.art == 0 || tab >= ilk.dust, "VaultEngine/dust");

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
        Urn storage urn = urns[ilkId][u];
        Ilk storage ilk = ilks[ilkId];

        urn.ink = Math.add(urn.ink, dink);
        urn.art = Math.add(urn.art, dart);
        ilk.globalArt = Math.add(ilk.globalArt, dart);

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

    /* ========================== INTERNAL FUNCTIONS ========================== */

    /**
     * @dev Returns whether `operator` may manage the positions of `owner`.
     * @param owner Owner of the positions.
     * @param operator Account being queried.
     * @return Whether the operator has management permission.
     */
    function _wish(address owner, address operator) internal view returns (bool) {
        return owner == operator || can[owner][operator] == 1;
    }
}
