// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { Auth } from "../extensions/Auth.sol";
import { IOracleSecurityModule } from "../interfaces/IOracleSecurityModule.sol";
import { IPriceSource } from "../interfaces/IPriceSource.sol";
import { _READER_ROLE, _WARD_ROLE } from "../shared/Constants.sol";
import { InvalidAddress, NotLive } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title OracleSecurityModule
 * @author Rain Team
 * @notice The delayed price feed. Holds prices back by 30 minutes so that if a price is manipulated, there is time
 *         to detect and respond before the system acts on it. Stores two prices per collateral type: the current
 *         one (which the system uses) and the next one (which becomes current after the delay). A single deployed
 *         instance serves every priced collateral: tokens are registered dynamically, each with its own price
 *         source.
 * @dev Based on MakerDAO's OSM, generalized from one-instance-per-collateral to a single multi-collateral module
 *      keyed by ilk identifier. The per-ilk price source is any {IPriceSource} implementation — a dedicated Uniswap
 *      time-weighted average wrapper, a Chainlink feed wrapper, or any future adapter — so the module never needs to
 *      know what kind of oracle backs a token. Sources are switchable by governance per ilk without any other
 *      contract changing.
 */
contract OracleSecurityModule is IOracleSecurityModule, Auth {
    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc IOracleSecurityModule
    uint16 public constant HOP = 1800;

    /// @dev Oracle state per collateral type.
    mapping(bytes32 ilkId => Ilk ilk) internal _ilks;

    /* ========================== TYPES ========================== */

    /// @dev A stored price and its validity flag.
    struct Feed {
        uint128 val;
        uint128 has;
    }

    /// @dev Per-collateral oracle state.
    struct Ilk {
        IPriceSource src;
        uint64 zzz;
        uint256 stopped;
        Feed cur;
        Feed nxt;
    }

    /* ========================== FUNCTIONS ========================== */

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
    function change(bytes32 ilkId, IPriceSource src_) external onlyRole(_WARD_ROLE) {
        if (address(src_) == address(0)) {
            _revert(InvalidAddress.selector);
        }

        _ilks[ilkId].src = src_;

        emit Change({ ilkId: ilkId, src: address(src_) });
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function kiss(address account) external onlyRole(_WARD_ROLE) {
        if (account == address(0)) {
            _revert(InvalidAddress.selector);
        }

        _grantRole(_READER_ROLE, account);

        emit Kiss({ account: account });
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function diss(address account) external onlyRole(_WARD_ROLE) {
        _revokeRole(_READER_ROLE, account);

        emit Diss({ account: account });
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
        // At least 30 minutes must have passed since the last update.
        require(pass(ilkId), "OracleSecurityModule/not-passed");

        (bytes32 wut, bool ok) = ilk.src.peek();

        if (ok) {
            ilk.cur = ilk.nxt;
            ilk.nxt = Feed(uint128(uint256(wut)), 1);
            ilk.zzz = uint64(block.timestamp - (block.timestamp % HOP));

            emit Poke({ ilkId: ilkId, current: ilk.cur.val, next: ilk.nxt.val });
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
    function zzz(bytes32 ilkId) external view returns (uint64) {
        return _ilks[ilkId].zzz;
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

        return (bytes32(uint256(cur.val)), cur.has == 1);
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
        Feed storage cur = _ilks[ilkId].cur;
        require(cur.has == 1, "OracleSecurityModule/no-current-value");

        return bytes32(uint256(cur.val));
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function pass(bytes32 ilkId) public view returns (bool) {
        return block.timestamp >= _ilks[ilkId].zzz + HOP;
    }
}
