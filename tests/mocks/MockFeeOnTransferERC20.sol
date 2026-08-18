// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockFeeOnTransferERC20
 * @author Rain Team
 * @notice ERC-20 that skims a configurable fee on every transfer, for adapter shortfall tests.
 */
contract MockFeeOnTransferERC20 is ERC20 {
    uint8 private immutable _decimals;

    /// @dev Fee in basis points taken from every transfer.
    uint256 public feeBps;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 feeBps_) ERC20(name_, symbol_) {
        _decimals = decimals_;
        feeBps = feeBps_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        // Burning the fee on real transfers only (mints and burns pass through untouched).
        if (from != address(0) && to != address(0) && feeBps != 0) {
            uint256 fee = (value * feeBps) / 10_000;

            super._update(from, address(0), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}
