// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

import { _WARD_ROLE } from "../shared/Constants.sol";
import { Deny, Rely } from "../shared/Events.sol";

/**
 * @title Auth
 * @author Rain Team
 * @notice Shared authorization base built on OpenZeppelin AccessControl. Every system contract that needs privileged
 *         access inherits this instead of hand-rolling the authorization mapping.
 * @dev Replaces MakerDAO's `wards` mapping with the `_WARD_ROLE` role, while preserving the familiar `rely`/`deny`
 *      ergonomics as thin wrappers over AccessControl. The ward role administers itself, so any ward may grant or
 *      revoke the role — mirroring the original behaviour where any authorized account could `rely`/`deny` another.
 */
abstract contract Auth is AccessControl {
    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Grants the deployer the ward role and makes the role self-administered.
     * @dev Runs automatically for every inheriting contract, so no explicit initializer call is needed in derived
     *      constructors.
     */
    constructor() {
        _initAuth();
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Grants ward authorization to an account.
     * @param account Address to authorize.
     */
    function rely(address account) external onlyRole(_WARD_ROLE) {
        _grantRole(_WARD_ROLE, account);

        emit Rely({ account: account });
    }

    /**
     * @notice Revokes ward authorization from an account.
     * @param account Address to deauthorize.
     */
    function deny(address account) external onlyRole(_WARD_ROLE) {
        _revokeRole(_WARD_ROLE, account);

        emit Deny({ account: account });
    }

    /**
     * @dev Performs the authorization setup and emits the corresponding event. Kept `private` and called from the
     *      constructor so that event emission never happens directly inside a constructor body.
     */
    function _initAuth() private {
        _setRoleAdmin(_WARD_ROLE, _WARD_ROLE);
        _grantRole(_WARD_ROLE, msg.sender);

        emit Rely({ account: msg.sender });
    }
}
