// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { Auth } from "../extensions/Auth.sol";
import { IBalanceSheet } from "../interfaces/IBalanceSheet.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { _WARD_ROLE } from "../shared/Constants.sol";
import { UnrecognizedParameter } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title BalanceSheet
 * @author Rain Team
 * @notice The protocol's treasury and debt manager. Receives revenue as surplus, holds a safety
 *         buffer, and absorbs bad debt through an ordered waterfall. When the surplus buffer is
 *         full, the excess goes toward buying back and burning RAIN.
 * @dev Based on MakerDAO's Vow, without surplus/debt auctions: USDR uses a RAIN buyback-and-burn
 *      for surplus and a controlled backstop for bad debt instead. The strict "fill before burn"
 *      rule is enforced in `distributeSurplus`.
 */
contract BalanceSheet is IBalanceSheet, Auth {
    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc IBalanceSheet
    IVaultEngine public immutable VAULT_ENGINE;

    /// @inheritdoc IBalanceSheet
    address public buybackReceiver;

    /// @inheritdoc IBalanceSheet
    uint256 public hump;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the balance sheet.
     * @param vaultEngine_ Address of the Vault Engine.
     */
    constructor(IVaultEngine vaultEngine_) {
        VAULT_ENGINE = vaultEngine_;
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IBalanceSheet
     */
    function file(bytes32 what, uint256 data) external onlyRole(_WARD_ROLE) {
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
    function file(bytes32 what, address data) external onlyRole(_WARD_ROLE) {
        if (what == "buybackReceiver") {
            buybackReceiver = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, addr: data });
    }

    /**
     * @inheritdoc IBalanceSheet
     */
    function fess(uint256 tab) external onlyRole(_WARD_ROLE) {
        emit Fess({ tab: tab });
    }

    /**
     * @inheritdoc IBalanceSheet
     */
    function heal(uint256 rad) external {
        require(rad <= VAULT_ENGINE.usdr(address(this)), "BalanceSheet/insufficient-surplus");
        require(rad <= VAULT_ENGINE.sin(address(this)), "BalanceSheet/insufficient-debt");

        VAULT_ENGINE.heal(rad);

        emit Heal({ rad: rad });
    }

    /**
     * @inheritdoc IBalanceSheet
     */
    function suck(address kpr, uint256 rad) external onlyRole(_WARD_ROLE) {
        // Creating the reward as a small piece of bad debt, to be covered later from surplus.
        VAULT_ENGINE.suck(address(this), kpr, rad);

        emit Suck({ kpr: kpr, rad: rad });
    }

    /**
     * @inheritdoc IBalanceSheet
     */
    function distributeSurplus() external returns (uint256 excess) {
        uint256 surplus = VAULT_ENGINE.usdr(address(this));
        uint256 badDebt = VAULT_ENGINE.sin(address(this));

        // Bad debt is always absorbed before any distribution.
        require(badDebt == 0, "BalanceSheet/outstanding-bad-debt");

        // The strict "fill before burn" rule: the surplus buffer must be at or above its target first. If the
        // buffer is below target, no distribution happens — all revenue stays.
        require(surplus > hump, "BalanceSheet/buffer-below-target");
        require(buybackReceiver != address(0), "BalanceSheet/no-buyback-receiver");

        // Only the amount above the buffer target is released to the RAIN buyback process.
        excess = surplus - hump;

        VAULT_ENGINE.move(address(this), buybackReceiver, excess);

        emit DistributeSurplus({ excess: excess });
    }
}
