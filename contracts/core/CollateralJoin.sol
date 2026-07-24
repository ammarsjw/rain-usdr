// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ICollateralJoin } from "../interfaces/ICollateralJoin.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { AdapterBase } from "./AdapterBase.sol";
import { InvalidAmount, NotLive } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title CollateralJoin.
 * @author Rain Team.
 * @notice The doorway for tokens entering and leaving the system. Bridges real tokens (RAIN,
 *         USDT, USDC) and the internal ledger. One adapter per collateral type.
 * @dev Based on MakerDAO's collateral adapter. Converts token decimals (USDT/USDC use 6, RAIN
 *      uses 18) to the internal 18 decimal representation. Shares its authorization and liveness
 *      machinery with the USDR adapter through {AdapterBase}.
 */
contract CollateralJoin is ICollateralJoin, AdapterBase {
    using SafeERC20 for IERC20Metadata;

    /* ========================== STATE VARIABLES ========================== */

    /// @notice The Vault Engine (core ledger).
    IVaultEngine public immutable vaultEngine;

    /// @notice Identifier of the collateral type this adapter serves.
    bytes32 public immutable ilkId;

    /// @notice The collateral token held in custody.
    IERC20Metadata public immutable collateralToken;

    /// @notice Decimals of the collateral token.
    uint256 public immutable dec;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the adapter and marks it live.
     * @param vaultEngine_ Address of the Vault Engine.
     * @param ilkId_ Identifier of the collateral type.
     * @param collateralToken_ Address of the collateral token.
     */
    constructor(IVaultEngine vaultEngine_, bytes32 ilkId_, IERC20Metadata collateralToken_) {
        vaultEngine = vaultEngine_;
        ilkId = ilkId_;
        collateralToken = collateralToken_;
        dec = collateralToken_.decimals();

        _initAdapter();
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc ICollateralJoin
     */
    function join(address user, uint256 amount) external {
        // Deposits are blocked after shutdown; withdrawals continue to work.
        if (live != 1) {
            _revert(NotLive.selector);
        }

        // Converting token decimals to the internal 18 decimal representation.
        uint256 wad = amount * (10 ** (18 - dec));

        if (int256(wad) < 0) {
            _revert(InvalidAmount.selector);
        }

        vaultEngine.slip(ilkId, user, int256(wad));
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Join({ user: user, amount: amount });
    }

    /**
     * @inheritdoc ICollateralJoin
     */
    function exit(address user, uint256 amount) external {
        // Converting token decimals to the internal 18 decimal representation.
        uint256 wad = amount * (10 ** (18 - dec));

        if (wad > uint256(type(int256).max)) {
            _revert(InvalidAmount.selector);
        }

        vaultEngine.slip(ilkId, msg.sender, -int256(wad));
        collateralToken.safeTransfer(user, amount);

        emit Exit({ user: user, amount: amount });
    }
}
