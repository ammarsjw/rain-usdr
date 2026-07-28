// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IUSDR
 * @author Rain Team
 * @notice Interface for the Rain Dollar stablecoin.
 */
interface IUSDR is IERC20 {
    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Creates new USDR and gives it to a specified wallet.
     * @dev Only callable by an authorized minter. Reverts on zero address or zero amount.
     * @param to Wallet that receives the new USDR.
     * @param amount Amount of USDR to create.
     */
    function mint(address to, uint256 amount) external;

    /**
     * @notice Destroys USDR, removing it from circulation.
     * @dev Callable by the token owner, an authorized minter, or a spender with allowance.
     * @param from Wallet whose USDR is destroyed.
     * @param amount Amount of USDR to destroy.
     */
    function burn(address from, uint256 amount) external;
}
