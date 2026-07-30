// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

import { IPriceCurve } from "../interfaces/IPriceCurve.sol";
import { _WARD_ROLE } from "../shared/Constants.sol";
import { UnrecognizedParameter } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title PriceCurve
 * @author Rain Team
 * @notice A pure calculator. Given an auction's starting price, its start time, and how long it
 *         should run, it returns the current price at any moment. USDR uses a straight-line
 *         decline: the price falls steadily from the start to zero over the auction's lifetime.
 * @dev Implements a linear decrease. The price falls in a straight line from the start value to zero over `tau`.
 */
contract PriceCurve is IPriceCurve, AccessControl {
    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc IPriceCurve
    uint256 public tau;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Authorizes the deployer.
     */
    constructor() {
        _setRoleAdmin(_WARD_ROLE, _WARD_ROLE);
        _grantRole(_WARD_ROLE, msg.sender);
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IPriceCurve
     */
    function file(bytes32 what, uint256 data) external onlyRole(_WARD_ROLE) {
        if (what == "tau") {
            tau = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, data: data });
    }

    /**
     * @inheritdoc IPriceCurve
     */
    function price(uint256 top, uint256 dur) external view returns (uint256) {
        // Past the lifetime, the price is zero and never negative.
        if (dur >= tau) {
            return 0;
        }

        // Current price = starting price * (1 - time elapsed / lifetime).
        return (top * (tau - dur)) / tau;
    }
}
