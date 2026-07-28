// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IPriceSource } from "../../contracts/interfaces/IPriceSource.sol";

/**
 * @title MockPriceSource
 * @author Rain Team
 * @notice Settable price source for tests, standing in for the Uniswap TWAP wrapper.
 */
contract MockPriceSource is IPriceSource {
    uint256 public price;
    bool public valid = true;

    constructor(uint256 price_) {
        price = price_;
    }

    function setPrice(uint256 price_) external {
        price = price_;
    }

    function setValid(bool valid_) external {
        valid = valid_;
    }

    function peek() external view returns (bytes32, bool) {
        return (bytes32(price), valid);
    }
}
