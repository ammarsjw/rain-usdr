// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

import { IUSDR } from "../interfaces/IUSDR.sol";
import { _BURNER_ROLE, _WARD_ROLE } from "../shared/Constants.sol";
import { InvalidAmount } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title USDR
 * @author Rain Team
 * @notice The Rain Dollar stablecoin. A standard, transferable digital dollar that can only be minted or
 *         burned by authorized system contracts (the Vault Engine adapter and the Peg Stability Module). No
 *         administrator can create USDR out of nothing.
 * @dev Minter authorization is governed by the `_WARD_ROLE` of the shared AccessControl base. Burning from an
 *      arbitrary address without an allowance requires the dedicated `_BURNER_ROLE`, held only by the
 *      Collateral Adapter; `_WARD_ROLE` administers roles but does not itself carry burn power.
 */
contract USDR is IUSDR, ERC20, ERC20Permit, AccessControl {
    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the token and authorizes the deployer, which grants authorization to the Vault
     *         Engine adapter and the Peg Stability Module during deployment.
     */
    constructor() ERC20("Rain Dollar", "USDR") ERC20Permit("Rain Dollar") {
        _setRoleAdmin(_BURNER_ROLE, _WARD_ROLE);
        _setRoleAdmin(_WARD_ROLE, _WARD_ROLE);

        _grantRole(_WARD_ROLE, msg.sender);
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IUSDR
     */
    function mint(address to, uint256 amount) external onlyRole(_WARD_ROLE) {
        if (amount == 0) {
            _revert(InvalidAmount.selector);
        }

        _mint(to, amount);
    }

    /**
     * @inheritdoc IUSDR
     */
    function burn(address from, uint256 amount) external {
        // Zero-amount burns are rejected rather than emitting no-op Transfer events that pollute indexers.
        if (amount == 0) {
            _revert(InvalidAmount.selector);
        }

        if (from != msg.sender && !hasRole(_BURNER_ROLE, msg.sender)) {
            _spendAllowance(from, msg.sender, amount);
        }

        _burn(from, amount);
    }
}
