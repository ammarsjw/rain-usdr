// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { Auth } from "../shared/Auth.sol";
import { WARD_ROLE } from "../shared/Constants.sol";

/**
 * @title AdapterBase.
 * @author Rain Team.
 * @notice Shared base for the token adapters (CollateralJoin and UsdrJoin). Holds the common
 *         authorization and liveness machinery so each adapter only has to implement its own
 *         token-specific join/exit conversion logic.
 * @dev Extracted rather than merging the two adapters into one contract: they operate on different
 *      ledger primitives (collateral `slip` versus USDR `move`) and only the USDR adapter may mint
 *      the token, so a single combined contract would leak mint authority to every collateral
 *      adapter. Sharing a base keeps the boilerplate in one place without collapsing that isolation.
 */
abstract contract AdapterBase is Auth {
    /* ========================== EVENTS ========================== */

    /// @notice Emitted when the adapter is shut down.
    event Cage();

    /* ========================== STATE VARIABLES ========================== */

    /// @notice Adapter liveness flag. `1` while live, `0` after shutdown.
    uint256 public live;

    /* ========================== INITIALIZER ========================== */

    /// @dev Sets up authorization and marks the adapter live. Called from inheriting constructors.
    function _initAdapter() internal {
        _initAuth();
        live = 1;
    }

    /* ========================== ADMINISTRATION ========================== */

    /**
     * @notice Shuts the adapter down. Each adapter defines what a shutdown blocks.
     */
    function cage() external onlyRole(WARD_ROLE) {
        live = 0;

        emit Cage();
    }
}
