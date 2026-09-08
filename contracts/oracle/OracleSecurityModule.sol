// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

import { IOracleSecurityModule } from "../interfaces/IOracleSecurityModule.sol";
import { IPriceSource } from "../interfaces/IPriceSource.sol";
import { ISolvencyEngine } from "../interfaces/ISolvencyEngine.sol";
import { _READER_ROLE, _WARD_ROLE } from "../shared/Constants.sol";
import { InvalidAddress, NotLive, UnrecognizedParameter } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title OracleSecurityModule
 * @author Rain Team
 * @notice The delayed price feed. Holds prices back by {delay} so that if a price is manipulated, there is time to
 *         detect and respond before the system acts on it. Stores two prices per collateral type: the current one
 *         (which the system uses) and the next one (which becomes current after the delay). A single deployed instance
 *         serves every priced collateral: tokens are registered dynamically, each with its own price source.
 *
 *         The delay is a HARD bound: the last poke's exact timestamp is stored unsnapped, so the next poke is only
 *         accepted a full {HOP} after the previous one. A price entering `nxt` therefore always resides there for at
 *         least {HOP} before it can be promoted to `cur`. There is no boundary alignment and no one-second worst case.
 * @dev A single multi-collateral module keyed by ilk identifier. The per-ilk price source is any {IPriceSource}
 *      implementation, such as a dedicated Uniswap time-weighted average wrapper, a Chainlink feed wrapper, or any
 *      future adapter, so the module never needs to know what kind of oracle backs a token. Sources are switchable by
 *      governance per ilk without any other contract changing. When {maxAge} is nonzero, {peek}/{read} treat a price
 *      whose last successful poke is older than {maxAge} as invalid (fail closed).
 */
contract OracleSecurityModule is IOracleSecurityModule, AccessControl {
    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc IOracleSecurityModule
    uint16 public constant HOP = 1800;

    /// @inheritdoc IOracleSecurityModule
    ISolvencyEngine public solvencyEngine;

    /// @inheritdoc IOracleSecurityModule
    uint256 public maxAge;

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
            solvencyEngine = ISolvencyEngine(data);
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
            // Zero disables the staleness check. A nonzero value marks peek/read invalid once the last successful poke
            // is older than maxAge seconds.
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

        emit Void({ ilkId: ilkId });
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function change(bytes32 ilkId, IPriceSource newSrc) external onlyRole(_WARD_ROLE) {
        if (address(newSrc) == address(0)) {
            _revert(InvalidAddress.selector);
        }

        _ilks[ilkId].src = newSrc;

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

        // A valid-but-zero price is treated as a failed report: zero is never a real market price, and letting it
        // propagate would freeze minting via a zero spot while looking like a healthy update to monitoring.
        if (ok && uint256(wut) != 0) {
            ilk.cur = ilk.nxt;
            ilk.nxt = Feed(uint128(uint256(wut)), 1);

            // Stored UNSNAPPED: snapping down to the HOP boundary would let a poke at boundary+1799 be followed one
            // second later, collapsing the guaranteed nxt->cur residency to 1 second. The exact timestamp makes {HOP}
            // a hard minimum interval between pokes.
            ilk.delay = uint64(block.timestamp);

            emit Poke({ ilkId: ilkId, current: ilk.cur.val, next: ilk.nxt.val });

            // Soft solvency refresh: a price advance is where a breach FIRST becomes visible (the one input nobody
            // controls), so the breach flag is recomputed immediately rather than waiting for the next keeper cycle.
            // This NEVER reverts: censoring a price update because it carries bad news is how systems die, so the call
            // is wrapped and a mis-wired engine can never block the feed.
            if (address(solvencyEngine) != address(0)) {
                try solvencyEngine.checkInvariant() returns (uint256, uint256) {} catch {}
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
        Feed storage cur = _ilks[ilkId].cur;

        return (bytes32(uint256(cur.val)), _isFresh(ilkId, cur.has == 1));
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function peep(bytes32 ilkId) external view onlyRole(_READER_ROLE) returns (bytes32, bool) {
        Feed storage nxt = _ilks[ilkId].nxt;

        return (bytes32(uint256(nxt.val)), _isFresh(ilkId, nxt.has == 1));
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function read(bytes32 ilkId) external view onlyRole(_READER_ROLE) returns (bytes32) {
        Feed storage cur = _ilks[ilkId].cur;

        if (!_isFresh(ilkId, cur.has == 1)) {
            _revert(NoCurrentValue.selector);
        }

        return bytes32(uint256(cur.val));
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function pass(bytes32 ilkId) public view returns (bool) {
        return block.timestamp >= _ilks[ilkId].delay + HOP;
    }

    /**
     * @dev A stored price is fresh when it is present and, if {maxAge} is configured, its last successful poke is
     *      still within the allowed age. `delay` is the unsnapped timestamp of that poke.
     * @param ilkId Identifier of the collateral type.
     * @param has Whether the feed slot currently holds a value.
     * @return Whether consumers may treat the value as live.
     */
    function _isFresh(bytes32 ilkId, bool has) private view returns (bool) {
        if (!has) {
            return false;
        }

        if (maxAge == 0) {
            return true;
        }

        return block.timestamp <= uint256(_ilks[ilkId].delay) + maxAge;
    }
}
