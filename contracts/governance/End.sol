// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IBalanceSheet } from "../interfaces/IBalanceSheet.sol";
import { IDutchAuction } from "../interfaces/IDutchAuction.sol";
import { IEnd } from "../interfaces/IEnd.sol";
import { ILiquidationTrigger } from "../interfaces/ILiquidationTrigger.sol";
import { IOracleSecurityModule } from "../interfaces/IOracleSecurityModule.sol";
import { IPriceConverter } from "../interfaces/IPriceConverter.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { _RAY, _WAD, _WARD_ROLE } from "../shared/Constants.sol";
import { InvalidAddress, InvalidAmount, NotAuthorized, NotLive, UnrecognizedParameter } from "../shared/Errors.sol";
import { Cage } from "../shared/Events.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title End
 * @author Rain Team
 * @notice The emergency settlement module. When governance pulls the plug, this contract freezes the system, settles
 *         every vault at the last oracle price, hands vault owners their excess collateral back, and finally lets
 *         every USDR holder redeem the remaining collateral pro-rata. This contract runs on a single balance sheet;
 *         the Vault Engine's cage drips every ilk before freezing its rates, so no accrued fee is silently forgiven at
 *         shutdown and the settlement math below is exact at any accrued rate (`tab / rate`, `art * rate * tag`).
 * @dev Settlement runs in ordered phases:
 *      1. `cage()` - freeze the Vault Engine, the Liquidation Trigger and the Price Converter.
 *      2. `cage(ilkId)` - fix each collateral type's settlement price and snapshot its debt.
 *      3. `skip(ilkId, id)` - reclaim in-flight auctions into the vaults they were seized from.
 *         `skim(vaultId)` - settle each vault: confiscate collateral covering its debt, cancel the debt.
 *      4. `free(vaultId)` - vault owners reclaim leftover collateral (their vault must carry no debt).
 *      5. `thaw()` - after the cooldown, with the Balance Sheet's surplus healed away, fix the total debt.
 *      6. `flow(ilkId)` - compute each collateral type's final redemption price.
 *      7. `pack(wad)` - USDR holders deposit internal USDR into a redemption bag.
 *      8. `cash(ilkId, wad)` - holders redeem each collateral type pro-rata against their bag.
 *      Holders of the USDR ERC-20 first convert it to internal USDR through the Collateral Adapter (`join`), and must
 *      `hope` this contract so it can move their internal balance in `pack`.
 */
contract End is IEnd, AccessControl, ReentrancyGuard {
    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc IEnd
    IVaultEngine public immutable VAULT_ENGINE;

    /// @inheritdoc IEnd
    uint256 public when;

    /// @inheritdoc IEnd
    uint256 public wait;

    /// @inheritdoc IEnd
    uint256 public debt;

    /// @inheritdoc IEnd
    uint256 public live;

    /// @inheritdoc IEnd
    ILiquidationTrigger public liquidationTrigger;

    /// @inheritdoc IEnd
    IBalanceSheet public balanceSheet;

    /// @inheritdoc IEnd
    IPriceConverter public priceConverter;

    /// @inheritdoc IEnd
    mapping(bytes32 ilkId => uint256 settlementPrice) public tag;

    /// @inheritdoc IEnd
    mapping(bytes32 ilkId => uint256 shortfall) public gap;

    /// @inheritdoc IEnd
    mapping(bytes32 ilkId => uint256 snapshotArt) public art;

    /// @inheritdoc IEnd
    mapping(bytes32 ilkId => uint256 redemptionPrice) public fix;

    /// @inheritdoc IEnd
    mapping(address usr => uint256 deposited) public bag;

    /// @inheritdoc IEnd
    mapping(bytes32 ilkId => mapping(address usr => uint256 redeemed)) public out;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the settlement module and marks it live.
     * @param vaultEngine_ Address of the Vault Engine.
     */
    constructor(IVaultEngine vaultEngine_) {
        if (address(vaultEngine_) == address(0)) {
            _revert(InvalidAddress.selector);
        }

        _setRoleAdmin(_WARD_ROLE, _WARD_ROLE);

        _grantRole(_WARD_ROLE, msg.sender);

        VAULT_ENGINE = vaultEngine_;

        live = 1;
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IEnd
     */
    function file(bytes32 what, uint256 data) external onlyRole(_WARD_ROLE) {
        if (live != 1) {
            _revert(NotLive.selector);
        }

        if (what == "wait") {
            wait = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, data: data });
    }

    /**
     * @inheritdoc IEnd
     */
    function file(bytes32 what, address data) external onlyRole(_WARD_ROLE) {
        if (live != 1) {
            _revert(NotLive.selector);
        }

        if (what == "liquidationTrigger") {
            liquidationTrigger = ILiquidationTrigger(data);
        } else if (what == "balanceSheet") {
            balanceSheet = IBalanceSheet(data);
        } else if (what == "priceConverter") {
            priceConverter = IPriceConverter(data);
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, addr: data });
    }

    /**
     * @inheritdoc IEnd
     */
    function skip(bytes32 ilkId, uint256 auctionId) external nonReentrant {
        if (tag[ilkId] == 0) {
            _revert(TagNotDefined.selector);
        }

        IDutchAuction dutchAuction = liquidationTrigger.dutchAuction();

        (, uint256 tab, uint256 lot, uint256 vaultId, , , ) = dutchAuction.sales(auctionId);

        (, , uint256 rate, , , , , ) = VAULT_ENGINE.ilks(ilkId);

        // Recreating the auction's debt on the Balance Sheet so the reclaim below can cancel it: suck mints matched
        // surplus and bad debt, grab then consumes the bad debt while restoring the vault. Net effect: the vault gets
        // its collateral and debt back, and the Balance Sheet keeps a surplus offsetting the sin queued at bark time.
        VAULT_ENGINE.suck(address(balanceSheet), address(balanceSheet), tab);

        // Yanking the auction moves its remaining collateral to this contract.
        dutchAuction.yank(auctionId);

        // Restoring the vault: the debt including the liquidation penalty is reinstated so the owner settles on the
        // same terms as everyone else.
        uint256 restoredArt = tab / rate;

        // The reinstated debt must also be added back to this ilk's settlement snapshot: `thaw` fixes the total debt
        // from the Vault Engine (which includes the restored debt via grab), so leaving the snapshot short makes
        // `flow` divide a short numerator by a full denominator understating the redemption price and stranding the
        // difference in this contract forever.
        art[ilkId] += restoredArt;

        // Overflow guards on the signed casts.
        if (int256(lot) < 0 || int256(restoredArt) < 0) {
            _revert(InvalidAmount.selector);
        }

        VAULT_ENGINE.grab(vaultId, address(this), address(balanceSheet), int256(lot), int256(restoredArt));

        emit Skip({ ilkId: ilkId, auctionId: auctionId, vaultId: vaultId, lot: lot, art: restoredArt });
    }

    /**
     * @inheritdoc IEnd
     */
    function skim(uint256 vaultId) external nonReentrant {
        bytes32 ilkId = VAULT_ENGINE.ilkOf(vaultId);

        if (tag[ilkId] == 0) {
            _revert(TagNotDefined.selector);
        }

        (uint256 ink, uint256 urnArt) = VAULT_ENGINE.urns(vaultId);
        (, , uint256 rate, , , , , ) = VAULT_ENGINE.ilks(ilkId);

        // The collateral owed is the vault's debt valued at the settlement price. If the vault holds less than it
        // owes, the difference is recorded as this collateral's shortfall and socialized across redeemers in flow.
        uint256 owe = (((urnArt * rate) / _RAY) * tag[ilkId]) / _RAY;
        uint256 wad = Math.min(ink, owe);

        gap[ilkId] += owe - wad;

        // Overflow guards on the signed casts.
        if (int256(wad) < 0 || int256(urnArt) < 0) {
            _revert(InvalidAmount.selector);
        }

        // Confiscating the owed collateral to this contract and cancelling the debt against the Balance Sheet.
        VAULT_ENGINE.grab(vaultId, address(this), address(balanceSheet), -int256(wad), -int256(urnArt));

        emit Skim({ ilkId: ilkId, vaultId: vaultId, wad: wad, art: urnArt });
    }

    /**
     * @inheritdoc IEnd
     */
    function free(uint256 vaultId) external nonReentrant {
        if (live != 0) {
            _revert(StillLive.selector);
        }

        address owner = VAULT_ENGINE.ownerOf(vaultId);

        if (owner != msg.sender) {
            _revert(NotAuthorized.selector);
        }

        (uint256 ink, uint256 urnArt) = VAULT_ENGINE.urns(vaultId);

        // The vault must be fully settled (or never indebted) before its leftover collateral is released.
        if (urnArt != 0) {
            _revert(ArtNotZero.selector);
        }

        bytes32 ilkId = VAULT_ENGINE.ilkOf(vaultId);

        // Overflow guard on the signed cast.
        if (int256(ink) < 0) {
            _revert(InvalidAmount.selector);
        }

        VAULT_ENGINE.grab(vaultId, owner, address(balanceSheet), -int256(ink), 0);

        emit Free({ ilkId: ilkId, vaultId: vaultId, owner: owner, ink: ink });
    }

    /**
     * @inheritdoc IEnd
     */
    function thaw() external {
        if (live != 0) {
            _revert(StillLive.selector);
        }

        if (debt != 0) {
            _revert(DebtAlreadyFixed.selector);
        }

        // The Balance Sheet's surplus must be fully healed against bad debt first, so redemption is computed against
        // the true outstanding supply. Queued sin unlocks for healing once the Balance Sheet's own wait elapses. This
        // contract's wait needs to be set accordingly.
        if (VAULT_ENGINE.usdr(address(balanceSheet)) != 0) {
            _revert(SurplusNotZero.selector);
        }

        if (block.timestamp < when + wait) {
            _revert(WaitNotElapsed.selector);
        }

        debt = VAULT_ENGINE.debt();

        emit Thaw({ debt: debt });
    }

    /**
     * @inheritdoc IEnd
     */
    function flow(bytes32 ilkId) external {
        if (debt == 0) {
            _revert(DebtNotFixed.selector);
        }

        if (fix[ilkId] != 0) {
            _revert(FixAlreadyDefined.selector);
        }

        (, , uint256 rate, , , , , ) = VAULT_ENGINE.ilks(ilkId);

        // The redeemable collateral for this ilk is its snapshotted debt valued at the settlement price, minus the
        // shortfall that could not be confiscated. Dividing by the fixed total debt gives collateral per USDR [ray].
        uint256 wad = (((art[ilkId] * rate) / _RAY) * tag[ilkId]) / _RAY;

        fix[ilkId] = ((wad - gap[ilkId]) * _RAY) / (debt / _RAY);

        emit Flow({ ilkId: ilkId, fix: fix[ilkId] });
    }

    /**
     * @inheritdoc IEnd
     */
    function pack(uint256 wad) external nonReentrant {
        if (debt == 0) {
            _revert(DebtNotFixed.selector);
        }

        // The deposited USDR moves to the Balance Sheet, permanently retiring it from circulation. The caller must
        // have hoped this contract on the Vault Engine.
        VAULT_ENGINE.move(msg.sender, address(balanceSheet), wad * _RAY);

        bag[msg.sender] += wad;

        emit Pack({ usr: msg.sender, wad: wad });
    }

    /**
     * @inheritdoc IEnd
     */
    function cash(bytes32 ilkId, uint256 wad) external nonReentrant {
        if (fix[ilkId] == 0) {
            _revert(FixNotDefined.selector);
        }

        // Redeeming this collateral against the caller's bag, pro-rata at the final redemption price.
        VAULT_ENGINE.flux(ilkId, address(this), msg.sender, (wad * fix[ilkId]) / _RAY);

        out[ilkId][msg.sender] += wad;

        if (out[ilkId][msg.sender] > bag[msg.sender]) {
            _revert(InsufficientBag.selector);
        }

        emit Cash({ ilkId: ilkId, usr: msg.sender, wad: wad, ink: (wad * fix[ilkId]) / _RAY });
    }

    /**
     * @inheritdoc IEnd
     */
    function cage() external onlyRole(_WARD_ROLE) {
        if (live != 1) {
            _revert(AlreadyCaged.selector);
        }

        live = 0;
        when = block.timestamp;

        // Freezing the system: no new debt, no new liquidations, no more price pokes. The Oracle Security Module is
        // deliberately NOT frozen since `cage(ilkId)` still needs its last delayed price.
        VAULT_ENGINE.cage();
        liquidationTrigger.cage();
        priceConverter.cage();

        emit Cage();
    }

    /**
     * @inheritdoc IEnd
     */
    function cage(bytes32 ilkId) external {
        if (live != 0) {
            _revert(StillLive.selector);
        }

        if (tag[ilkId] != 0) {
            _revert(TagAlreadyDefined.selector);
        }

        (uint256 globalArt, , , , , , , ) = VAULT_ENGINE.ilks(ilkId);

        art[ilkId] = globalArt;

        // Halting the auction house: after global settlement the auction price keeps decaying while the settlement
        // price below is fixed forever, so any still-running auction becomes a risk-free arbitrage against USDR
        // redeemers once the curve crosses break-even and collateral bought there leaves the redemption pool
        // permanently. The auction house is global (it serves every collateral type), so the first caged ilk halts it
        // and later cages skip the already-dead house. `yank` is deliberately not live-gated, so `skip` still reclaims
        // in-flight auctions after the halt. Deployments with no auction house configured skip this.
        IDutchAuction dutchAuction = liquidationTrigger.dutchAuction();

        if (address(dutchAuction) != address(0) && dutchAuction.live() == 1) {
            dutchAuction.cage();
        }

        // The settlement price is par (USDR's target value) divided by the collateral's last delayed price: collateral
        // units owed per USDR of debt [ray]. Fixed-price ilks settle at exactly $1, matching the price they minted at;
        // oracle-backed ilks read the OSM's current value one final time.
        (, bool fixedPrice) = priceConverter.ilks(ilkId);

        uint256 price;

        if (fixedPrice) {
            price = _WAD;
        } else {
            IOracleSecurityModule oracleSecurityModule = priceConverter.oracleSecurityModule();

            if (address(oracleSecurityModule) == address(0)) {
                _revert(InvalidAddress.selector);
            }

            price = uint256(oracleSecurityModule.read(ilkId));
        }

        tag[ilkId] = (priceConverter.par() * _WAD) / price;

        emit CageIlk({ ilkId: ilkId, tag: tag[ilkId], art: globalArt });
    }
}
