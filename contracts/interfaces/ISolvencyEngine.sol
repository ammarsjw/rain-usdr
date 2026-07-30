// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IExternalExposure } from "./IExternalExposure.sol";
import { IReserveAccounting } from "./IReserveAccounting.sol";
import { IVaultEngine } from "./IVaultEngine.sol";

/**
 * @title ISolvencyEngine
 * @author Rain Team
 * @notice Interface for the contract that enforces the master safety rule.
 */
interface ISolvencyEngine {
    /* ========================== EVENTS ========================== */

    /**
     * @dev Emitted when a stress parameter or dependency is updated.
     * @param what Name of the parameter.
     * @param data New value.
     */
    event File(bytes32 indexed what, uint256 data);

    /**
     * @dev Emitted when a volatile collateral type is added to the stress calculation.
     * @param ilkId Identifier of the collateral type.
     */
    event AddVolatileIlk(bytes32 indexed ilkId);

    /**
     * @dev Emitted when the invariant is checked, for the monitoring system.
     * @param reserve The current stable reserve [wad].
     * @param worstCaseLoss The worst-case loss under stress [wad].
     * @param passed Whether the invariant held.
     */
    event InvariantChecked(uint256 reserve, uint256 worstCaseLoss, bool passed);

    /* ========================== ERRORS ========================== */

    /**
     * @dev Indicates that the worst-case loss exceeds the stable reserve.
     */
    error SolvencyBreach();

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Returns the Vault Engine this engine reports to.
     */
    function VAULT_ENGINE() external view returns (IVaultEngine);

    /**
     * @notice Returns the reserve accounting contract.
     */
    function RESERVE_ACCOUNTING() external view returns (IReserveAccounting);

    /**
     * @notice Returns the prediction market layer's exposure reporter. May be unset at launch.
     */
    function externalExposure() external view returns (IExternalExposure);

    /**
     * @notice Returns the stress markdown applied to volatile asset prices [wad]. 50% = 0.5 * WAD.
     */
    function stressMarkdown() external view returns (uint256);

    /**
     * @notice Returns the assumed liquidation market depth under stress [wad]. 35% = 0.35 * WAD.
     */
    function stressDepth() external view returns (uint256);

    /**
     * @notice Returns a volatile collateral type included in the stress calculation.
     * @param index Position in the volatile collateral list.
     * @return The collateral type identifier.
     */
    function volatileIlks(uint256 index) external view returns (bytes32);

    /**
     * @notice Adjusts a stress parameter: {stressMarkdown} or {stressDepth}.
     * @param what Name of the parameter.
     * @param data New value [wad].
     */
    function file(bytes32 what, uint256 data) external;

    /**
     * @notice Sets an address dependency: {externalExposure}.
     * @param what Name of the parameter.
     * @param data New address.
     */
    function file(bytes32 what, address data) external;

    /**
     * @notice Adds a volatile collateral type to the stress calculation.
     * @param ilkId Identifier of the collateral type.
     */
    function addVolatileIlk(bytes32 ilkId) external;

    /**
     * @notice Enforces the master rule: worst-case loss must never exceed the stable reserve.
     * @dev Reverts with a solvency-breach error if the rule would be broken. On success, updates the committed escrow
     *      in Reserve Accounting and emits a record of the check.
     * @return loss The worst-case loss under stress [wad].
     * @return reserve The current stable reserve [wad].
     */
    function checkInvariant() external returns (uint256 loss, uint256 reserve);

    /**
     * @notice Calculates the most the protocol could lose, assuming a crisis.
     * @dev Assumes volatile assets marked down 50%, liquidation depth at 35% of normal, and correlated assets crashing
     *      together, plus any reported prediction market exposure.
     * @return loss The worst-case loss under stress [wad].
     */
    function worstCaseLoss() external view returns (uint256 loss);
}
