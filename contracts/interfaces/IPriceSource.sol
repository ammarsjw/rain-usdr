// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/**
 * @title IPriceSource
 * @author Rain Team
 * @notice Interface for a raw price source consumed by the Oracle Security Module. Implemented by the Uniswap
 *         time-weighted average wrapper and, for future assets, Chainlink wrappers.
 */
interface IPriceSource {
    /**
     * @notice Returns the latest raw price and whether it is valid.
     * @return wut The price [wad], encoded as bytes32.
     * @return ok Whether the price is valid.
     */
    function peek() external view returns (bytes32 wut, bool ok);
}
