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
import { WAD, WARD_ROLE } from "../shared/Constants.sol";
import { InvalidAmount, UnrecognizedParameter } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title PegStabilityModule.
 * @author Rain Team.
 * @notice The on-ramp and off-ramp for stablecoins. Deposit USDT or USDC, get USDR one-for-one.
 *         Return USDR, get stablecoins back — but redemption is best-effort, served only from
 *         the protocol's free reserves after guaranteed obligations are covered.
 * @dev Based on MakerDAO's PSM, adapted to a shared-reserve model. One instance per stablecoin.
 *      Unlike MakerDAO's PSM, which holds segregated stablecoins and can always redeem, USDR's
 *      reserve is shared: guaranteed obligations always take priority, so redemption reverts
 *      when free slack is too low. This keeps the protocol from promising the same dollar twice.
 */
contract PegStabilityModule is IPegStabilityModule, Auth {
    using SafeERC20 for IERC20Metadata;

    /* ========================== STATE VARIABLES ========================== */

    /// @notice The Vault Engine (core ledger).
    IVaultEngine public immutable vaultEngine;

    /// @notice The collateral adapter for the stablecoin.
    ICollateralAdapter public immutable collateralAdapter;

    /// @notice The stablecoin (USDT or USDC).
    IERC20Metadata public immutable stableToken;

    /// @notice The USDR token adapter.
    ICollateralAdapter public immutable usdrAdapter;

    /// @notice The USDR token.
    IUSDR public immutable usdr;

    /// @notice The reserve accounting contract that reports free slack.
    IReserveAccounting public reserveAccounting;

    /// @notice Identifier of the stablecoin's collateral type.
    bytes32 public immutable ilkId;

    /// @notice Decimal conversion factor between the stablecoin and 18 decimals.
    uint256 public immutable to18ConversionFactor;

    /// @notice Mint fee [wad]. Zero at launch.
    uint256 public tin;

    /// @notice Redeem fee [wad]. Zero at launch.
    uint256 public tout;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the module and grants the Vault Engine unlimited USDR movement rights.
     * @param collateralAdapter_ Address of the stablecoin's collateral adapter.
     * @param usdrAdapter_ Address of the USDR token adapter.
     * @param reserveAccounting_ Address of the reserve accounting contract.
     */
    constructor(
        ICollateralAdapter collateralAdapter_,
        ICollateralAdapter usdrAdapter_,
        IReserveAccounting reserveAccounting_
    ) {
        collateralAdapter = collateralAdapter_;
        usdrAdapter = usdrAdapter_;
        reserveAccounting = reserveAccounting_;
        vaultEngine = IVaultEngine(address(collateralAdapter_.vaultEngine()));
        stableToken = collateralAdapter_.token();
        usdr = IUSDR(address(usdrAdapter_.token()));
        ilkId = collateralAdapter_.ilkId();
        to18ConversionFactor = 10 ** (18 - collateralAdapter_.dec());

        vaultEngine.hope(address(usdrAdapter_));
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IPegStabilityModule
     */
    function file(bytes32 what, uint256 data) external onlyRole(WARD_ROLE) {
        if (what == "tin") {
            tin = data;
        } else if (what == "tout") {
            tout = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, data: data });
    }

    /**
     * @inheritdoc IPegStabilityModule
     */
    function sellStable(address user, uint256 stableAmt) external {
        if (stableAmt == 0) {
            _revert(InvalidAmount.selector);
        }

        uint256 stableAmt18 = stableAmt * to18ConversionFactor;
        uint256 fee = (stableAmt18 * tin) / WAD;
        uint256 usdrAmt = stableAmt18 - fee;

        // Moving the stablecoins into the protocol's stable reserve. The ceiling check happens
        // inside the Vault Engine's frob.
        stableToken.safeTransferFrom(msg.sender, address(this), stableAmt);
        stableToken.forceApprove(address(collateralAdapter), stableAmt);
        collateralAdapter.join(address(this), stableAmt);
        vaultEngine.frob(ilkId, address(this), address(this), address(this), int256(stableAmt18), int256(stableAmt18));
        usdrAdapter.exit(user, usdrAmt);

        // Registering the reserve increase.
        reserveAccounting.recordIncrease(stableAmt18);

        emit SellStable({ user: user, stableAmt: stableAmt, usdrAmt: usdrAmt });
    }

    /**
     * @inheritdoc IPegStabilityModule
     */
    function buyStable(address user, uint256 stableAmt) external {
        if (stableAmt == 0) {
            _revert(InvalidAmount.selector);
        }

        uint256 stableAmt18 = stableAmt * to18ConversionFactor;
        uint256 fee = (stableAmt18 * tout) / WAD;
        uint256 usdrAmt = stableAmt18 + fee;

        // Free-slack check: redemption is best-effort, served only from the reserve minus the
        // amount committed to guaranteed obligations. If free slack is too low, revert — the
        // user must use the open market instead.
        require(stableAmt18 <= reserveAccounting.freeSlack(), "PegStabilityModule/insufficient-free-slack");

        usdr.transferFrom(msg.sender, address(this), usdrAmt);
        usdrAdapter.join(address(this), usdrAmt);
        vaultEngine.frob(
            ilkId,
            address(this),
            address(this),
            address(this),
            -int256(stableAmt18),
            -int256(stableAmt18)
        );
        collateralAdapter.exit(user, stableAmt);

        // Registering the reserve decrease.
        reserveAccounting.recordDecrease(stableAmt18);

        emit BuyStable({ user: user, stableAmt: stableAmt, usdrAmt: usdrAmt });
    }
}
