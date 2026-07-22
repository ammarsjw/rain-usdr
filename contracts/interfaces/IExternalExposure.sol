// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/**
 * @title IExternalExposure.
 * @author Rain Team.
 * @notice Dedicated interface through which the prediction market layer (owned by a separate
 *         team) reports its exposure. The Solvency Engine consumes this figure as a number.
 */
interface IExternalExposure {
    /**
     * @notice Returns the exposure currently reported by the prediction market layer.
     * @return The reported exposure [wad].
     */
    function reportedExposure() external view returns (uint256);
}
