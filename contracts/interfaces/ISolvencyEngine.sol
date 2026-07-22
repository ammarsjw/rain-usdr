// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/**
 * @title ISolvencyEngine.
 * @author Rain Team.
 * @notice Interface for the contract that enforces the master safety rule.
 */
interface ISolvencyEngine {
    /* ========================== EVENTS ========================== */

    /// @notice Emitted when an account is granted authorization.
    event Rely(address indexed account);

    /// @notice Emitted when an account has its authorization revoked.
    event Deny(address indexed account);

    /// @notice Emitted when a stress parameter or dependency is updated.
    event File(bytes32 indexed what, uint256 data);

    /// @notice Emitted when a volatile collateral type is added to the stress calculation.
    event AddVolatileIlk(bytes32 indexed ilkId);

    /// @notice Emitted when the invariant is checked, for the monitoring system.
    event InvariantChecked(uint256 reserve, uint256 worstCaseLoss, bool passed);

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
     * @notice Adjusts a stress parameter: "stressMarkdown" or "stressDepth".
     * @param what Name of the parameter.
     * @param data New value [wad].
     */
    function file(bytes32 what, uint256 data) external;

    /**
     * @notice Sets an address dependency: "externalExposure".
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
     * @notice Calculates the most the protocol could lose, assuming a crisis.
     * @dev Assumes volatile assets marked down 50%, liquidation depth at 35% of normal, and
     *      correlated assets crashing together, plus any reported prediction market exposure.
     * @return loss The worst-case loss under stress [wad].
     */
    function worstCaseLoss() external view returns (uint256 loss);

    /**
     * @notice Enforces the master rule: worst-case loss must never exceed the stable reserve.
     * @dev Reverts with a solvency-breach error if the rule would be broken. On success,
     *      updates the committed escrow in Reserve Accounting and emits a record of the check.
     * @return loss The worst-case loss under stress [wad].
     * @return reserve The current stable reserve [wad].
     */
    function checkInvariant() external returns (uint256 loss, uint256 reserve);
}
