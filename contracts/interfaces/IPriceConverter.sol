// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/**
 * @title IPriceConverter
 * @author Rain Team
 * @notice Interface for the contract that turns a raw price into a collateralization limit.
 */
interface IPriceConverter {
    /* ========================== EVENTS ========================== */

    /// @notice Emitted when a collateral type's oracle is assigned.
    event File(bytes32 indexed ilkId, bytes32 indexed what, address pip);

    /// @notice Emitted when a global parameter is updated.
    event File(bytes32 indexed what, uint256 data);

    /// @notice Emitted when a per-collateral parameter is updated.
    event File(bytes32 indexed ilkId, bytes32 indexed what, uint256 data);

    /// @notice Emitted when the converter is shut down.
    event Cage();

    /// @notice Emitted when a collateral type's price factor is recalculated.
    event Poke(bytes32 indexed ilkId, bytes32 val, uint256 spot);

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Assigns which oracle a collateral type reads from.
     * @param ilkId Identifier of the collateral type.
     * @param what Name of the parameter ("pip").
     * @param pip_ Address of the Oracle Security Module.
     */
    function file(bytes32 ilkId, bytes32 what, address pip_) external;

    /**
     * @notice Updates a global parameter ("par").
     * @param what Name of the parameter.
     * @param data New value [ray].
     */
    function file(bytes32 what, uint256 data) external;

    /**
     * @notice Sets a collateral type's collateralization ratio ("mat") or marks it as a
     *         supported stablecoin pinned to $1 ("fixed", 1 to set and 0 to clear). Marking an
     *         ilk fixed detaches any assigned oracle — the two kinds are mutually exclusive.
     * @param ilkId Identifier of the collateral type.
     * @param what Name of the parameter.
     * @param data New value [ray] for "mat"; 1 or 0 for "fixed".
     */
    function file(bytes32 ilkId, bytes32 what, uint256 data) external;

    /**
     * @notice Shuts the converter down.
     */
    function cage() external;

    /**
     * @notice Recalculates a collateral type's price factor and pushes it into the Vault
     *         Engine. Fixed-price ilks convert at $1 without an oracle lookup; oracle-backed
     *         ilks read the latest delayed price from their OSM.
     * @dev Public — anyone can trigger it. Does nothing if the price is invalid; reverts for
     *      ilks configured neither fixed nor with an oracle.
     * @param ilkId Identifier of the collateral type.
     */
    function poke(bytes32 ilkId) external;
}
