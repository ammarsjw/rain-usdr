// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { _revert } from "../shared/Globals.sol";

/**
 * @title Math
 * @author Rain Team
 * @notice Library containing generic math helpers for mixed signed and unsigned arithmetic. Helpers that already
 *         exist in OpenZeppelin's `Math` library, for example `min` and `max` for unsigned integers, are
 *         intentionally not duplicated here. Consumers should import them from OpenZeppelin directly.
 */
library Math {
    /* ========================== ERRORS ========================== */

    /**
     * @dev Indicates an overflow during signed and unsigned addition.
     */
    error AddOverflow();

    /**
     * @dev Indicates an underflow during signed and unsigned addition.
     */
    error AddUnderflow();

    /**
     * @dev Indicates an overflow during signed and unsigned subtraction.
     */
    error SubOverflow();

    /**
     * @dev Indicates an underflow during signed and unsigned subtraction.
     */
    error SubUnderflow();

    /**
     * @dev Indicates an overflow during signed and unsigned multiplication.
     */
    error MulOverflow();

    /* ========================== FUNCTIONS ========================== */

    /**
     * @dev Adds a signed integer to an unsigned integer, reverting on over/underflow.
     * @param x Unsigned operand.
     * @param y Signed operand.
     * @return z The sum `x + y` as an unsigned integer.
     */
    function add(uint256 x, int256 y) internal pure returns (uint256 z) {
        unchecked {
            z = x + uint256(y);
        }
        if (y < 0 && z > x) {
            _revert(AddUnderflow.selector);
        }
        if (y > 0 && z < x) {
            _revert(AddOverflow.selector);
        }
    }

    /**
     * @dev Subtracts a signed integer from an unsigned integer, reverting on over/underflow.
     * @param x Unsigned operand.
     * @param y Signed operand.
     * @return z The difference `x - y` as an unsigned integer.
     */
    function sub(uint256 x, int256 y) internal pure returns (uint256 z) {
        unchecked {
            z = x - uint256(y);
        }
        if (y > 0 && z > x) {
            _revert(SubUnderflow.selector);
        }
        if (y < 0 && z < x) {
            _revert(SubOverflow.selector);
        }
    }

    /**
     * @dev Multiplies an unsigned integer by a signed integer, reverting on overflow.
     * @param x Unsigned operand.
     * @param y Signed operand.
     * @return z The product `x * y` as a signed integer.
     */
    function mul(uint256 x, int256 y) internal pure returns (int256 z) {
        z = int256(x) * y;
        if (int256(x) < 0) {
            _revert(MulOverflow.selector);
        }
        if (y != 0 && z / y != int256(x)) {
            _revert(MulOverflow.selector);
        }
    }

    /**
     * @dev Logical AND without short-circuit branching.
     * @param x First operand.
     * @param y Second operand.
     * @return z Whether both operands are true.
     */
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly ("memory-safe") {
            z := and(x, y)
        }
    }
}
