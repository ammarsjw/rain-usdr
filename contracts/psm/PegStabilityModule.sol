// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

import { ICollateralAdapter } from "../interfaces/ICollateralAdapter.sol";
import { IPegStabilityModule } from "../interfaces/IPegStabilityModule.sol";
import { IReserveAccounting } from "../interfaces/IReserveAccounting.sol";
import { IUSDR } from "../interfaces/IUSDR.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { _USDR_ILK, _WAD, _WARD_ROLE } from "../shared/Constants.sol";
import { InvalidAddress, InvalidAmount, UnrecognizedParameter } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title PegStabilityModule
 * @author Rain Team
 * @notice The on-ramp and off-ramp for stablecoins. Deposit USDT or USDC, get USDR one-for-one. Return USDR, get
 *         stablecoins back, but redemption is best-effort, served only from the protocol's free reserves after
 *         guaranteed obligations are covered. A single deployed instance serves every stablecoin, and ilks are
 *         registered dynamically.
 * @dev Uses a shared-reserve model with a single ilk-keyed module riding the equally singular Collateral Adapter.
 *      USDR's reserve is shared, so guaranteed obligations always take priority and redemption reverts when free
 *      slack is too low. This keeps the protocol from promising the same dollar twice.
 */
contract PegStabilityModule is IPegStabilityModule, AccessControl {
    using SafeERC20 for IERC20Metadata;

    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc IPegStabilityModule
    IUSDR public immutable USDR;

    /// @inheritdoc IPegStabilityModule
    IVaultEngine public immutable VAULT_ENGINE;

    /// @inheritdoc IPegStabilityModule
    IReserveAccounting public immutable RESERVE_ACCOUNTING;

    /// @inheritdoc IPegStabilityModule
    ICollateralAdapter public immutable COLLATERAL_ADAPTER;

    /// @inheritdoc IPegStabilityModule
    mapping(bytes32 ilkId => Ilk ilk) public ilks;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the module and grants the Vault Engine unlimited USDR movement rights.
     * @param collateralAdapter_ Address of the token adapter.
     * @param reserveAccounting_ Address of the reserve accounting contract.
     */
    constructor(ICollateralAdapter collateralAdapter_, IReserveAccounting reserveAccounting_) {
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
        require(address(ilks[ilkId].token) == address(0), "PegStabilityModule/ilk-already-init");

        // The ilk must already be registered with the adapter.
        (IERC20Metadata token, uint8 dec, bool isUsdr, ) = COLLATERAL_ADAPTER.ilks(ilkId);
        if (address(token) == address(0) || isUsdr) {
            _revert(InvalidAddress.selector);
        }

        ilks[ilkId] = Ilk({ token: token, to18ConversionFactor: 10 ** (18 - dec), tin: 0, tout: 0 });

        emit Init({ ilkId: ilkId, token: address(token) });
    }

    /**
     * @inheritdoc IPegStabilityModule
     */
    function file(bytes32 ilkId, bytes32 what, uint256 data) external onlyRole(_WARD_ROLE) {
        if (address(ilks[ilkId].token) == address(0)) {
            _revert(InvalidAddress.selector);
        }

        if (what == "tin") {
            ilks[ilkId].tin = data;
        } else if (what == "tout") {
            ilks[ilkId].tout = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ ilkId: ilkId, what: what, data: data });
    }

    /**
     * @inheritdoc IPegStabilityModule
     */
    function sellStable(bytes32 ilkId, address user, uint256 stableAmt) external {
        Ilk storage ilk = ilks[ilkId];

        if (address(ilk.token) == address(0)) {
            _revert(InvalidAddress.selector);
        }
        if (stableAmt == 0) {
            _revert(InvalidAmount.selector);
        }

        uint256 stableAmt18 = stableAmt * ilk.to18ConversionFactor;
        uint256 fee = (stableAmt18 * ilk.tin) / _WAD;
        uint256 usdrAmt = stableAmt18 - fee;

        // Moving the stablecoins into the protocol's stable reserve. The ceiling check happens inside the Vault
        // Engine's frob.
        ilk.token.safeTransferFrom(msg.sender, address(this), stableAmt);
        ilk.token.forceApprove(address(COLLATERAL_ADAPTER), stableAmt);
        COLLATERAL_ADAPTER.join(ilkId, address(this), stableAmt);
        VAULT_ENGINE.frob(ilkId, address(this), address(this), address(this), int256(stableAmt18), int256(stableAmt18));
        COLLATERAL_ADAPTER.exit(_USDR_ILK, user, usdrAmt);

        // Registering the reserve increase.
        RESERVE_ACCOUNTING.recordIncrease(stableAmt18);

        emit SellStable({ ilkId: ilkId, user: user, stableAmt: stableAmt, usdrAmt: usdrAmt });
    }

    /**
     * @inheritdoc IPegStabilityModule
     */
    function buyStable(bytes32 ilkId, address user, uint256 stableAmt) external {
        Ilk storage ilk = ilks[ilkId];

        if (address(ilk.token) == address(0)) {
            _revert(InvalidAddress.selector);
        }
        if (stableAmt == 0) {
            _revert(InvalidAmount.selector);
        }

        uint256 stableAmt18 = stableAmt * ilk.to18ConversionFactor;
        uint256 fee = (stableAmt18 * ilk.tout) / _WAD;
        uint256 usdrAmt = stableAmt18 + fee;

        // Free-slack check: redemption is best-effort, served only from the reserve minus the amount committed to
        // guaranteed obligations. If free slack is too low, revert so the user must use the open market instead.
        require(stableAmt18 <= RESERVE_ACCOUNTING.freeSlack(), "PegStabilityModule/insufficient-free-slack");

        USDR.transferFrom(msg.sender, address(this), usdrAmt);
        COLLATERAL_ADAPTER.join(_USDR_ILK, address(this), usdrAmt);
        VAULT_ENGINE.frob(
            ilkId,
            address(this),
            address(this),
            address(this),
            -int256(stableAmt18),
            -int256(stableAmt18)
        );
        COLLATERAL_ADAPTER.exit(ilkId, user, stableAmt);

        // Registering the reserve decrease.
        RESERVE_ACCOUNTING.recordDecrease(stableAmt18);

        emit BuyStable({ ilkId: ilkId, user: user, stableAmt: stableAmt, usdrAmt: usdrAmt });
    }
}
