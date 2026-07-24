// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IBalanceSheet } from "../interfaces/IBalanceSheet.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { Auth } from "../shared/Auth.sol";
import { WARD_ROLE } from "../shared/Constants.sol";
import { UnrecognizedParameter } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title BalanceSheet.
 * @author Rain Team.
 * @notice The protocol's treasury and debt manager. Receives revenue as surplus, holds a safety
 *         buffer, and absorbs bad debt through an ordered waterfall. When the surplus buffer is
 *         full, the excess goes toward buying back and burning RAIN.
 * @dev Based on MakerDAO's Vow, without surplus/debt auctions: USDR uses a RAIN buyback-and-burn
 *      for surplus and a controlled backstop for bad debt instead. The strict "fill before burn"
 *      rule is enforced in `distributeSurplus`.
 */
contract BalanceSheet is IBalanceSheet, Auth {
    /* ========================== STATE VARIABLES ========================== */

    /// @notice The Vault Engine (core ledger).
    IVaultEngine public immutable vaultEngine;

    /// @notice Recipient of surplus distributions (the RAIN buyback-and-burn process).
    address public buybackReceiver;

    /// @notice The surplus buffer target [rad]. 10% of reserves with a $500,000 floor at launch.
    uint256 public hump;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the balance sheet.
     * @param vaultEngine_ Address of the Vault Engine.
     */
    constructor(IVaultEngine vaultEngine_) {
        vaultEngine = vaultEngine_;

        _initAuth();
    }

    /* ========================== ADMINISTRATION ========================== */

    /**
     * @inheritdoc IBalanceSheet
     */
    function file(bytes32 what, uint256 data) external onlyRole(WARD_ROLE) {
        if (what == "hump") {
            hump = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, data: data });
    }

    /**
     * @inheritdoc IBalanceSheet
     */
    function file(bytes32 what, address data) external onlyRole(WARD_ROLE) {
        if (what == "buybackReceiver") {
            buybackReceiver = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, addr: data });
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IBalanceSheet
     */
    function fess(uint256 tab) external onlyRole(WARD_ROLE) {
        emit Fess({ tab: tab });
    }

    /**
     * @inheritdoc IBalanceSheet
     */
    function heal(uint256 rad) external {
        require(rad <= vaultEngine.usdr(address(this)), "BalanceSheet/insufficient-surplus");
        require(rad <= vaultEngine.sin(address(this)), "BalanceSheet/insufficient-debt");

        vaultEngine.heal(rad);

        emit Heal({ rad: rad });
    }

    /**
     * @inheritdoc IBalanceSheet
     */
    function suck(address kpr, uint256 rad) external onlyRole(WARD_ROLE) {
        // Creating the reward as a small piece of bad debt, to be covered later from surplus.
        vaultEngine.suck(address(this), kpr, rad);

        emit Suck({ kpr: kpr, rad: rad });
    }

    /**
     * @inheritdoc IBalanceSheet
     */
    function distributeSurplus() external returns (uint256 excess) {
        uint256 surplus = vaultEngine.usdr(address(this));
        uint256 badDebt = vaultEngine.sin(address(this));

        // Bad debt is always absorbed before any distribution.
        require(badDebt == 0, "BalanceSheet/outstanding-bad-debt");

        // The strict "fill before burn" rule: the surplus buffer must be at or above its target
        // first. If the buffer is below target, no distribution happens — all revenue stays.
        require(surplus > hump, "BalanceSheet/buffer-below-target");
        require(buybackReceiver != address(0), "BalanceSheet/no-buyback-receiver");

        // Only the amount above the buffer target is released to the RAIN buyback process.
        excess = surplus - hump;

        vaultEngine.move(address(this), buybackReceiver, excess);

        emit DistributeSurplus({ excess: excess });
    }
}
