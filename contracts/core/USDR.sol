// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

import { IUSDR } from "../interfaces/IUSDR.sol";
import { InvalidAddress, InvalidAmount, NotAuthorized } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title USDR.
 * @author Rain Team.
 * @notice The Rain Dollar stablecoin. A standard, transferable digital dollar that can only be
 *         minted or burned by authorized system contracts (the Vault Engine adapter and the
 *         Peg Stability Module). No administrator can create USDR out of nothing.
 * @dev Based on MakerDAO's Dai token. Uses the `rely`/`deny` wards pattern for minter authorization.
 */
contract USDR is IUSDR, ERC20, ERC20Permit {
    /* ========================== STATE VARIABLES ========================== */

    /// @notice Authorized minters. `wards[account] == 1` grants mint and burn rights.
    mapping(address account => uint256 authorization) public wards;

    /* ========================== MODIFIERS ========================== */

    /// @dev Restricts a function to authorized minters.
    modifier auth() {
        if (wards[msg.sender] != 1) {
            _revert(NotAuthorized.selector);
        }
        _;
    }

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the token and authorizes the deployer, which transfers authorization
     *         to the Vault Engine adapter and the Peg Stability Module during deployment.
     */
    constructor() ERC20("Rain Dollar", "USDR") ERC20Permit("Rain Dollar") {
        wards[msg.sender] = 1;

        emit Rely({ account: msg.sender });
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IUSDR
     */
    function rely(address account) external auth {
        if (account == address(0)) {
            _revert(InvalidAddress.selector);
        }

        wards[account] = 1;

        emit Rely({ account: account });
    }

    /**
     * @inheritdoc IUSDR
     */
    function deny(address account) external auth {
        wards[account] = 0;

        emit Deny({ account: account });
    }

    /**
     * @inheritdoc IUSDR
     */
    function mint(address to, uint256 amount) external auth {
        if (to == address(0)) {
            _revert(InvalidAddress.selector);
        }
        if (amount == 0) {
            _revert(InvalidAmount.selector);
        }

        _mint(to, amount);
    }

    /**
     * @inheritdoc IUSDR
     */
    function burn(address from, uint256 amount) external {
        if (from != msg.sender && wards[msg.sender] != 1) {
            _spendAllowance(from, msg.sender, amount);
        }

        _burn(from, amount);
    }
}
