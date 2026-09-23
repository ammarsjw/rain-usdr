// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { IPriceSource } from "./IPriceSource.sol";

/**
 * @title IOracleSecurityModule
 * @author Rain Team
 * @notice Interface for the delayed price feed serving every priced collateral from a single deployed
 *         instance.
 */
interface IOracleSecurityModule {
    /* ========================== TYPES ========================== */

    /// @dev A stored price and its validity flag.
    struct Feed {
        uint128 val;
        uint128 has;
    }

    /// @dev Per-collateral oracle state.
    struct Ilk {
        IPriceSource src;
        uint64 delay;
        uint256 stopped;
        Feed cur;
        Feed nxt;
    }

    /* ========================== EVENTS ========================== */

    /**
     * @dev Emitted when an address dependency is updated.
     * @param what Name of the parameter.
     * @param addr New address.
     */
    event File(bytes32 indexed what, address addr);

    /**
     * @dev Emitted when a numeric parameter is adjusted (audit M11).
     * @param what Name of the parameter.
     * @param data New value.
     */
    event File(bytes32 indexed what, uint256 data);

    /**
     * @dev Emitted when a collateral's price updates are frozen.
     * @param ilkId Identifier of the collateral type.
     */
    event Stop(bytes32 indexed ilkId);

    /**
     * @dev Emitted when a collateral's price updates resume.
     * @param ilkId Identifier of the collateral type.
     */
    event Start(bytes32 indexed ilkId);

    /**
     * @dev Emitted when a collateral's stored prices are cleared and updates frozen.
     * @param ilkId Identifier of the collateral type.
     */
    event Void(bytes32 indexed ilkId);

    /**
     * @dev Emitted when a collateral's price source is registered or switched.
     * @param ilkId Identifier of the collateral type.
     * @param src Address of the new price source.
     */
    event Change(bytes32 indexed ilkId, address indexed src);

    /**
     * @dev Emitted when a collateral's price advances.
     * @param ilkId Identifier of the collateral type.
     * @param current The new current (delayed) price.
     * @param next The new next price.
     */
    event Poke(bytes32 indexed ilkId, uint128 current, uint128 next);

    /**
     * @dev Emitted when a poke finds the price source reporting an invalid value. The stored prices are
     *      untouched.
     * @param ilkId Identifier of the collateral type.
     * @param src Address of the price source that failed.
     */
    event PokeFailed(bytes32 indexed ilkId, address indexed src);

    /* ========================== ERRORS ========================== */

    /**
     * @dev Indicates that the update delay has not yet elapsed.
     */
    error NotPassed();

    /**
     * @dev Indicates that no current price is set for the collateral.
     */
    error NoCurrentValue();

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Sets an address dependency {solvencyEngine}.
     * @dev The Solvency Engine is consulted SOFTLY after every successful poke: the breach flag is refreshed
     *      but a failure can never block the price update.
     * @param what Name of the parameter.
     * @param data New address.
     */
    function file(bytes32 what, address data) external;

    /**
     * @notice Adjusts a numeric parameter: `maxAge`, the maximum age of a promoted price before it stops
     *         being served (audit M11). Zero is rejected — it would mark every price permanently stale.
     * @param what Name of the parameter.
     * @param data New value.
     */
    function file(bytes32 what, uint256 data) external;

    /**
     * @notice Maximum age [seconds] of a promoted price before peek reports has = false and read reverts
     *         (audit M11). Measured from the last successful promotion timestamp ({delay}).
     * @return The maximum age in seconds.
     */
    function maxAge() external view returns (uint256);

    /**
     * @notice The authorized Price Converter (audit M14), called synchronously after every successful
     *         promotion and after void so the cached spot can never lag a promoted price.
     * @return The Price Converter address.
     */
    function priceConverter() external view returns (address);

    /**
     * @notice Freezes a collateral's price updates.
     * @dev CAUTION: stop blocks {poke} only; {peek}/{read} keep serving the LAST STORED price as live
     *      (`has == true`), so consumers continue trusting a frozen value. Use stop when the stored price is
     *      trusted and updates must halt (e.g. source maintenance). For a suspected-compromised feed use
     *      {void}, which is fail-closed: it wipes the stored prices so consumers value the collateral at
     *      zero.
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
     * @notice Registers a collateral's price source, or switches an existing one. This is how new tokens are
     *         added to the module. Any {IPriceSource} adapter works, whether it wraps a Uniswap time-weighted
     *         average or a Chainlink feed.
     * @dev Future updates read from the new source. Consumers keep reading the same current price until the
     *      next poke cycle completes.
     * @param ilkId Identifier of the collateral type.
     * @param newSrc Address of the new price source.
     */
    function change(bytes32 ilkId, IPriceSource newSrc) external;

    /**
     * @notice Advances a collateral's price: the next price becomes current and a fresh price is read from
     *         the source to become the new next.
     * @dev Public, anyone may call, but the 30 minute minimum is always enforced.
     * @param ilkId Identifier of the collateral type.
     */
    function poke(bytes32 ilkId) external;

    /**
     * @notice Returns the price source of a collateral type.
     * @param ilkId Identifier of the collateral type.
     * @return src The price source.
     */
    function src(bytes32 ilkId) external view returns (IPriceSource);

    /**
     * @notice Returns the timestamp of the start of a collateral's current delay window.
     * @param ilkId Identifier of the collateral type.
     * @return delay The window start timestamp.
     */
    function delay(bytes32 ilkId) external view returns (uint64);

    /**
     * @notice Returns whether a collateral's price updates are frozen.
     * @param ilkId Identifier of the collateral type.
     * @return stopped Status. `1` when frozen, `0` when updating.
     */
    function stopped(bytes32 ilkId) external view returns (uint256);

    /**
     * @notice Returns a collateral's current (delayed) price with a validity flag.
     * @param ilkId Identifier of the collateral type.
     * @return encodedPrice The price, encoded as bytes32.
     * @return isValid Whether the price is valid.
     */
    function peek(bytes32 ilkId) external view returns (bytes32, bool);

    /**
     * @notice Previews a collateral's next price, the early-warning window for spotting manipulation.
     * @param ilkId Identifier of the collateral type.
     * @return encodedNextPrice The next price, encoded as bytes32.
     * @return isValid Whether the price is valid.
     */
    function peep(bytes32 ilkId) external view returns (bytes32, bool);

    /**
     * @notice Returns a collateral's current (delayed) price, reverting if no valid price is set.
     * @param ilkId Identifier of the collateral type.
     * @return encodedPrice The price, encoded as bytes32.
     */
    function read(bytes32 ilkId) external view returns (bytes32);

    /**
     * @notice Returns whether enough time has passed for a collateral's next price update.
     * @param ilkId Identifier of the collateral type.
     * @return isCallable Whether `poke` may be called.
     */
    function pass(bytes32 ilkId) external view returns (bool);

    /**
     * @notice Returns the update delay in seconds.
     */
    function HOP() external view returns (uint16);

    /**
     * @notice Returns the Solvency Engine softly refreshed on every successful poke. Zero when unset.
     */
    function solvencyEngine() external view returns (address);
}
