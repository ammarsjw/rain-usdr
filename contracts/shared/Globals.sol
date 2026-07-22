// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

/* ========================== FREE FUNCTIONS ========================== */

/**
 * @dev For more efficient reverts.
 */
function _revert(bytes4 errorSelector) pure {
    assembly ("memory-safe") {
        mstore(0x00, errorSelector)
        revert(0x00, 0x04)
    }
}
