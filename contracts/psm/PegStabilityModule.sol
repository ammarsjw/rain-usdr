// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ICollateralJoin } from "../interfaces/ICollateralJoin.sol";
import { IPegStabilityModule } from "../interfaces/IPegStabilityModule.sol";
import { IReserveAccounting } from "../interfaces/IReserveAccounting.sol";
import { IUsdrJoin } from "../interfaces/IUsdrJoin.sol";
import { IUSDR } from "../interfaces/IUSDR.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { RAY, WAD } from "../shared/Constants.sol";
import { InvalidAmount, NotAuthorized, UnrecognizedParameter } from "../shared/Errors.sol";
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
contract PegStabilityModule is IPegStabilityModule {
    using SafeERC20 for IERC20Metadata;

    /* ========================== STATE VARIABLES ========================== */

    /// @notice Authorized accounts. `wards[account] == 1` grants authorization.
    mapping(address account => uint256 authorization) public wards;

    /// @notice The Vault Engine (core ledger).
    IVaultEngine public immutable vaultEngine;

    /// @notice The collateral adapter for the stablecoin.
    ICollateralJoin public immutable gemJoin;

    /// @notice The stablecoin (USDT or USDC).
    IERC20Metadata public immutable gem;

    /// @notice The USDR token adapter.
    IUsdrJoin public immutable usdrJoin;

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

    /* ========================== MODIFIERS ========================== */

    /// @dev Restricts a function to authorized accounts.
    modifier auth() {
        if (wards[msg.sender] != 1) {
            _revert(NotAuthorized.selector);
        }
        _;
    }

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the module and grants the Vault Engine unlimited USDR movement rights.
     * @param gemJoin_ Address of the stablecoin's collateral adapter.
     * @param usdrJoin_ Address of the USDR token adapter.
     * @param reserveAccounting_ Address of the reserve accounting contract.
     */
    constructor(ICollateralJoin gemJoin_, IUsdrJoin usdrJoin_, IReserveAccounting reserveAccounting_) {
        wards[msg.sender] = 1;
        gemJoin = gemJoin_;
        usdrJoin = usdrJoin_;
        reserveAccounting = reserveAccounting_;
        vaultEngine = IVaultEngine(address(gemJoin_.vaultEngine()));
        gem = gemJoin_.gem();
        usdr = usdrJoin_.usdr();
        ilkId = gemJoin_.ilkId();
        to18ConversionFactor = 10 ** (18 - gemJoin_.dec());

        vaultEngine.hope(address(usdrJoin_));

        emit Rely({ account: msg.sender });
    }

    /* ========================== ADMINISTRATION ========================== */

    /**
     * @inheritdoc IPegStabilityModule
     */
    function rely(address account) external auth {
        wards[account] = 1;

        emit Rely({ account: account });
    }

    /**
     * @inheritdoc IPegStabilityModule
     */
    function deny(address account) external auth {
        wards[account] = 0;

        emit Deny({ account: account });
    }

    /**
     * @inheritdoc IPegStabilityModule
     */
    function file(bytes32 what, uint256 data) external auth {
        if (what == "tin") {
            tin = data;
        } else if (what == "tout") {
            tout = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, data: data });
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IPegStabilityModule
     */
    function sellGem(address user, uint256 gemAmt) external {
        if (gemAmt == 0) {
            _revert(InvalidAmount.selector);
        }

        uint256 gemAmt18 = gemAmt * to18ConversionFactor;
        uint256 fee = (gemAmt18 * tin) / WAD;
        uint256 usdrAmt = gemAmt18 - fee;

        // Moving the stablecoins into the protocol's stable reserve. The ceiling check happens
        // inside the Vault Engine's frob.
        gem.safeTransferFrom(msg.sender, address(this), gemAmt);
        gem.forceApprove(address(gemJoin), gemAmt);
        gemJoin.join(address(this), gemAmt);
        vaultEngine.frob(ilkId, address(this), address(this), address(this), int256(gemAmt18), int256(gemAmt18));
        usdrJoin.exit(user, usdrAmt);

        // Registering the reserve increase.
        reserveAccounting.recordIncrease(gemAmt18);

        emit SellGem({ user: user, gemAmt: gemAmt, usdrAmt: usdrAmt });
    }

    /**
     * @inheritdoc IPegStabilityModule
     */
    function buyGem(address user, uint256 gemAmt) external {
        if (gemAmt == 0) {
            _revert(InvalidAmount.selector);
        }

        uint256 gemAmt18 = gemAmt * to18ConversionFactor;
        uint256 fee = (gemAmt18 * tout) / WAD;
        uint256 usdrAmt = gemAmt18 + fee;

        // Free-slack check: redemption is best-effort, served only from the reserve minus the
        // amount committed to guaranteed obligations. If free slack is too low, revert — the
        // user must use the open market instead.
        require(gemAmt18 <= reserveAccounting.freeSlack(), "PegStabilityModule/insufficient-free-slack");

        usdr.transferFrom(msg.sender, address(this), usdrAmt);
        usdrJoin.join(address(this), usdrAmt);
        vaultEngine.frob(ilkId, address(this), address(this), address(this), -int256(gemAmt18), -int256(gemAmt18));
        gemJoin.exit(user, gemAmt);

        // Registering the reserve decrease.
        reserveAccounting.recordDecrease(gemAmt18);

        emit BuyGem({ user: user, gemAmt: gemAmt, usdrAmt: usdrAmt });
    }
}
