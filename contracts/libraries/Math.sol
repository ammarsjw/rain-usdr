// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/**
 * @title Math
 * @author Rain Team
 * @notice Library containing generic math helpers for mixed signed and unsigned arithmetic. Helpers that already
 *         exist in OpenZeppelin's `Math` library (e.g. `min` and `max` for unsigned integers) are intentionally not
 *         duplicated here — consumers should import them from OpenZeppelin directly.
 */
library Math {
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
        require(y >= 0 || z <= x, "Math/add-underflow");
        require(y <= 0 || z >= x, "Math/add-overflow");
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
        require(y <= 0 || z <= x, "Math/sub-underflow");
        require(y >= 0 || z >= x, "Math/sub-overflow");
    }

    /**
     * @dev Multiplies an unsigned integer by a signed integer, reverting on overflow.
     * @param x Unsigned operand.
     * @param y Signed operand.
     * @return z The product `x * y` as a signed integer.
     */
    function mul(uint256 x, int256 y) internal pure returns (int256 z) {
        z = int256(x) * y;
        require(int256(x) >= 0, "Math/mul-overflow");
        require(y == 0 || z / y == int256(x), "Math/mul-overflow");
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
