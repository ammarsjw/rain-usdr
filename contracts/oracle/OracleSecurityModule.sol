// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IOracleSecurityModule } from "../interfaces/IOracleSecurityModule.sol";
import { IPriceSource } from "../interfaces/IPriceSource.sol";
import { Auth } from "../extensions/Auth.sol";
import { READER_ROLE, WARD_ROLE } from "../shared/Constants.sol";
import { InvalidAddress, NotLive } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title OracleSecurityModule.
 * @author Rain Team.
 * @notice The delayed price feed. Holds prices back by 30 minutes so that if a price is
 *         manipulated, there is time to detect and respond before the system acts on it.
 *         Stores two prices: the current one (which the system uses) and the next one (which
 *         becomes current after the delay). One instance per priced collateral.
 * @dev Based on MakerDAO's OSM. The price source is switchable by governance (e.g. from a
 *      Uniswap time-weighted average to a Chainlink feed) without any other contract changing.
 */
contract OracleSecurityModule is IOracleSecurityModule, Auth {
    /* ========================== TYPES ========================== */

    /// @dev A stored price and its validity flag.
    struct Feed {
        uint128 val;
        uint128 has;
    }

    /* ========================== STATE VARIABLES ========================== */

    /// @notice The raw price source being read.
    IPriceSource public src;

    /// @notice Update delay in seconds (30 minutes).
    uint16 public constant hop = 1800;

    /// @notice Timestamp of the start of the current delay window.
    uint64 public zzz;

    /// @notice Module liveness flag. `1` while updating, `0` when stopped.
    uint256 public stopped;

    /// @dev The current (delayed) price the system uses.
    Feed internal cur;

    /// @dev The next price, which becomes current after the delay.
    Feed internal nxt;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the module with its price source.
     * @param src_ Address of the raw price source.
     */
    constructor(IPriceSource src_) {
        src = src_;
    }

    /* ========================== ADMINISTRATION ========================== */

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function stop() external onlyRole(WARD_ROLE) {
        stopped = 1;

        emit Stop();
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function start() external onlyRole(WARD_ROLE) {
        stopped = 0;

        emit Start();
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function void() external onlyRole(WARD_ROLE) {
        cur = nxt = Feed(0, 0);
        stopped = 1;

        emit Void();
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function change(IPriceSource src_) external onlyRole(WARD_ROLE) {
        if (address(src_) == address(0)) {
            _revert(InvalidAddress.selector);
        }

        src = src_;

        emit Change({ src: address(src_) });
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function kiss(address account) external onlyRole(WARD_ROLE) {
        if (account == address(0)) {
            _revert(InvalidAddress.selector);
        }

        _grantRole(READER_ROLE, account);

        emit Kiss({ account: account });
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function diss(address account) external onlyRole(WARD_ROLE) {
        _revokeRole(READER_ROLE, account);

        emit Diss({ account: account });
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function pass() public view returns (bool) {
        return block.timestamp >= zzz + hop;
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function poke() external {
        // The module must not be stopped.
        if (stopped != 0) {
            _revert(NotLive.selector);
        }
        // At least 30 minutes must have passed since the last update.
        require(pass(), "OracleSecurityModule/not-passed");

        (bytes32 wut, bool ok) = src.peek();

        if (ok) {
            cur = nxt;
            nxt = Feed(uint128(uint256(wut)), 1);
            zzz = uint64(block.timestamp - (block.timestamp % hop));

            emit Poke({ current: cur.val, next: nxt.val });
        }
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function peek() external view onlyRole(READER_ROLE) returns (bytes32, bool) {
        return (bytes32(uint256(cur.val)), cur.has == 1);
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function peep() external view onlyRole(READER_ROLE) returns (bytes32, bool) {
        return (bytes32(uint256(nxt.val)), nxt.has == 1);
    }

    /**
     * @inheritdoc IOracleSecurityModule
     */
    function read() external view onlyRole(READER_ROLE) returns (bytes32) {
        require(cur.has == 1, "OracleSecurityModule/no-current-value");

        return bytes32(uint256(cur.val));
    }
}
