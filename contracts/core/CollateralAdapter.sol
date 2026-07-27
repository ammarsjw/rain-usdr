// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Auth } from "../extensions/Auth.sol";
import { ICollateralAdapter } from "../interfaces/ICollateralAdapter.sol";
import { IUSDR } from "../interfaces/IUSDR.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { RAY, WARD_ROLE } from "../shared/Constants.sol";
import { InvalidAmount, NotLive } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title CollateralAdapter.
 * @author Rain Team.
 * @notice The doorway for tokens entering and leaving the system. Bridges real tokens (RAIN,
 *         USDT, USDC — and USDR itself) and the internal ledger. One adapter instance per token:
 *         collateral instances take custody of deposits, while the single USDR instance mints and
 *         burns the token.
 * @dev Merges MakerDAO's GemJoin and DaiJoin into one contract, selected per instance by the
 *      immutable {isUsdrAdapter} flag. Collateral instances convert token decimals (USDT/USDC use
 *      6, RAIN uses 18) to the internal 18 decimal representation and update the ledger through
 *      `slip`; the USDR instance moves internal balances (45 decimals) through `move` and
 *      mints/burns the ERC-20. Merging is safe because USDR mint authority is granted
 *      per-instance on the token itself — collateral instances are never granted it, so the
 *      shared code path cannot leak mint rights.
 */
contract CollateralAdapter is ICollateralAdapter, Auth {
    using SafeERC20 for IERC20Metadata;

    /* ========================== STATE VARIABLES ========================== */

    /// @notice The Vault Engine (core ledger).
    IVaultEngine public immutable vaultEngine;

    /// @notice Identifier of the collateral type this adapter serves. Zero for the USDR instance.
    bytes32 public immutable ilkId;

    /// @notice The token this adapter bridges — held in custody, or minted/burned for USDR.
    IERC20Metadata public immutable token;

    /// @notice Decimals of the token.
    uint256 public immutable dec;

    /// @notice Whether this instance is the USDR adapter (`true`) or a collateral adapter.
    bool public immutable isUsdrAdapter;

    /// @notice Adapter liveness flag. `1` while live, `0` after shutdown.
    uint256 public live;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the adapter and marks it live.
     * @param vaultEngine_ Address of the Vault Engine.
     * @param ilkId_ Identifier of the collateral type. Pass zero for the USDR instance.
     * @param token_ Address of the token this adapter bridges.
     * @param isUsdrAdapter_ Whether this instance is the USDR adapter.
     */
    constructor(IVaultEngine vaultEngine_, bytes32 ilkId_, IERC20Metadata token_, bool isUsdrAdapter_) {
        vaultEngine = vaultEngine_;
        ilkId = ilkId_;
        token = token_;
        dec = token_.decimals();
        isUsdrAdapter = isUsdrAdapter_;
        live = 1;
    }

    /* ========================== ADMINISTRATION ========================== */

    /**
     * @inheritdoc ICollateralAdapter
     */
    function cage() external onlyRole(WARD_ROLE) {
        live = 0;

        emit Cage();
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc ICollateralAdapter
     */
    function join(address user, uint256 amount) external {
        if (isUsdrAdapter) {
            // Returning USDR into the system keeps working after shutdown.
            vaultEngine.move(address(this), user, RAY * amount);
            IUSDR(address(token)).burn(msg.sender, amount);
        } else {
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
            token.safeTransferFrom(msg.sender, address(this), amount);
        }

        emit Join({ user: user, amount: amount });
    }

    /**
     * @inheritdoc ICollateralAdapter
     */
    function exit(address user, uint256 amount) external {
        if (isUsdrAdapter) {
            // Minting is blocked after shutdown; returning USDR continues to work.
            if (live != 1) {
                _revert(NotLive.selector);
            }

            vaultEngine.move(msg.sender, address(this), RAY * amount);
            IUSDR(address(token)).mint(user, amount);
        } else {
            // Converting token decimals to the internal 18 decimal representation.
            uint256 wad = amount * (10 ** (18 - dec));

            if (wad > uint256(type(int256).max)) {
                _revert(InvalidAmount.selector);
            }

            vaultEngine.slip(ilkId, msg.sender, -int256(wad));
            token.safeTransfer(user, amount);
        }

        emit Exit({ user: user, amount: amount });
    }
}
