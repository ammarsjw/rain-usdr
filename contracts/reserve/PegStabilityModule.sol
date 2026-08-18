// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { ICollateralAdapter } from "../interfaces/ICollateralAdapter.sol";
import { IGovernor } from "../interfaces/IGovernor.sol";
import { IPegStabilityModule } from "../interfaces/IPegStabilityModule.sol";
import { IReserveAccounting } from "../interfaces/IReserveAccounting.sol";
import { ISolvencyEngine } from "../interfaces/ISolvencyEngine.sol";
import { IUSDR } from "../interfaces/IUSDR.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { _USDR_ILK, _WARD_ROLE } from "../shared/Constants.sol";
import { IlkAlreadyInitialized, InvalidAddress, InvalidAmount, SolvencyGateActive, SystemPaused, UnrecognizedParameter } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title PegStabilityModule
 * @author Rain Team
 * @notice The on-ramp and off-ramp for stablecoins. Deposit USDT or USDC, get USDR one-for-one. Return USDR, get
 *         stablecoins back, but redemption is best-effort, served only from the protocol's free reserves after
 *         guaranteed obligations are covered. A single deployed instance serves every stablecoin, and ilks are
 *         registered dynamically. Conversions are exactly 1:1 in both directions: the protocol charges no fee.
 * @dev Uses a shared-reserve model with a single ilk-keyed module riding the equally singular Collateral Adapter.
 *      USDR's reserve is shared, so guaranteed obligations always take priority and redemption reverts when free
 *      slack is too low. This keeps the protocol from promising the same dollar twice.
 */
contract PegStabilityModule is IPegStabilityModule, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20Metadata;

    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc IPegStabilityModule
    ICollateralAdapter public immutable COLLATERAL_ADAPTER;

    /// @inheritdoc IPegStabilityModule
    IReserveAccounting public immutable RESERVE_ACCOUNTING;

    /// @inheritdoc IPegStabilityModule
    IVaultEngine public immutable VAULT_ENGINE;

    /// @inheritdoc IPegStabilityModule
    IUSDR public immutable USDR;

    /// @inheritdoc IPegStabilityModule
    address public solvencyEngine;

    /// @inheritdoc IPegStabilityModule
    address public governor;

    /// @inheritdoc IPegStabilityModule
    mapping(bytes32 ilkId => Ilk ilk) public ilks;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the module and grants the Vault Engine unlimited USDR movement rights.
     * @param collateralAdapter_ Address of the token adapter.
     * @param reserveAccounting_ Address of the reserve accounting contract.
     */
    constructor(ICollateralAdapter collateralAdapter_, IReserveAccounting reserveAccounting_) {
        if (address(collateralAdapter_) == address(0) || address(reserveAccounting_) == address(0)) {
            _revert(InvalidAddress.selector);
        }

        _setRoleAdmin(_WARD_ROLE, _WARD_ROLE);

        _grantRole(_WARD_ROLE, msg.sender);

        COLLATERAL_ADAPTER = collateralAdapter_;
        RESERVE_ACCOUNTING = reserveAccounting_;
        VAULT_ENGINE = IVaultEngine(address(collateralAdapter_.VAULT_ENGINE()));

        (IERC20Metadata usdrToken, , , ) = collateralAdapter_.ilks(_USDR_ILK);

        if (address(usdrToken) == address(0)) {
            _revert(InvalidAddress.selector);
        }

        USDR = IUSDR(address(usdrToken));

        VAULT_ENGINE.hope(address(collateralAdapter_));
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IPegStabilityModule
     */
    function init(bytes32 ilkId) external onlyRole(_WARD_ROLE) {
        if (address(ilks[ilkId].token) != address(0)) {
            _revert(IlkAlreadyInitialized.selector);
        }

        // The ilk must already be registered with the adapter.
        (IERC20Metadata token, uint8 dec, bool isUsdr, ) = COLLATERAL_ADAPTER.ilks(ilkId);

        if (address(token) == address(0) || isUsdr) {
            _revert(InvalidAddress.selector);
        }

        // The PSM holds its entire stable inventory for this ilk in a single dedicated vault, opened here. The ilk
        // must therefore already be initialized in the Vault Engine.
        uint256 vaultId = VAULT_ENGINE.open(ilkId, address(this));

        ilks[ilkId] = Ilk({ token: token, to18ConversionFactor: 10 ** (18 - dec), vaultId: vaultId });

        emit Init({ ilkId: ilkId, token: address(token) });
    }

    /**
     * @inheritdoc IPegStabilityModule
     */
    function file(bytes32 what, address data) external onlyRole(_WARD_ROLE) {
        if (what == "solvencyEngine") {
            solvencyEngine = data;
        } else if (what == "governor") {
            governor = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, addr: data });
    }

    /**
     * @inheritdoc IPegStabilityModule
     */
    function sellStable(bytes32 ilkId, address user, uint256 stableAmt) external nonReentrant {
        Ilk storage ilk = ilks[ilkId];

        if (address(ilk.token) == address(0)) {
            _revert(InvalidAddress.selector);
        }

        if (stableAmt == 0) {
            _revert(InvalidAmount.selector);
        }

        // Emergency pause check (full stop). Note that this is never gated by the solvency engine: selling stables
        // INCREASES the reserve, so it remains available during a solvency breach.
        if (governor != address(0) && IGovernor(governor).paused()) {
            _revert(SystemPaused.selector);
        }

        // Exactly 1:1: the user receives stableAmt18 USDR for stableAmt stablecoins. No fee.
        uint256 stableAmt18 = stableAmt * ilk.to18ConversionFactor;

        // Moving the stablecoins into the protocol's stable reserve. The ceiling check happens inside the Vault
        // Engine's frob.
        ilk.token.safeTransferFrom(msg.sender, address(this), stableAmt);
        ilk.token.forceApprove(address(COLLATERAL_ADAPTER), stableAmt);

        COLLATERAL_ADAPTER.join(ilkId, address(this), stableAmt);
        VAULT_ENGINE.frob(ilk.vaultId, address(this), address(this), int256(stableAmt18), int256(stableAmt18));
        COLLATERAL_ADAPTER.exit(_USDR_ILK, user, stableAmt18);

        // Registering the reserve increase, exactly the amount that entered.
        RESERVE_ACCOUNTING.recordIncrease(stableAmt18);

        emit SellStable({ ilkId: ilkId, user: user, stableAmt: stableAmt, usdrAmt: stableAmt18 });
    }

    /**
     * @inheritdoc IPegStabilityModule
     */
    function buyStable(bytes32 ilkId, address user, uint256 stableAmt) external nonReentrant {
        Ilk storage ilk = ilks[ilkId];

        if (address(ilk.token) == address(0)) {
            _revert(InvalidAddress.selector);
        }

        if (stableAmt == 0) {
            _revert(InvalidAmount.selector);
        }

        // Emergency pause check (full stop).
        if (governor != address(0) && IGovernor(governor).paused()) {
            _revert(SystemPaused.selector);
        }

        // Solvency gate: redemption DECREASES the reserve, so it is blocked while the invariant is breached.
        if (solvencyEngine != address(0) && ISolvencyEngine(solvencyEngine).isBreached()) {
            _revert(SolvencyGateActive.selector);
        }

        // Exactly 1:1: the user pays stableAmt18 USDR for stableAmt stablecoins. No fee.
        uint256 stableAmt18 = stableAmt * ilk.to18ConversionFactor;

        // Free-slack check: redemption is best-effort, served only from the reserve minus the amount committed to
        // guaranteed obligations. If free slack is too low, revert so the user must use the open market instead.
        if (stableAmt18 > RESERVE_ACCOUNTING.freeSlack()) {
            _revert(InsufficientFreeSlack.selector);
        }

        IERC20(address(USDR)).safeTransferFrom(msg.sender, address(this), stableAmt18);
        COLLATERAL_ADAPTER.join(_USDR_ILK, address(this), stableAmt18);
        VAULT_ENGINE.frob(ilk.vaultId, address(this), address(this), -int256(stableAmt18), -int256(stableAmt18));
        COLLATERAL_ADAPTER.exit(ilkId, user, stableAmt);

        // Registering the reserve decrease, exactly the amount that left.
        RESERVE_ACCOUNTING.recordDecrease(stableAmt18);

        emit BuyStable({ ilkId: ilkId, user: user, stableAmt: stableAmt, usdrAmt: stableAmt18 });
    }
}
