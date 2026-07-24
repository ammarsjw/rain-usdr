// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { Auth } from "../shared/Auth.sol";
import { WARD_ROLE } from "../shared/Constants.sol";
import { NotLive, UnrecognizedParameter } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title VaultEngine.
 * @author Rain Team.
 * @notice The immutable core ledger. Master record of every piece of collateral and every unit of
 *         debt in the system. Enforces the fundamental rule that no vault can mint more USDR than
 *         its collateral allows. Its rules can never be changed after deployment.
 * @dev Based on MakerDAO's Vat. USDR charges no stability fee, so each ilk's `rate` is initialized
 *      to `RAY` (1.0) and never changes. Internal USDR balances are tracked in `rad` (45 decimals).
 */
contract VaultEngine is IVaultEngine, Auth {
    /* ========================== STATE VARIABLES ========================== */

    /// @notice Vault management permissions. `can[owner][operator] == 1` lets `operator` manage `owner`'s positions.
    mapping(address owner => mapping(address operator => uint256 permission)) public can;

    /// @notice Registered collateral types, keyed by identifier (e.g. "RAIN-A", "USDT-A", "USDC-A").
    mapping(bytes32 ilkId => Ilk collateralType) public ilks;

    /// @notice Vaults, keyed by collateral type and owner.
    mapping(bytes32 ilkId => mapping(address vaultOwner => Urn vault)) public urns;

    /// @notice Free (unlocked) collateral balances inside the system [wad].
    mapping(bytes32 ilkId => mapping(address user => uint256 balance)) public collateral;

    /// @notice Internal USDR balances [rad].
    mapping(address user => uint256 balance) public usdr;

    /// @notice Bad debt (unbacked USDR) per debt sink [rad].
    mapping(address debtSink => uint256 balance) public sin;

    /// @notice Total USDR issued [rad].
    uint256 public debt;

    /// @notice Total bad debt [rad].
    uint256 public vice;

    /// @notice Global debt ceiling [rad].
    uint256 public Line;

    /// @notice System liveness flag. `1` while live, `0` after shutdown.
    uint256 public live;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Authorizes the deployer and marks the ledger live.
     */
    constructor() {
        live = 1;

        _initAuth();
    }

    /* ========================== AUTHORIZATION ========================== */

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

    /// @dev Returns whether `operator` may manage the positions of `owner`.
    function wish(address owner, address operator) internal view returns (bool) {
        return owner == operator || can[owner][operator] == 1;
    }

    /* ========================== ADMINISTRATION ========================== */

    /**
     * @inheritdoc IVaultEngine
     */
    function init(bytes32 ilkId) external onlyRole(WARD_ROLE) {
        require(ilks[ilkId].rate == 0, "VaultEngine/ilk-already-init");

        ilks[ilkId].rate = 10 ** 27;

        emit Init({ ilkId: ilkId });
    }

    /**
     * @inheritdoc IVaultEngine
     */
    function file(bytes32 what, uint256 data) external onlyRole(WARD_ROLE) {
        if (live != 1) {
            _revert(NotLive.selector);
        }

        if (what == "Line") {
            Line = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, data: data });
    }

    /**
     * @inheritdoc IVaultEngine
     */
    function file(bytes32 ilkId, bytes32 what, uint256 data) external onlyRole(WARD_ROLE) {
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
    function cage() external onlyRole(WARD_ROLE) {
        live = 0;

        emit Cage();
    }

    /* ========================== FUNGIBILITY ========================== */

    /**
     * @inheritdoc IVaultEngine
     */
    function slip(bytes32 ilkId, address user, int256 wad) external onlyRole(WARD_ROLE) {
        collateral[ilkId][user] = _add(collateral[ilkId][user], wad);

        emit Slip({ ilkId: ilkId, user: user, wad: wad });
    }

    /**
     * @inheritdoc IVaultEngine
     */
    function flux(bytes32 ilkId, address from, address to, uint256 wad) external {
        require(wish(from, msg.sender), "VaultEngine/not-allowed");

        collateral[ilkId][from] -= wad;
        collateral[ilkId][to] += wad;

        emit Flux({ ilkId: ilkId, from: from, to: to, wad: wad });
    }

    /**
     * @inheritdoc IVaultEngine
     */
    function move(address from, address to, uint256 rad) external {
        require(wish(from, msg.sender), "VaultEngine/not-allowed");

        usdr[from] -= rad;
        usdr[to] += rad;

        emit Move({ from: from, to: to, rad: rad });
    }

    /* ========================== VAULT MANAGEMENT ========================== */

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

        urn.ink = _add(urn.ink, dink);
        urn.art = _add(urn.art, dart);
        ilk.Art = _add(ilk.Art, dart);

        int256 dtab = _mul(ilk.rate, dart);
        uint256 tab = ilk.rate * urn.art;
        debt = _add(debt, dtab);

        // Ceiling check: either debt is being repaid, or both the ilk ceiling and the global
        // ceiling must hold after the change.
        require(dart <= 0 || (ilk.Art * ilk.rate <= ilk.line && debt <= Line), "VaultEngine/ceiling-exceeded");
        // Safety check: the vault must be either safer than before, or safe after the change.
        // Uses the delayed oracle price factor already stored in the system.
        require(both(dart <= 0, dink >= 0) || tab <= urn.ink * ilk.spot, "VaultEngine/not-safe");

        // Permission checks: positions may only be worsened with the owner's consent, collateral
        // may only be taken with its source's consent, and internal USDR may only be drawn from
        // a consenting destination.
        require(both(dart <= 0, dink >= 0) || wish(u, msg.sender), "VaultEngine/not-allowed-u");
        require(dink <= 0 || wish(v, msg.sender), "VaultEngine/not-allowed-v");
        require(dart >= 0 || wish(w, msg.sender), "VaultEngine/not-allowed-w");

        // Minimum size check: a vault must either carry zero debt or at least the minimum size.
        require(urn.art == 0 || tab >= ilk.dust, "VaultEngine/dust");

        collateral[ilkId][v] = _sub(collateral[ilkId][v], dink);
        usdr[w] = _add(usdr[w], dtab);

        urns[ilkId][u] = urn;
        ilks[ilkId] = ilk;

        emit Frob({ ilkId: ilkId, u: u, v: v, w: w, dink: dink, dart: dart });
    }

    /* ========================== LIQUIDATION ========================== */

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
    ) external onlyRole(WARD_ROLE) {
        Urn storage urn = urns[ilkId][u];
        Ilk storage ilk = ilks[ilkId];

        urn.ink = _add(urn.ink, dink);
        urn.art = _add(urn.art, dart);
        ilk.Art = _add(ilk.Art, dart);

        int256 dtab = _mul(ilk.rate, dart);

        collateral[ilkId][v] = _sub(collateral[ilkId][v], dink);
        sin[w] = _sub(sin[w], dtab);
        vice = _sub(vice, dtab);

        emit Grab({ ilkId: ilkId, u: u, v: v, w: w, dink: dink, dart: dart });
    }

    /* ========================== SETTLEMENT ========================== */

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
    function suck(address u, address v, uint256 rad) external onlyRole(WARD_ROLE) {
        sin[u] += rad;
        usdr[v] += rad;
        vice += rad;
        debt += rad;

        emit Suck({ u: u, v: v, rad: rad });
    }

    /* ========================== MATH HELPERS ========================== */

    /// @dev Adds a signed integer to an unsigned integer, reverting on over/underflow.
    function _add(uint256 x, int256 y) internal pure returns (uint256 z) {
        unchecked {
            z = x + uint256(y);
        }
        require(y >= 0 || z <= x, "VaultEngine/add-underflow");
        require(y <= 0 || z >= x, "VaultEngine/add-overflow");
    }

    /// @dev Subtracts a signed integer from an unsigned integer, reverting on over/underflow.
    function _sub(uint256 x, int256 y) internal pure returns (uint256 z) {
        unchecked {
            z = x - uint256(y);
        }
        require(y <= 0 || z <= x, "VaultEngine/sub-underflow");
        require(y >= 0 || z >= x, "VaultEngine/sub-overflow");
    }

    /// @dev Multiplies an unsigned integer by a signed integer, reverting on overflow.
    function _mul(uint256 x, int256 y) internal pure returns (int256 z) {
        z = int256(x) * y;
        require(int256(x) >= 0, "VaultEngine/mul-overflow");
        require(y == 0 || z / y == int256(x), "VaultEngine/mul-overflow");
    }

    /// @dev Logical AND without short-circuit branching.
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly ("memory-safe") {
            z := and(x, y)
        }
    }
}
