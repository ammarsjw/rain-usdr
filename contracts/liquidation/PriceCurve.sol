// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IPriceCurve } from "../interfaces/IPriceCurve.sol";
import { Auth } from "../shared/Auth.sol";
import { WARD_ROLE } from "../shared/Constants.sol";
import { UnrecognizedParameter } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title PriceCurve.
 * @author Rain Team.
 * @notice A pure calculator. Given an auction's starting price, its start time, and how long it
 *         should run, it returns the current price at any moment. USDR uses a straight-line
 *         decline: the price falls steadily from the start to zero over the auction's lifetime.
 * @dev Based on MakerDAO's LinearDecrease Abacus.
 */
contract PriceCurve is IPriceCurve, Auth {
    /* ========================== STATE VARIABLES ========================== */

    /// @notice Auction lifetime in seconds — how long until the price reaches zero.
    uint256 public tau;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Authorizes the deployer.
     */
    constructor() {
        _initAuth();
    }

    /* ========================== ADMINISTRATION ========================== */

    /**
     * @inheritdoc IPriceCurve
     */
    function file(bytes32 what, uint256 data) external onlyRole(WARD_ROLE) {
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
