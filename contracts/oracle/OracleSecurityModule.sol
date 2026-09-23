// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

import { IOracleSecurityModule } from "../interfaces/IOracleSecurityModule.sol";
import { IPriceConverter } from "../interfaces/IPriceConverter.sol";
import { IPriceSource } from "../interfaces/IPriceSource.sol";
import { ISolvencyEngine } from "../interfaces/ISolvencyEngine.sol";
import { _READER_ROLE, _WARD_ROLE } from "../shared/Constants.sol";
import { InvalidAddress, InvalidAmount, NotLive, StalePrice, UnrecognizedParameter } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title OracleSecurityModule
 * @author Rain Team
 * @notice The delayed price feed. Holds prices back by {delay} so that if a price is manipulated, there is
 *         time to detect and respond before the system acts on it. Stores two prices per collateral type: the
 *         current one (which the system uses) and the next one (which becomes current after the delay). A
 *         single deployed instance serves every priced collateral: tokens are registered dynamically, each
 *         with its own price source.
 *
 *         The delay is a HARD bound: the last poke's exact timestamp is stored unsnapped, so the next poke is
 *         only accepted a full {HOP} after the previous one. A price entering `nxt` therefore always resides
 *         there for at least {HOP} before it can be promoted to `cur`. There is no boundary alignment and no
 *         one-second worst case.
 * @dev A single multi-collateral module keyed by ilk identifier. The per-ilk price source is any
 *      {IPriceSource} implementation, such as a dedicated Uniswap time-weighted average wrapper, a Chainlink
 *      feed wrapper, or any future adapter, so the module never needs to know what kind of oracle backs a
 *      token. Sources are switchable by governance per ilk without any other contract changing.
 */
contract OracleSecurityModule is IOracleSecurityModule, AccessControl {
    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc IOracleSecurityModule
    uint16 public constant HOP = 1800;

    /// @inheritdoc IOracleSecurityModule
    address public solvencyEngine;

    /// @inheritdoc IOracleSecurityModule
    /// @dev The authorized Price Converter (audit M14): called synchronously after every successful `cur`
    ///      promotion and after `void`, BEFORE the solvency refresh, so the Vault Engine's cached spot can
    ///      never lag a promoted price. The call is mandatory (not try/caught): catching a failure would
    ///      preserve exactly the stale-authorization window the wiring exists to close, so a failing
    ///      converter must fail the poke.
    address public priceConverter;

    /// @inheritdoc IOracleSecurityModule
    /// @dev Maximum age of a promoted price before it stops being served (audit M11): `ilk.delay` records the
    ///      timestamp of the last successful promotion, so once `block.timestamp > delay + maxAge` the current
    ///      price is treated as ABSENT on both interfaces — peek returns has = false and read reverts — so
    ///      solvency, auctions, and settlement cannot disagree about freshness. Without this bound a source
    ///      outage preserves the last pre-outage price as valid forever, letting unsafe vaults stay
    ///      unliquidatable and reserve outflows stay open against a stale valuation. Defaults to two OSM
    ///      windows, matching the PriceConverter's tolerance: one window is the normal poke cadence, so a
    ///      single missed keeper cycle never freezes healthy collateral.
    uint256 public maxAge = 3600;

    /// @dev Oracle state per collateral type.
    mapping(bytes32 ilkId => Ilk ilk) private _ilks;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Authorizes the deployer.
     */
    constructor() {
        _setRoleAdmin(_READER_ROLE, _WARD_ROLE);
        _setRoleAdmin(_WARD_ROLE, _WARD_ROLE);

        _grantRole(_WARD_ROLE, msg.sender);
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function file(bytes32 what, address data) external onlyRole(_WARD_ROLE) {
        if (what == "solvencyEngine") {
            solvencyEngine = data;
        } else if (what == "priceConverter") {
            // The converter refresh after a promotion is MANDATORY (audit M14), so a zero address may only
            // be filed deliberately never by accident; rejecting zero here keeps the wiring explicit.
            // Clearing the converter is not supported: once wired, promotions and the cached spot advance
            // atomically, and detaching would silently reopen the stale-authorization window.
            if (data == address(0)) {
                _revert(InvalidAddress.selector);
            }

            priceConverter = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, addr: data });
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function file(bytes32 what, uint256 data) external onlyRole(_WARD_ROLE) {
        if (what == "maxAge") {
            // A zero maxAge would mark every promoted price permanently stale the moment it lands, freezing
            // minting, liquidation kicks, and settlement reads system-wide with no repair path better than
            // refiling. Same guard-the-bricking-direction standard as the PriceConverter's par/tol guards.
            if (data == 0) {
                _revert(InvalidAmount.selector);
            }

            maxAge = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, data: data });
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function stop(bytes32 ilkId) external onlyRole(_WARD_ROLE) {
        _ilks[ilkId].stopped = 1;

        emit Stop({ ilkId: ilkId });
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function start(bytes32 ilkId) external onlyRole(_WARD_ROLE) {
        _ilks[ilkId].stopped = 0;

        emit Start({ ilkId: ilkId });
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function void(bytes32 ilkId) external onlyRole(_WARD_ROLE) {
        Ilk storage ilk = _ilks[ilkId];
        ilk.cur = ilk.nxt = Feed(0, 0);
        ilk.stopped = 1;

        // Mandatory spot refresh (audit M14), the void twin of the promotion path: voiding clears the price
        // this instant, so the Vault Engine's cached spot must zero in the SAME transaction. Relying on a
        // later permissionless PriceConverter.poke would leave the retired price authorizing mints until
        // someone happens to call it — the exact stale-authorization window this wiring closes.
        if (priceConverter != address(0)) {
            IPriceConverter(priceConverter).poke(ilkId);
        }

        emit Void({ ilkId: ilkId });
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function change(bytes32 ilkId, IPriceSource newSrc) external onlyRole(_WARD_ROLE) {
        if (address(newSrc) == address(0)) {
            _revert(InvalidAddress.selector);
        }

        Ilk storage ilk = _ilks[ilkId];
        ilk.src = newSrc;

        // The queued next price still belongs to the outgoing source. Leaving it in place would let the first
        // poke after the switch promote the abandoned source's value into `cur` — precisely the value a
        // rotation away from a misbehaving or compromised source is meant to retire. Clearing the queue means
        // the new source must report twice (once into `nxt`, once promoted) before its price becomes current,
        // preserving the delayed-feed guarantee across the switch. The current price is kept: it was already
        // promoted under the full delay and consumers depend on its availability.
        ilk.nxt = Feed(0, 0);

        emit Change({ ilkId: ilkId, src: address(newSrc) });
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function poke(bytes32 ilkId) external {
        Ilk storage ilk = _ilks[ilkId];

        // The collateral must be registered.
        if (address(ilk.src) == address(0)) {
            _revert(InvalidAddress.selector);
        }

        // The collateral's feed must not be stopped.
        if (ilk.stopped != 0) {
            _revert(NotLive.selector);
        }

        // At least {delay} must have passed since the last update.
        if (!pass(ilkId)) {
            _revert(NotPassed.selector);
        }

        (bytes32 wut, bool ok) = ilk.src.peek();

        // A valid-but-zero price is treated as a failed report: zero is never a real market price, and
        // letting it propagate would freeze minting via a zero spot while looking like a healthy update to
        // monitoring. The value is also validated at the width it will be STORED at: the feed narrows to
        // uint128 on assignment, so a wider report would otherwise be silently truncated to an unrelated
        // number — and a report that is an exact multiple of 2**128 would store the very zero the guard
        // exists to keep out. An out-of-range report takes the failure path, keeping the previous price in
        // place and surfacing the anomaly for monitoring.
        uint256 val = uint256(wut);
        if (ok && val != 0 && val <= type(uint128).max) {
            ilk.cur = ilk.nxt;
            ilk.nxt = Feed(uint128(val), 1);

            // Stored UNSNAPPED: snapping down to the HOP boundary would let a poke at boundary+1799 be
            // followed one second later, collapsing the guaranteed nxt->cur residency to 1 second. The exact
            // timestamp makes {HOP} a hard minimum interval between pokes.
            ilk.delay = uint64(block.timestamp);

            emit Poke({ ilkId: ilkId, current: ilk.cur.val, next: ilk.nxt.val });

            // Mandatory spot refresh (audit M14): the promotion and the Vault Engine's cached spot advance
            // in the SAME transaction, so no permissionless caller can promote a lower price and omit the
            // converter call to draw against the stale higher spot. Deliberately NOT try/caught — catching a
            // failure would preserve exactly the stale-authorization window this call closes, so a failing
            // converter fails the poke (the tradeoff: OSM liveness is coupled to converter liveness).
            if (priceConverter != address(0)) {
                IPriceConverter(priceConverter).poke(ilkId);
            }

            // Soft solvency refresh: a price advance is where a breach FIRST becomes visible (the one input
            // nobody controls), so the breach flag is recomputed immediately rather than waiting for the next
            // keeper cycle. This NEVER reverts: censoring a price update because it carries bad news is how
            // systems die, so the call is wrapped and a mis-wired engine can never block the feed.
            if (solvencyEngine != address(0)) {
                // Low-level call rather than try/catch (audit L02): a try with a `returns` clause omits the
                // code-existence check, so against a code-less target the empty-returndata decode reverts in
                // THIS frame and the catch never runs — a mistyped solvencyEngine would make every successful
                // poke revert, freezing the feed while the stale spot keeps authorizing mints. The result is
                // discarded, so no decode is needed: a code-less target degrades to the intended no-op.
                (bool refreshed, ) = solvencyEngine.call(abi.encodeCall(ISolvencyEngine.checkInvariant, ()));
                refreshed;
            }
        } else {
            // The source refused to report a valid price: surface it for monitoring without reverting.
            emit PokeFailed({ ilkId: ilkId, src: address(ilk.src) });
        }
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function src(bytes32 ilkId) external view returns (IPriceSource) {
        return _ilks[ilkId].src;
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function delay(bytes32 ilkId) external view returns (uint64) {
        return _ilks[ilkId].delay;
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function stopped(bytes32 ilkId) external view returns (uint256) {
        return _ilks[ilkId].stopped;
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function peek(bytes32 ilkId) external view onlyRole(_READER_ROLE) returns (bytes32, bool) {
        Ilk storage ilk = _ilks[ilkId];
        Feed storage cur = ilk.cur;

        // Staleness gate (audit M11): a price older than maxAge is treated as ABSENT, exactly like a missing
        // one. ilk.delay records the last successful promotion, so an outage that stops poke from advancing
        // the feed stops this interface from serving the pre-outage value — fail closed, matching every
        // consumer's existing !has behavior (worstCaseLoss zeroes the collateral, kick reverts).
        bool fresh = block.timestamp <= uint256(ilk.delay) + maxAge;

        return (bytes32(uint256(cur.val)), cur.has == 1 && fresh);
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function peep(bytes32 ilkId) external view onlyRole(_READER_ROLE) returns (bytes32, bool) {
        Feed storage nxt = _ilks[ilkId].nxt;

        return (bytes32(uint256(nxt.val)), nxt.has == 1);
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function read(bytes32 ilkId) external view onlyRole(_READER_ROLE) returns (bytes32) {
        Ilk storage ilk = _ilks[ilkId];
        Feed storage cur = ilk.cur;

        if (cur.has != 1) {
            _revert(NoCurrentValue.selector);
        }

        // Staleness gate (audit M11), the revert twin of peek's has = false: both interfaces must agree on
        // freshness so solvency, auctions, and settlement can never act on different views of the same feed.
        if (block.timestamp > uint256(ilk.delay) + maxAge) {
            _revert(StalePrice.selector);
        }

        return bytes32(uint256(cur.val));
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function pass(bytes32 ilkId) public view returns (bool) {
        return block.timestamp >= _ilks[ilkId].delay + HOP;
    }
}
