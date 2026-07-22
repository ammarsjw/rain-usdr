// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IPriceCurve } from "../interfaces/IPriceCurve.sol";
import { NotAuthorized, UnrecognizedParameter } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title PriceCurve.
 * @author Rain Team.
 * @notice A pure calculator. Given an auction's starting price, its start time, and how long it
 *         should run, it returns the current price at any moment. USDR uses a straight-line
 *         decline: the price falls steadily from the start to zero over the auction's lifetime.
 * @dev Based on MakerDAO's LinearDecrease Abacus.
 */
contract PriceCurve is IPriceCurve {
    /* ========================== STATE VARIABLES ========================== */

    /// @notice Authorized accounts. `wards[account] == 1` grants authorization.
    mapping(address account => uint256 authorization) public wards;

    /// @notice Auction lifetime in seconds — how long until the price reaches zero.
    uint256 public tau;

    /* ========================== MODIFIERS ========================== */

    /// @dev Restricts a function to authorized accounts.
    modifier auth() {
        if (wards[msg.sender] != 1) {
            _revert(NotAuthorized.selector);
        }
        _;
    }

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Authorizes the deployer.
     */
    constructor() {
        wards[msg.sender] = 1;

        emit Rely({ account: msg.sender });
    }

    /* ========================== ADMINISTRATION ========================== */

    /**
     * @inheritdoc IPriceCurve
     */
    function rely(address account) external auth {
        wards[account] = 1;

        emit Rely({ account: account });
    }

    /**
     * @inheritdoc IPriceCurve
     */
    function deny(address account) external auth {
        wards[account] = 0;

        emit Deny({ account: account });
    }

    /**
     * @inheritdoc IPriceCurve
     */
    function file(bytes32 what, uint256 data) external auth {
        if (what == "tau") {
            tau = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, data: data });
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IPriceCurve
     */
    function price(uint256 top, uint256 dur) external view returns (uint256) {
        // Past the lifetime, the price is zero — never negative.
        if (dur >= tau) {
            return 0;
        }

        // Current price = starting price * (1 - time elapsed / lifetime).
        return (top * (tau - dur)) / tau;
    }
}
