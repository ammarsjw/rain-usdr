// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IPriceSource } from "./IPriceSource.sol";

/**
 * @title IOracleSecurityModule.
 * @author Rain Team.
 * @notice Interface for the delayed price feed.
 */
interface IOracleSecurityModule {
    /* ========================== EVENTS ========================== */

    /// @notice Emitted when an account is granted authorization.
    event Rely(address indexed account);

    /// @notice Emitted when an account has its authorization revoked.
    event Deny(address indexed account);

    /// @notice Emitted when price updates are frozen.
    event Stop();

    /// @notice Emitted when price updates resume.
    event Start();

    /// @notice Emitted when the stored prices are cleared and updates frozen.
    event Void();

    /// @notice Emitted when the price source is switched.
    event Change(address indexed src);

    /// @notice Emitted when a reader is whitelisted.
    event Kiss(address indexed account);

    /// @notice Emitted when a reader's whitelist entry is revoked.
    event Diss(address indexed account);

    /// @notice Emitted when the price advances.
    event Poke(uint128 current, uint128 next);

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Grants authorization to an account.
     * @param account Address to authorize.
     */
    function rely(address account) external;

    /**
     * @notice Revokes authorization from an account.
     * @param account Address to deauthorize.
     */
    function deny(address account) external;

    /**
     * @notice Freezes price updates.
     */
    function stop() external;

    /**
     * @notice Resumes price updates.
     */
    function start() external;

    /**
     * @notice Clears the stored prices and freezes updates.
     */
    function void() external;

    /**
     * @notice Switches where prices come from.
     * @dev Future updates read from the new source; consumers keep reading the same current price.
     * @param src_ Address of the new price source.
     */
    function change(IPriceSource src_) external;

    /**
     * @notice Whitelists a contract to read the price.
     * @param account Address being granted read access.
     */
    function kiss(address account) external;

    /**
     * @notice Revokes a contract's permission to read the price.
     * @param account Address losing read access.
     */
    function diss(address account) external;

    /**
     * @notice Returns whether enough time has passed for the next price update.
     * @return Whether `poke` may be called.
     */
    function pass() external view returns (bool);

    /**
     * @notice Advances the price: the next price becomes current and a fresh price is read
     *         from the source to become the new next.
     * @dev Public — anyone may call — but the 30 minute minimum is always enforced.
     */
    function poke() external;

    /**
     * @notice Returns the current (delayed) price with a validity flag.
     * @return The price, encoded as bytes32.
     * @return Whether the price is valid.
     */
    function peek() external view returns (bytes32, bool);

    /**
     * @notice Previews the next price — the early-warning window for spotting manipulation.
     * @return The next price, encoded as bytes32.
     * @return Whether the price is valid.
     */
    function peep() external view returns (bytes32, bool);

    /**
     * @notice Returns the current (delayed) price, reverting if no valid price is set.
     * @return The price, encoded as bytes32.
     */
    function read() external view returns (bytes32);
}
