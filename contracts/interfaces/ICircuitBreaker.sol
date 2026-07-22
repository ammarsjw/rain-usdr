// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/**
 * @title ICircuitBreaker.
 * @author Rain Team.
 * @notice Interface for the contract that slows liquidations when the price moves suspiciously fast.
 */
interface ICircuitBreaker {
    /* ========================== EVENTS ========================== */

    /// @notice Emitted when an account is granted authorization.
    event Rely(address indexed account);

    /// @notice Emitted when an account has its authorization revoked.
    event Deny(address indexed account);

    /// @notice Emitted when a parameter is updated.
    event File(bytes32 indexed what, uint256 data);

    /// @notice Emitted when the breaker activates.
    event Activated(uint256 deviation);

    /// @notice Emitted when the breaker deactivates.
    event Deactivated();

    /// @notice Emitted on every check, for the dashboard.
    event Checked(uint256 deviation, bool active);

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
     * @notice Adjusts the deviation threshold ("threshold") or the number of calm blocks
     *         needed to reset ("calmBlocks").
     * @param what Name of the parameter.
     * @param data New value.
     */
    function file(bytes32 what, uint256 data) external;

    /**
     * @notice Determines whether prices are moving abnormally and sets the breaker on or off.
     * @dev Public — anyone can call. Activates above the threshold; deactivates after the
     *      required consecutive calm blocks.
     */
    function check() external;

    /**
     * @notice Reports whether the breaker is currently active.
     * @return Whether liquidations are being throttled.
     */
    function active() external view returns (bool);
}
