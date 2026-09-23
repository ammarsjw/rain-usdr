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
 * @notice The emergency settlement module. When governance pulls the plug, this contract freezes the system,
 *         settles every vault at the last oracle price, hands vault owners their excess collateral back, and
 *         finally lets every USDR holder redeem the remaining collateral pro-rata. This contract runs on a
 *         single balance sheet; the Vault Engine's cage drips every ilk before freezing its rates, so no
 *         accrued fee is silently forgiven at shutdown and the settlement math below is exact at any accrued
 *         rate (`tab / rate`, `art * rate * tag`).
 * @dev Settlement runs in ordered phases:
 *      1. `cage()` - freeze the Vault Engine, the Liquidation Trigger and the Price Converter.
 *      2. `cage(ilkId)` - fix each collateral type's settlement price and snapshot its debt.
 *      3. `skip(ilkId, id)` - reclaim in-flight auctions into the vaults they were seized from.
 *         `skim(vaultId)` - settle each vault: confiscate collateral covering its debt, cancel the debt.
 *      4. `free(vaultId)` - vault owners reclaim leftover collateral (their vault must carry no debt).
 *      5. `thaw()` - after the cooldown, with every in-flight auction reclaimed, fix the total debt (net of
 *         the Balance Sheet's residual surplus, so redemption prices against the packable supply).
 *      6. `flow(ilkId)` - compute each collateral type's final redemption price.
 *      7. `pack(wad)` - USDR holders deposit internal USDR into a redemption bag.
 *      8. `cash(ilkId, wad)` - holders redeem each collateral type pro-rata against their bag.
 *      Holders of the USDR ERC-20 first convert it to internal USDR through the Collateral Adapter (`join`),
 *      and must `hope` this contract so it can move their internal balance in `pack`.
 */
contract End is IEnd, AccessControl, ReentrancyGuard {
    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc IEnd
    IVaultEngine public immutable VAULT_ENGINE;

    /// @inheritdoc IEnd
    uint256 public live;

    /// @inheritdoc IEnd
    uint256 public when;

    /// @inheritdoc IEnd
    uint256 public wait;

    /// @inheritdoc IEnd
    uint256 public debt;

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
    mapping(bytes32 ilkId => uint256 unskimmedArt) public pendingArt;

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
    function cage() external onlyRole(_WARD_ROLE) {
        if (live != 1) {
            _revert(AlreadyCaged.selector);
        }

        live = 0;
        when = block.timestamp;

        // Freezing the system: no new debt, no new liquidations, no more price pokes.
        VAULT_ENGINE.cage();
        liquidationTrigger.cage();
        priceConverter.cage();

        // Freezing every oracle-backed ilk's OSM in the SAME transaction (audit H07): after the global cage,
        // both poke and cage(ilkId) are permissionless, so transaction ordering would otherwise select which
        // delayed price (cur vs a matured nxt) becomes each ilk's permanent settlement price — reallocating
        // collateral between vault owners and USDR holders at the orderer's discretion. A stopped OSM blocks
        // poke only: read still serves the frozen cur, which is exactly what cage(ilkId) consumes later.
        // Deliberately NOT wrapped in try/catch — a failed stop would preserve the race for that ilk, so it
        // must abort the shutdown instead (correct OSM authorization is a shutdown prerequisite).
        uint256 length = VAULT_ENGINE.ilkIdsLength();

        for (uint256 i; i < length; ++i) {
            bytes32 ilkId = VAULT_ENGINE.ilkIds(i);

            (IOracleSecurityModule pip, , bool fixedPrice) = priceConverter.ilks(ilkId);

            if (!fixedPrice && address(pip) != address(0)) {
                pip.stop(ilkId);
            }
        }

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

        // Settlement-completeness accumulator: the debt that still awaits skim. Initialized to the snapshot,
        // raised by skip (reinstated auction debt), lowered by skim as vaults settle. flow requires it at
        // zero so the shortfall (gap) is complete before the redemption price is fixed.
        pendingArt[ilkId] = globalArt;

        // Halting this collateral's auction house: after global settlement the auction price keeps decaying
        // while the settlement price below is fixed forever, so any still-running auction becomes a risk-free
        // arbitrage against USDR redeemers once the curve crosses break-even and collateral bought there
        // leaves the redemption pool permanently. `yank` is deliberately not live-gated, so `skip` still
        // reclaims in-flight auctions after the halt. Ilks with no auction house configured (e.g. PSM
        // stables) skip this.
        (address clipAddress, , , , ) = liquidationTrigger.ilks(ilkId);

        if (clipAddress != address(0) && IDutchAuction(clipAddress).live() == 1) {
            IDutchAuction(clipAddress).cage();
        }

        // The settlement price is par (USDR's target value) divided by the collateral's last delayed price:
        // collateral units owed per USDR of debt [ray]. Fixed-price ilks settle at exactly $1, matching the
        // price they minted at; oracle-backed ilks read the OSM's current value one final time.
        (IOracleSecurityModule pip, , bool fixedPrice) = priceConverter.ilks(ilkId);

        uint256 price;

        if (fixedPrice) {
            price = _WAD;
        } else {
            if (address(pip) == address(0)) {
                _revert(InvalidAddress.selector);
            }

            price = uint256(pip.read(ilkId));
        }

        tag[ilkId] = (priceConverter.par() * _WAD) / price;

        emit CageIlk({ ilkId: ilkId, tag: tag[ilkId], art: globalArt });
    }

    /**
     * @inheritdoc IEnd
     */
    function skip(bytes32 ilkId, uint256 auctionId) external nonReentrant {
        if (tag[ilkId] == 0) {
            _revert(TagNotDefined.selector);
        }

        (address clipAddress, , , , ) = liquidationTrigger.ilks(ilkId);

        IDutchAuction clip = IDutchAuction(clipAddress);

        (, uint256 tab, uint256 lot, uint256 vaultId, , , ) = clip.sales(auctionId);

        (, , uint256 rate, , , , , ) = VAULT_ENGINE.ilks(ilkId);

        // Recreating the auction's debt on the Balance Sheet so the reclaim below can cancel it: suck mints
        // matched surplus and bad debt, grab then consumes the bad debt while restoring the vault. Net
        // effect: the vault gets its collateral and debt back, and the Balance Sheet keeps a surplus
        // offsetting the sin queued at bark time.
        VAULT_ENGINE.suck(address(balanceSheet), address(balanceSheet), tab);

        // Yanking the auction moves its remaining collateral to this contract.
        clip.yank(auctionId);

        // Restoring the vault: the debt including the liquidation penalty is reinstated so the owner settles
        // on the same terms as everyone else.
        uint256 restoredArt = tab / rate;

        // The reinstated debt must also be added back to this ilk's settlement snapshot: `thaw` fixes the
        // total debt from the Vault Engine (which includes the restored debt via grab), so leaving the
        // snapshot short makes `flow` divide a short numerator by a full denominator understating the
        // redemption price and stranding the difference in this contract forever.
        art[ilkId] += restoredArt;

        // The reinstated debt also awaits skim, so it raises the completeness accumulator by the same amount.
        pendingArt[ilkId] += restoredArt;

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

        // The collateral owed is the vault's debt valued at the settlement price. If the vault holds less
        // than it owes, the difference is recorded as this collateral's shortfall and socialized across
        // redeemers in flow.
        uint256 owe = (((urnArt * rate) / _RAY) * tag[ilkId]) / _RAY;
        uint256 wad = Math.min(ink, owe);

        gap[ilkId] += owe - wad;

        // The settled debt leaves the completeness accumulator: once every debt-bearing vault has been
        // skimmed (pendingArt == 0), the shortfall (gap) is complete and flow may fix the redemption price.
        // Zero-debt or repeat skims lower it by nothing.
        pendingArt[ilkId] -= urnArt;

        // Overflow guards on the signed casts.
        if (int256(wad) < 0 || int256(urnArt) < 0) {
            _revert(InvalidAmount.selector);
        }

        // Confiscating the owed collateral to this contract and cancelling the debt against the Balance
        // Sheet.
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

        if (block.timestamp < when + wait) {
            _revert(WaitNotElapsed.selector);
        }

        // Every in-flight auction must be reclaimed (skip) before the total debt is fixed: skip sucks the
        // auction's tab as fresh surplus and debt, so a skip landing after this snapshot would inflate the
        // ledger past the fixed total and desynchronize the netting below. After cage(ilkId) each auction
        // house is caged, so skip is the only way its active list drains. Ilks with no auction house (e.g.
        // PSM stables) have nothing to wait for.
        uint256 length = VAULT_ENGINE.ilkIdsLength();

        for (uint256 i; i < length; ++i) {
            (address clipAddress, , , , ) = liquidationTrigger.ilks(VAULT_ENGINE.ilkIds(i));

            if (clipAddress != address(0) && IDutchAuction(clipAddress).count() != 0) {
                _revert(AuctionsPending.selector);
            }
        }

        // The redemption supply is the total debt NET of the Balance Sheet's residual surplus. Requiring the
        // surplus to be healed to zero instead would brick settlement forever: stability fees accrue as
        // surplus with NO matching sin, so when the book is mostly repaid before shutdown the post-skim sin
        // can be smaller than the surplus and the residual is unhealable (and distributeSurplus cannot move
        // amounts under the hump floor). Netting is exact either way — heal burns surplus and debt equally,
        // so the difference is invariant to how much healing ran — and it prices redemption against the
        // PACKABLE supply: the Balance Sheet never packs its own balance, so counting it in the denominator
        // would understate every fix and strand the difference in this contract forever.
        debt = VAULT_ENGINE.debt() - VAULT_ENGINE.usdr(address(balanceSheet));

        // A zero net snapshot means there is no redeemable supply at all (audit M07): without this guard the
        // zero would not arm DebtAlreadyFixed, so thaw could be re-run indefinitely, emitting spurious Thaw
        // events while flow/pack/cash (all requiring debt != 0) stay unreachable anyway.
        if (debt == 0) {
            _revert(NoRedeemableDebt.selector);
        }

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

        // Every in-flight auction on this ilk must be reclaimed (skip) before the redemption price is fixed:
        // skip raises the settlement snapshot (art) by the reinstated debt, and fix is one-shot. Fixing the
        // price while auctions are still pending would permanently understate it and strand the collateral
        // later yanked into this contract. After cage(ilkId) the auction house is caged, so skip is the only
        // way its active list can drain. Ilks with no auction house (e.g. PSM stables) have nothing to wait
        // for.
        (address clipAddress, , , , ) = liquidationTrigger.ilks(ilkId);

        if (clipAddress != address(0) && IDutchAuction(clipAddress).count() != 0) {
            _revert(AuctionsPending.selector);
        }

        // Settlement-completeness guard: every debt-bearing vault on this ilk must have been skimmed before
        // the redemption price is fixed. An unskimmed underwater vault leaves gap[ilkId] understated, so a
        // premature flow would lock fix too favorable — the early redeemer over-collects from the pot and
        // later redeemers' cash reverts against an emptied pool. Skim is permissionless, so anyone can drive
        // this to zero.
        if (pendingArt[ilkId] != 0) {
            _revert(SkimsPending.selector);
        }

        (, , uint256 rate, , , , , ) = VAULT_ENGINE.ilks(ilkId);

        // The redeemable collateral for this ilk is its snapshotted debt valued at the settlement price,
        // minus the shortfall that could not be confiscated. Dividing by the fixed total debt gives
        // collateral per USDR [ray].
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

        // The deposited USDR moves to the Balance Sheet, permanently retiring it from circulation. The caller
        // must have hoped this contract on the Vault Engine.
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
}
