// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ICollateralAdapter } from "../interfaces/ICollateralAdapter.sol";
import { IPegStabilityModule } from "../interfaces/IPegStabilityModule.sol";
import { IReserveAccounting } from "../interfaces/IReserveAccounting.sol";
import { IUSDR } from "../interfaces/IUSDR.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { Auth } from "../extensions/Auth.sol";
import { USDR_ILK, WAD, WARD_ROLE } from "../shared/Constants.sol";
import { InvalidAddress, InvalidAmount, UnrecognizedParameter } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title PegStabilityModule.
 * @author Rain Team.
 * @notice The on-ramp and off-ramp for stablecoins. Deposit USDT or USDC, get USDR one-for-one.
 *         Return USDR, get stablecoins back — but redemption is best-effort, served only from
 *         the protocol's free reserves after guaranteed obligations are covered. A single
 *         deployed instance serves every stablecoin: ilks are registered dynamically.
 * @dev Based on MakerDAO's PSM, adapted to a shared-reserve model and generalized from
 *      one-instance-per-stablecoin to a single ilk-keyed module riding the (equally singular)
 *      Collateral Adapter. Unlike MakerDAO's PSM, which holds segregated stablecoins and can
 *      always redeem, USDR's reserve is shared: guaranteed obligations always take priority, so
 *      redemption reverts when free slack is too low. This keeps the protocol from promising
 *      the same dollar twice.
 */
contract PegStabilityModule is IPegStabilityModule, Auth {
    using SafeERC20 for IERC20Metadata;

    /* ========================== TYPES ========================== */

    /**
     * @notice Configuration of a registered stablecoin ilk.
     * @param token The stablecoin (USDT or USDC).
     * @param to18ConversionFactor Decimal conversion factor between the stablecoin and 18
     *        decimals.
     * @param tin Mint fee [wad]. Zero at launch.
     * @param tout Redeem fee [wad]. Zero at launch.
     */
    struct Ilk {
        IERC20Metadata token;
        uint256 to18ConversionFactor;
        uint256 tin;
        uint256 tout;
    }

    /* ========================== STATE VARIABLES ========================== */

    /// @notice The Vault Engine (core ledger).
    IVaultEngine public immutable vaultEngine;

    /// @notice The token adapter (single instance; bridges both stablecoins and USDR).
    ICollateralAdapter public immutable collateralAdapter;

    /// @notice The USDR token.
    IUSDR public immutable usdr;

    /// @notice The reserve accounting contract that reports free slack.
    IReserveAccounting public immutable reserveAccounting;

    /// @notice Configuration per stablecoin ilk.
    mapping(bytes32 ilkId => Ilk ilk) public ilks;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the module and grants the Vault Engine unlimited USDR movement rights.
     * @param collateralAdapter_ Address of the token adapter.
     * @param reserveAccounting_ Address of the reserve accounting contract.
     */
    constructor(ICollateralAdapter collateralAdapter_, IReserveAccounting reserveAccounting_) {
        collateralAdapter = collateralAdapter_;
        reserveAccounting = reserveAccounting_;
        vaultEngine = IVaultEngine(address(collateralAdapter_.vaultEngine()));

        (IERC20Metadata usdrToken, , , ) = collateralAdapter_.ilks(USDR_ILK);
        if (address(usdrToken) == address(0)) {
            _revert(InvalidAddress.selector);
        }
        usdr = IUSDR(address(usdrToken));

        vaultEngine.hope(address(collateralAdapter_));
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IPegStabilityModule
     */
    function init(bytes32 ilkId) external onlyRole(WARD_ROLE) {
        require(address(ilks[ilkId].token) == address(0), "PegStabilityModule/ilk-already-init");

        // The ilk must already be registered with the adapter.
        (IERC20Metadata token, uint8 dec, bool isUsdr, ) = collateralAdapter.ilks(ilkId);
        if (address(token) == address(0) || isUsdr) {
            _revert(InvalidAddress.selector);
        }

        ilks[ilkId] = Ilk({ token: token, to18ConversionFactor: 10 ** (18 - dec), tin: 0, tout: 0 });

        emit Init({ ilkId: ilkId, token: address(token) });
    }

    /**
     * @inheritdoc IPegStabilityModule
     */
    function file(bytes32 ilkId, bytes32 what, uint256 data) external onlyRole(WARD_ROLE) {
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
        uint256 fee = (stableAmt18 * ilk.tin) / WAD;
        uint256 usdrAmt = stableAmt18 - fee;

        // Moving the stablecoins into the protocol's stable reserve. The ceiling check happens
        // inside the Vault Engine's frob.
        ilk.token.safeTransferFrom(msg.sender, address(this), stableAmt);
        ilk.token.forceApprove(address(collateralAdapter), stableAmt);
        collateralAdapter.join(ilkId, address(this), stableAmt);
        vaultEngine.frob(ilkId, address(this), address(this), address(this), int256(stableAmt18), int256(stableAmt18));
        collateralAdapter.exit(USDR_ILK, user, usdrAmt);

        // Registering the reserve increase.
        reserveAccounting.recordIncrease(stableAmt18);

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
        uint256 fee = (stableAmt18 * ilk.tout) / WAD;
        uint256 usdrAmt = stableAmt18 + fee;

        // Free-slack check: redemption is best-effort, served only from the reserve minus the
        // amount committed to guaranteed obligations. If free slack is too low, revert — the
        // user must use the open market instead.
        require(stableAmt18 <= reserveAccounting.freeSlack(), "PegStabilityModule/insufficient-free-slack");

        usdr.transferFrom(msg.sender, address(this), usdrAmt);
        collateralAdapter.join(USDR_ILK, address(this), usdrAmt);
        vaultEngine.frob(
            ilkId,
            address(this),
            address(this),
            address(this),
            -int256(stableAmt18),
            -int256(stableAmt18)
        );
        collateralAdapter.exit(ilkId, user, stableAmt);

        // Registering the reserve decrease.
        reserveAccounting.recordDecrease(stableAmt18);

        emit BuyStable({ ilkId: ilkId, user: user, stableAmt: stableAmt, usdrAmt: usdrAmt });
    }
}
