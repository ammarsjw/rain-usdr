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
     * @param mat The required collateralization ratio [ray]. 400% = 4 * RAY.
     * @param fixedPrice Whether the ilk is a supported stablecoin pinned to $1 (no oracle lookup).
     */
    struct IlkOracle {
        uint256 mat;
        bool fixedPrice;
    }

    /* ========================== EVENTS ========================== */

    /**
     * @dev Emitted when an address dependency is updated.
     * @param what Name of the parameter.
     * @param addr New address.
     */
    event File(bytes32 indexed what, address addr);

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

    /* ========================== ERRORS ========================== */

    /**
     * @dev Indicates that a collateralization ratio below 100% was supplied.
     */
    error MatBelowOne();

    /**
     * @dev Indicates that the collateral type has never been configured (its `mat` is unset), so no spot may be
     *      derived for it.
     */
    error IlkNotConfigured();

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Sets an address dependency {oracleSecurityModule}, the single system-wide Oracle Security Module every
     *         oracle-backed ilk reads from.
     * @param what Name of the parameter.
     * @param data New address.
     */
    function file(bytes32 what, address data) external;

    /**
     * @notice Updates a global parameter {par}.
     * @param what Name of the parameter.
     * @param data New value [ray].
     */
    function file(bytes32 what, uint256 data) external;

    /**
     * @notice Sets a collateral type's collateralization ratio {mat} or marks it as a supported stablecoin pinned to
     *         $1 ({fixed}, 1 to set and 0 to clear). A cleared flag makes the ilk oracle-backed via the single
     *         system-wide OSM; if the OSM does not serve the ilk, {poke} fails closed to a zero spot.
     * @param ilkId Identifier of the collateral type.
     * @param what Name of the parameter.
     * @param data New value [ray] for {mat}, or 1 or 0 for {fixed}.
     */
    function file(bytes32 ilkId, bytes32 what, uint256 data) external;

    /**
     * @notice Recalculates a collateral type's price factor and pushes it into the Vault Engine. Fixed-price ilks
     *         convert at $1 without an oracle lookup. Oracle-backed ilks read the latest delayed price from the
     *         single system-wide OSM.
     * @dev Public, anyone can trigger it. Zeroes the spot (freezing mints) if the price is invalid, and reverts for
     *      ilks that were never configured.
     * @param ilkId Identifier of the collateral type.
     */
    function poke(bytes32 ilkId) external;

    /**
     * @notice Shuts the converter down.
     */
    function cage() external;

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
     * @notice Returns the single system-wide Oracle Security Module every oracle-backed ilk reads from.
     */
    function oracleSecurityModule() external view returns (IOracleSecurityModule);

    /**
     * @notice Returns a collateral type's oracle configuration.
     * @param ilkId Identifier of the collateral type.
     * @return mat The required collateralization ratio [ray].
     * @return fixedPrice Whether the ilk is a supported stablecoin pinned to $1.
     */
    function ilks(bytes32 ilkId) external view returns (uint256 mat, bool fixedPrice);
}
