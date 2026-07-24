// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

import { WARD_ROLE } from "./Constants.sol";

/**
 * @title Auth.
 * @author Rain Team.
 * @notice Shared authorization base built on OpenZeppelin AccessControl. Every system contract that
 *         needs privileged access inherits this instead of hand-rolling the authorization mapping.
 * @dev Replaces MakerDAO's `wards` mapping with the `WARD_ROLE` role, while preserving the familiar
 *      `rely`/`deny` ergonomics as thin wrappers over AccessControl. The ward role administers
 *      itself, so any ward may grant or revoke the role — mirroring the original behaviour where
 *      any authorized account could `rely`/`deny` another.
 */
abstract contract Auth is AccessControl {
    /* ========================== EVENTS ========================== */

    /// @notice Emitted when an account is granted authorization.
    event Rely(address indexed account);

    /// @notice Emitted when an account has its authorization revoked.
    event Deny(address indexed account);

    /* ========================== INITIALIZER ========================== */

    /**
     * @notice Grants the deployer the ward role and makes the role self-administered.
     * @dev Called from constructors so the authorization setup — and its event — lives in one place
     *      rather than being inlined into every constructor. Must be `internal` (not `private`) so
     *      inheriting constructors can call it.
     */
    function _initAuth() internal {
        _setRoleAdmin(WARD_ROLE, WARD_ROLE);
        _grantRole(WARD_ROLE, msg.sender);

        emit Rely({ account: msg.sender });
    }

    /* ========================== AUTHORIZATION ========================== */

    /**
     * @notice Grants ward authorization to an account.
     * @param account Address to authorize.
     */
    function rely(address account) external onlyRole(WARD_ROLE) {
        _grantRole(WARD_ROLE, account);

        emit Rely({ account: account });
    }

    /**
     * @notice Revokes ward authorization from an account.
     * @param account Address to deauthorize.
     */
    function deny(address account) external onlyRole(WARD_ROLE) {
        _revokeRole(WARD_ROLE, account);

        emit Deny({ account: account });
    }
}
