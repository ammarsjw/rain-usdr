// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { IExternalExposure } from "./IExternalExposure.sol";
import { IOracleSecurityModule } from "./IOracleSecurityModule.sol";
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
     * @dev Emitted when a volatile collateral type is removed from the stress calculation.
     * @param ilkId Identifier of the collateral type.
     */
    event RemoveVolatileIlk(bytes32 indexed ilkId);

    /**
     * @dev Emitted when the external exposure reporter reverts or reports above the cap, and the conservative cap is
     *      used instead.
     * @param reported The value reported (`type(uint256).max` when the reporter reverted).
     * @param cap The exposure cap that was applied [wad].
     */
    event ExposureClamped(uint256 reported, uint256 cap);

    /**
     * @dev Emitted when the invariant is checked, for the monitoring system.
     * @param reserve The current stable reserve [wad].
     * @param worstCaseLoss The worst-case loss under stress [wad].
     * @param passed Whether the invariant held.
     */
    event InvariantChecked(uint256 reserve, uint256 worstCaseLoss, bool passed);

    /* ========================== ERRORS ========================== */

    /**
     * @dev Indicates that a stress or threshold parameter outside (0, WAD] was supplied.
     */
    error ParameterOutOfBounds();

    /**
     * @dev Indicates that an exposure reporter cannot be wired while the exposure cap is unset.
     */
    error ExposureCapNotSet();

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Adjusts a stress parameter {stressMarkdown} or {stressDepth}.
     * @param what Name of the parameter.
     * @param data New value [wad].
     */
    function file(bytes32 what, uint256 data) external;

    /**
     * @notice Sets an address dependency {externalExposure}.
     * @param what Name of the parameter.
     * @param data New address.
     */
    function file(bytes32 what, address data) external;

    /**
     * @notice Adds a volatile collateral type to the stress calculation.
     * @dev Reverts if the ilk is already registered.
     * @param ilkId Identifier of the collateral type.
     */
    function addVolatileIlk(bytes32 ilkId) external;

    /**
     * @notice Removes a volatile collateral type from the stress calculation (swap-and-pop).
     * @dev Reverts if the ilk is not registered.
     * @param ilkId Identifier of the collateral type.
     */
    function removeVolatileIlk(bytes32 ilkId) external;

    /**
     * @notice Recomputes the master rule: worst-case loss must stay under the gated fraction of the stable reserve.
     * @dev NEVER reverts on a breach: it always updates the committed escrow and the {breached} flag so downstream
     *      accounting can never go stale. A keeper bot is expected to call this regularly.
     * @return loss The worst-case loss under stress [wad].
     * @return reserve The current stable reserve [wad].
     */
    function checkInvariant() external returns (uint256 loss, uint256 reserve);

    /**
     * @notice Returns whether the solvency invariant was breached at the last {checkInvariant} call.
     */
    function isBreached() external view returns (bool);

    /**
     * @notice Returns the loss level above which the invariant is considered breached [wad].
     */
    function breachThreshold() external view returns (uint256);

    /**
     * @notice Calculates the most the protocol could lose, assuming a crisis.
     * @dev Assumes volatile assets marked down 50%, liquidation depth at 35% of normal, and correlated assets crashing
     *      together, plus any reported prediction market exposure.
     * @return loss The worst-case loss under stress [wad].
     */
    function worstCaseLoss() external view returns (uint256 loss);

    /**
     * @notice Returns the Vault Engine this engine reports to.
     */
    function VAULT_ENGINE() external view returns (IVaultEngine);

    /**
     * @notice Returns the reserve accounting contract.
     */
    function RESERVE_ACCOUNTING() external view returns (IReserveAccounting);

    /**
     * @notice Returns the stress markdown applied to volatile asset prices [wad]. 50% = 0.5 * WAD.
     */
    function stressMarkdown() external view returns (uint256);

    /**
     * @notice Returns the assumed liquidation market depth under stress [wad]. 35% = 0.35 * WAD.
     */
    function stressDepth() external view returns (uint256);

    /**
     * @notice Returns the reserve fraction above which a worst-case loss flags a breach [wad]. 90% = 0.9 * WAD.
     */
    function reserveFactor() external view returns (uint256);

    /**
     * @notice Returns the cap applied to externally reported exposure [wad].
     */
    function exposureCap() external view returns (uint256);

    /**
     * @notice Returns the breach flag as last computed by {checkInvariant}.
     */
    function breached() external view returns (bool);

    /**
     * @notice Returns the Oracle Security Module the stress scenario prices collateral from.
     */
    function osm() external view returns (IOracleSecurityModule);

    /**
     * @notice Returns the prediction market layer's exposure reporter.
     */
    function externalExposure() external view returns (IExternalExposure);

    /**
     * @notice Returns a volatile collateral type included in the stress calculation.
     * @param index Position in the volatile collateral list.
     * @return The collateral type identifier.
     */
    function volatileIlks(uint256 index) external view returns (bytes32);

    /**
     * @notice Returns whether an ilk is registered as volatile in the stress calculation.
     * @param ilkId Identifier of the collateral type.
     */
    function isVolatile(bytes32 ilkId) external view returns (bool);
}
