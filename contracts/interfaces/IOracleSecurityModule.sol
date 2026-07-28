// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IPriceSource } from "./IPriceSource.sol";

/**
 * @title IOracleSecurityModule
 * @author Rain Team
 * @notice Interface for the delayed price feed serving every priced collateral from a single
 *         deployed instance.
 */
interface IOracleSecurityModule {
    /* ========================== EVENTS ========================== */

    /// @notice Emitted when a collateral's price updates are frozen.
    event Stop(bytes32 indexed ilkId);

    /// @notice Emitted when a collateral's price updates resume.
    event Start(bytes32 indexed ilkId);

    /// @notice Emitted when a collateral's stored prices are cleared and updates frozen.
    event Void(bytes32 indexed ilkId);

    /// @notice Emitted when a collateral's price source is registered or switched.
    event Change(bytes32 indexed ilkId, address indexed src);

    /// @notice Emitted when a reader is whitelisted.
    event Kiss(address indexed account);

    /// @notice Emitted when a reader's whitelist entry is revoked.
    event Diss(address indexed account);

    /// @notice Emitted when a collateral's price advances.
    event Poke(bytes32 indexed ilkId, uint128 current, uint128 next);

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Returns the price source of a collateral type.
     * @param ilkId Identifier of the collateral type.
     * @return The price source.
     */
    function src(bytes32 ilkId) external view returns (IPriceSource);

    /**
     * @notice Returns the timestamp of the start of a collateral's current delay window.
     * @param ilkId Identifier of the collateral type.
     * @return The window start timestamp.
     */
    function zzz(bytes32 ilkId) external view returns (uint64);

    /**
     * @notice Returns whether a collateral's price updates are frozen.
     * @param ilkId Identifier of the collateral type.
     * @return `1` when frozen, `0` when updating.
     */
    function stopped(bytes32 ilkId) external view returns (uint256);

    /**
     * @notice Freezes a collateral's price updates.
     * @param ilkId Identifier of the collateral type.
     */
    function stop(bytes32 ilkId) external;

    /**
     * @notice Resumes a collateral's price updates.
     * @param ilkId Identifier of the collateral type.
     */
    function start(bytes32 ilkId) external;

    /**
     * @notice Clears a collateral's stored prices and freezes its updates.
     * @param ilkId Identifier of the collateral type.
     */
    function void(bytes32 ilkId) external;

    /**
     * @notice Registers a collateral's price source, or switches an existing one. This is how
     *         new tokens are added to the module: any {IPriceSource} adapter works, whether it
     *         wraps a Uniswap time-weighted average or a Chainlink feed.
     * @dev Future updates read from the new source; consumers keep reading the same current
     *      price until the next poke cycle completes.
     * @param ilkId Identifier of the collateral type.
     * @param src_ Address of the price source.
     */
    function change(bytes32 ilkId, IPriceSource src_) external;

    /**
     * @notice Whitelists a contract to read prices.
     * @param account Address being granted read access.
     */
    function kiss(address account) external;

    /**
     * @notice Revokes a contract's permission to read prices.
     * @param account Address losing read access.
     */
    function diss(address account) external;

    /**
     * @notice Returns whether enough time has passed for a collateral's next price update.
     * @param ilkId Identifier of the collateral type.
     * @return Whether `poke` may be called.
     */
    function pass(bytes32 ilkId) external view returns (bool);

    /**
     * @notice Advances a collateral's price: the next price becomes current and a fresh price
     *         is read from the source to become the new next.
     * @dev Public — anyone may call — but the 30 minute minimum is always enforced.
     * @param ilkId Identifier of the collateral type.
     */
    function poke(bytes32 ilkId) external;

    /**
     * @notice Returns a collateral's current (delayed) price with a validity flag.
     * @param ilkId Identifier of the collateral type.
     * @return The price, encoded as bytes32.
     * @return Whether the price is valid.
     */
    function peek(bytes32 ilkId) external view returns (bytes32, bool);

    /**
     * @notice Previews a collateral's next price — the early-warning window for spotting
     *         manipulation.
     * @param ilkId Identifier of the collateral type.
     * @return The next price, encoded as bytes32.
     * @return Whether the price is valid.
     */
    function peep(bytes32 ilkId) external view returns (bytes32, bool);

    /**
     * @notice Returns a collateral's current (delayed) price, reverting if no valid price is
     *         set.
     * @param ilkId Identifier of the collateral type.
     * @return The price, encoded as bytes32.
     */
    function read(bytes32 ilkId) external view returns (bytes32);
}
