// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { IOracleSecurityModule } from "./IOracleSecurityModule.sol";
import { IVaultEngine } from "./IVaultEngine.sol";

/**
 * @title IPriceConverter
 * @author Rain Team
 * @notice Interface for the contract that turns a raw price into a collateralization limit.
 */
interface IPriceConverter {
    /* ========================== TYPES ========================== */

    /**
     * @notice Oracle configuration for a collateral type.
     * @param pip The collateral's Oracle Security Module. Zero for fixed-price ilks.
     * @param mat The required collateralization ratio [ray]. 400% = 4 * RAY.
     * @param fixedPrice Whether the ilk is a supported stablecoin pinned to $1 (no oracle).
     */
    struct IlkOracle {
        IOracleSecurityModule pip;
        uint256 mat;
        bool fixedPrice;
    }

    /* ========================== EVENTS ========================== */

    /**
     * @dev Emitted when a collateral type's oracle is assigned.
     * @param ilkId Identifier of the collateral type.
     * @param what Name of the parameter.
     * @param pip Address of the Oracle Security Module.
     */
    event File(bytes32 indexed ilkId, bytes32 indexed what, address pip);

    /**
     * @dev Emitted when a global parameter is updated.
     * @param what Name of the parameter.
     * @param data New value [ray].
     */
    event File(bytes32 indexed what, uint256 data);

    /**
     * @dev Emitted when a per-collateral parameter is updated.
     * @param ilkId Identifier of the collateral type.
     * @param what Name of the parameter.
     * @param data New value.
     */
    event File(bytes32 indexed ilkId, bytes32 indexed what, uint256 data);

    /**
     * @dev Emitted when a collateral type's price factor is recalculated.
     * @param ilkId Identifier of the collateral type.
     * @param val The price used in the calculation.
     * @param spot The resulting price factor [ray].
     */
    event Poke(bytes32 indexed ilkId, bytes32 val, uint256 spot);

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Returns the Vault Engine this converter reports to.
     */
    function VAULT_ENGINE() external view returns (IVaultEngine);

    /**
     * @notice Returns the target dollar value of USDR [ray]. Fixed at 1.0.
     */
    function par() external view returns (uint256);

    /**
     * @notice Returns the liveness flag. `1` while live, `0` after shutdown.
     */
    function live() external view returns (uint256);

    /**
     * @notice Returns a collateral type's oracle configuration.
     * @param ilkId Identifier of the collateral type.
     * @return pip The collateral's Oracle Security Module. Zero for fixed-price ilks.
     * @return mat The required collateralization ratio [ray].
     * @return fixedPrice Whether the ilk is a supported stablecoin pinned to $1.
     */
    function ilks(bytes32 ilkId) external view returns (IOracleSecurityModule pip, uint256 mat, bool fixedPrice);

    /**
     * @notice Assigns which oracle a collateral type reads from.
     * @param ilkId Identifier of the collateral type.
     * @param what Name of the parameter: {pip}.
     * @param pip_ Address of the Oracle Security Module.
     */
    function file(bytes32 ilkId, bytes32 what, address pip_) external;

    /**
     * @notice Updates a global parameter: {par}.
     * @param what Name of the parameter.
     * @param data New value [ray].
     */
    function file(bytes32 what, uint256 data) external;

    /**
     * @notice Sets a collateral type's collateralization ratio: {mat} or marks it as a supported stablecoin pinned to
     *         $1 ({fixed}, 1 to set and 0 to clear). Marking an ilk fixed detaches any assigned oracle, as the two
     *         kinds are mutually exclusive.
     * @param ilkId Identifier of the collateral type.
     * @param what Name of the parameter.
     * @param data New value [ray] for {mat}, or 1 or 0 for {fixed}.
     */
    function file(bytes32 ilkId, bytes32 what, uint256 data) external;

    /**
     * @notice Shuts the converter down.
     */
    function cage() external;

    /**
     * @notice Recalculates a collateral type's price factor and pushes it into the Vault Engine. Fixed-price ilks
     *         convert at $1 without an oracle lookup. Oracle-backed ilks read the latest delayed price from their OSM.
     * @dev Public, anyone can trigger it. Does nothing if the price is invalid, and reverts for ilks configured
     *      neither fixed nor with an oracle.
     * @param ilkId Identifier of the collateral type.
     */
    function poke(bytes32 ilkId) external;
}
