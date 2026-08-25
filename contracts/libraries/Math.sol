// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { _RAY } from "../shared/Constants.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title Math
 * @author Rain Team
 * @notice Library containing generic math helpers for mixed signed and unsigned arithmetic. Helpers that already exist
 *         in OpenZeppelin's `Math` library, for example `min` and `max` for unsigned integers, are intentionally not
 *         duplicated here. Consumers should import them from OpenZeppelin directly.
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
        // The unsigned operand must fit the signed range BEFORE the cast is used in arithmetic: validating after
        // multiplying would compute with an already-corrupted (negative) operand.
        if (x > uint256(type(int256).max)) {
            _revert(MulOverflow.selector);
        }

        unchecked {
            z = int256(x) * y;
        }

        if (y != 0 && z / y != int256(x)) {
            _revert(MulOverflow.selector);
        }
    }

    /**
     * @dev Multiplies two unsigned integers, reverting with a decodable error (rather than an arithmetic panic) on
     *      overflow. Used in ledger hot paths where reachable products may exceed 256 bits.
     * @param x First operand.
     * @param y Second operand.
     * @return z The product `x * y`.
     */
    function umul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        unchecked {
            z = x * y;
        }

        if (y != 0 && z / y != x) {
            _revert(MulOverflow.selector);
        }
    }

    /**
     * @dev Multiplies two ray fixed-point numbers, truncating: `(x * y) / RAY`. Reverts with a decodable error on
     *      overflow of the intermediate product.
     * @param x First operand [ray].
     * @param y Second operand [ray].
     * @return z The ray product `x * y / RAY` [ray].
     */
    function rmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = umul(x, y) / _RAY;
    }

    /**
     * @dev Fixed-point exponentiation by squaring: computes `x ** n` where `x` is a fixed-point number scaled by
     *      `base`. Used to compound a per-second `duty` factor over the
     *      elapsed time in {VaultEngine.drip}. Reverts (via the invalid opcode inside the assembly block) on
     *      overflow.
     * @param x Fixed-point base scaled by `base` (e.g. a per-second rate factor in ray).
     * @param n Exponent (e.g. elapsed seconds).
     * @param base Fixed-point scalar (e.g. RAY).
     * @return z The fixed-point power `x ** n` scaled by `base`.
     */
    function rpow(uint256 x, uint256 n, uint256 base) internal pure returns (uint256 z) {
        assembly ("memory-safe") {
            switch x
            case 0 {
                switch n
                case 0 {
                    z := base
                }
                default {
                    z := 0
                }
            }
            default {
                switch mod(n, 2)
                case 0 {
                    z := base
                }
                default {
                    z := x
                }
                let half := div(base, 2) // for rounding.
                for {
                    n := div(n, 2)
                } n {
                    n := div(n, 2)
                } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) {
                        revert(0, 0)
                    }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) {
                        revert(0, 0)
                    }
                    x := div(xxRound, base)
                    if mod(n, 2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) {
                            revert(0, 0)
                        }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) {
                            revert(0, 0)
                        }
                        z := div(zxRound, base)
                    }
                }
            }
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
