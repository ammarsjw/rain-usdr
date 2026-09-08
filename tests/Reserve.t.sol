// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IBalanceSheet } from "../contracts/interfaces/IBalanceSheet.sol";
import { IPegStabilityModule } from "../contracts/interfaces/IPegStabilityModule.sol";
import { IReserveAccounting } from "../contracts/interfaces/IReserveAccounting.sol";
import { ISolvencyEngine } from "../contracts/interfaces/ISolvencyEngine.sol";
import { InvalidAmount, InvalidDuty, SolvencyGateActive, UnrecognizedParameter } from "../contracts/shared/Errors.sol";
import { _RAD, _RAY, _RECORDER_ROLE, _WAD } from "../contracts/shared/Constants.sol";

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { BaseTest } from "./shared/BaseTest.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockExternalExposure } from "./mocks/MockExternalExposure.sol";

/* ========================== BALANCE SHEET ========================== */

/**
 * @title BalanceSheetTest
 * @author Rain Team
 * @notice Coverage of the treasury: sin queue lifecycle, heal bounds, keeper reward suck, the fill-before-burn surplus
 *         rule and the dynamic hump target.
 */
contract BalanceSheetTest is BaseTest {
    /* ========================== 1. FILE ========================== */

    function test_fileParametersAndGuards() public {
        balanceSheet.file("humpFloor", 1000 * _RAD);
        balanceSheet.file("humpRate", _WAD / 10);
        balanceSheet.file("wait", 561600);
        balanceSheet.file("buybackReceiver", address(0xB0B));
        balanceSheet.file("reserveAccounting", address(reserveAccounting));

        assertEq(balanceSheet.humpFloor(), 1000 * _RAD, "humpFloor");
        assertEq(balanceSheet.humpRate(), _WAD / 10, "humpRate");
        assertEq(balanceSheet.wait(), 561600, "wait");
        assertEq(balanceSheet.buybackReceiver(), address(0xB0B), "receiver");

        vm.expectRevert(UnrecognizedParameter.selector);
        balanceSheet.file("nonsense", 1);

        vm.expectRevert(UnrecognizedParameter.selector);
        balanceSheet.file("nonsense", address(1));

        vm.prank(address(0xBAD));
        vm.expectRevert();
        balanceSheet.file("wait", 0);
    }

    /* ========================== 2. SIN QUEUE ========================== */

    function test_fessFlogHealFullLifecycle() public {
        balanceSheet.file("wait", 1000);

        vaultEngine.suck(address(balanceSheet), address(balanceSheet), 30 * _RAD);
        balanceSheet.fess(30 * _RAD);

        uint256 era = vm.getBlockTimestamp();
        assertEq(balanceSheet.totalQueuedSin(), 30 * _RAD, "queued");
        assertEq(balanceSheet.sin(era), 30 * _RAD, "era bucket");

        // Queued sin cannot be healed and the era cannot be flogged early.
        vm.expectRevert(IBalanceSheet.InsufficientDebt.selector);
        balanceSheet.heal(30 * _RAD);

        vm.expectRevert(IBalanceSheet.WaitNotElapsed.selector);
        balanceSheet.flog(era);

        // After the wait: flog releases, heal cancels.
        vm.warp(era + 1000);
        balanceSheet.flog(era);

        assertEq(balanceSheet.totalQueuedSin(), 0, "queue drained");
        assertEq(balanceSheet.sin(era), 0, "era cleared");

        balanceSheet.heal(30 * _RAD);
        assertEq(vaultEngine.sin(address(balanceSheet)), 0, "healed");

        // Flogging an empty era is a harmless no-op.
        balanceSheet.flog(era);
    }

    function test_healBoundedBySurplusAndReleasedSin() public {
        // Surplus 10, sin 30 (all released, wait = 0).
        vaultEngine.suck(address(balanceSheet), address(this), 20 * _RAD);
        vaultEngine.suck(address(balanceSheet), address(balanceSheet), 10 * _RAD);

        // More than the surplus.
        vm.expectRevert(IBalanceSheet.InsufficientSurplus.selector);
        balanceSheet.heal(11 * _RAD);

        // Within surplus and released sin.
        balanceSheet.heal(10 * _RAD);
        assertEq(vaultEngine.sin(address(balanceSheet)), 20 * _RAD, "partial heal");
    }

    function test_suckPaysKeeperReward() public {
        balanceSheet.suck(keeper, 2 * _RAD);

        assertEq(vaultEngine.usdr(keeper), 2 * _RAD, "keeper paid");
        assertEq(vaultEngine.sin(address(balanceSheet)), 2 * _RAD, "debt recorded");

        vm.prank(address(0xBAD));
        vm.expectRevert();
        balanceSheet.suck(keeper, 1);
    }

    /* ========================== 3. SURPLUS DISTRIBUTION ========================== */

    function test_distributeNoOpsOnUnqueuedBadDebt() public {
        // Regression: unqueued sin (e.g. a suck keeper reward) is a routine keeper race, so distribution
        // no-ops (Maker-consistent) instead of hard-reverting and alarming automation through every liquidation.
        balanceSheet.file("buybackReceiver", address(0xB0B));

        vaultEngine.suck(address(balanceSheet), address(balanceSheet), 10 * _RAD);

        assertEq(balanceSheet.distributeSurplus(), 0, "no-op while unqueued sin outstanding");

        // Healing the sin re-enables distribution of the remaining surplus (all of it: hump target is 0 here).
        balanceSheet.heal(10 * _RAD);
        vaultEngine.suck(address(this), address(balanceSheet), 5 * _RAD);

        assertEq(balanceSheet.distributeSurplus(), 5 * _RAD, "distribution resumes once healed");
    }

    function test_distributeReservesQueuedSinInsteadOfBlocking() public {
        // Regression: queued sin cannot be healed yet, but the surplus that will heal it must not leave.
        // Instead of blocking ALL distribution for the whole wait window, the queued amount is reserved on top of
        // the hump target and only the genuine excess ships.
        balanceSheet.file("buybackReceiver", address(0xB0B));
        balanceSheet.file("wait", 1 days);

        // 30 surplus on the sheet; 10 of queued bad debt arrives via fess (no matched engine sin needed for the
        // reservation logic itself — fess only books the queue).
        vaultEngine.suck(address(this), address(balanceSheet), 30 * _RAD);
        balanceSheet.fess(10 * _RAD);

        // Note: fess books queue-side only; engine sin for the balance sheet is what distribute reads as badDebt.
        // Here badDebt == 0 but totalQueuedSin == 10: the queued amount is still reserved.
        assertEq(balanceSheet.distributeSurplus(), 20 * _RAD, "only surplus above the queued reservation ships");
    }

    function test_distributeRequiresReceiver() public {
        balanceSheet.file("humpFloor", 1 * _RAD);

        vaultEngine.suck(address(this), address(balanceSheet), 10 * _RAD);

        vm.expectRevert(IBalanceSheet.NoBuybackReceiver.selector);
        balanceSheet.distributeSurplus();
    }

    function test_humpTargetIsMaxOfFloorAndRate() public {
        balanceSheet.file("humpFloor", 500 * _RAD);
        balanceSheet.file("humpRate", _WAD / 10);
        balanceSheet.file("reserveAccounting", address(reserveAccounting));

        // Empty reserve: the floor rules.
        assertEq(balanceSheet.humpTarget(), 500 * _RAD, "floor rules empty reserve");

        // A large reserve: 10% of it beats the floor. Mint via the PSM.
        usdt.mint(user, 100_000e6);
        vm.startPrank(user);
        usdt.approve(address(psm), 100_000e6);
        psm.sellStable(USDT_ILK, user, 100_000e6);
        vm.stopPrank();

        assertEq(balanceSheet.humpTarget(), 10_000e18 * _RAY, "10% of 100k reserve");
    }

    function test_distributeReleasesOnlyExcessAboveTarget() public {
        balanceSheet.file("humpFloor", 20 * _RAD);
        balanceSheet.file("buybackReceiver", address(0xB0B));

        vaultEngine.suck(address(this), address(balanceSheet), 50 * _RAD);

        uint256 excess = balanceSheet.distributeSurplus();

        assertEq(excess, 30 * _RAD, "released above target");
        assertEq(vaultEngine.usdr(address(balanceSheet)), 20 * _RAD, "buffer intact");
        assertEq(vaultEngine.usdr(address(0xB0B)), 30 * _RAD, "receiver credited");

        // A second call is a clean no-op at target.
        assertEq(balanceSheet.distributeSurplus(), 0, "no-op at target");
    }
}

/* ========================== RESERVE (PSM, RESERVEACCOUNTING, SOLVENCYENGINE) ========================== */

/**
 * @title ReserveTest
 * @author Rain Team
 * @notice Adversarial coverage of the reserve stack: the direct-OSM pricing (mat-change immunity), the lazy
 *         redemption gate, parameter bounds, volatile ilk validation and escrow guards.
 */
contract ReserveTest is BaseTest {
    /* ========================== HELPERS ========================== */

    function _setRainPrice(uint256 price) internal {
        rainPriceSource.setPrice(price);
        vm.warp(((vm.getBlockTimestamp() / 1800) + 2) * 1800);
        osm.poke(RAIN_ILK);
        vm.warp(vm.getBlockTimestamp() + 3600);
        osm.poke(RAIN_ILK);
        priceConverter.poke(RAIN_ILK);
    }

    function _openVault(address who, uint256 ink, uint256 art) internal returns (uint256 vaultId) {
        rain.mint(who, ink);

        vm.startPrank(who);
        rain.approve(address(collateralAdapter), ink);
        collateralAdapter.join(RAIN_ILK, who, ink);
        vaultId = vaultEngine.open(RAIN_ILK, who);
        vaultEngine.frob(vaultId, who, who, int256(ink), int256(art));
        vm.stopPrank();
    }

    function _sellUsdt(address who, uint256 amt) internal {
        usdt.mint(who, amt);

        vm.startPrank(who);
        usdt.approve(address(psm), amt);
        psm.sellStable(USDT_ILK, who, amt);
        vm.stopPrank();
    }

    /* ========================== 1. DIRECT OSM PRICING ========================== */

    function test_worstCaseLossImmuneToMatChange() public {
        // THE rev-4 headline scenario. Loss must be identical before and after a mat change with no poke: the engine
        // prices collateral straight from the OSM, so mat desynchronization cannot bend it.
        _setRainPrice(1e18);
        _openVault(user, 800e18, 200e18);

        uint256 lossBefore = solvencyEngine.worstCaseLoss();
        assertEq(lossBefore, 60e18, "baseline: 200 - 800*0.5*0.35");

        // Governance responds to rising risk by RAISING mat (the standard action), no poke yet.
        priceConverter.file(RAIN_ILK, "mat", 8 * _RAY);
        assertEq(solvencyEngine.worstCaseLoss(), lossBefore, "raising mat cannot disable the invariant");

        // Lowering mat must not fabricate a breach either.
        priceConverter.file(RAIN_ILK, "mat", 2 * _RAY);
        assertEq(solvencyEngine.worstCaseLoss(), lossBefore, "lowering mat cannot fabricate loss");
    }

    function test_worstCaseLossFailsClosedOnUnavailablePrice() public {
        _setRainPrice(1e18);
        _openVault(user, 800e18, 200e18);

        assertEq(solvencyEngine.worstCaseLoss(), 60e18, "priced loss");

        // Void the feed: collateral is valued at zero and the FULL debt becomes the loss (fail closed).
        osm.void(RAIN_ILK);

        assertEq(solvencyEngine.worstCaseLoss(), 200e18, "no price = zero collateral value");
    }

    /* ========================== 2. LAZY REDEMPTION GATE ========================== */

    function test_redemptionGateHoldsWithoutAnyKeeper() public {
        // Price collapse with the keeper dead: buyStable itself must detect the breach.
        _setRainPrice(1e18);
        _openVault(user, 800e18, 200e18);
        _sellUsdt(keeper, 20e6);

        // NOTE: No checkInvariant call anywhere. The stale flag says healthy.
        assertFalse(solvencyEngine.breached(), "flag stale-healthy");

        vm.startPrank(keeper);
        usdr.approve(address(psm), 5e18);
        vm.expectRevert(SolvencyGateActive.selector);
        psm.buyStable(USDT_ILK, keeper, 5e6);
        vm.stopPrank();

        // NOTE: The revert rolls the recompute back with the rest of the transaction, the persistent flag is still
        // refreshed by keepers and by any SUCCESSFUL redemption; what the lazy gate guarantees is that no redemption
        // can ever pass on stale data, which the revert above just proved.
        assertFalse(solvencyEngine.breached(), "flag untouched by the reverted attempt");
    }

    /* ========================== 3. PARAMETER BOUNDS ========================== */

    function test_stressParameterBounds() public {
        vm.expectRevert(ISolvencyEngine.ParameterOutOfBounds.selector);
        solvencyEngine.file("stressMarkdown", 0);

        vm.expectRevert(ISolvencyEngine.ParameterOutOfBounds.selector);
        solvencyEngine.file("stressMarkdown", _WAD + 1);

        vm.expectRevert(ISolvencyEngine.ParameterOutOfBounds.selector);
        solvencyEngine.file("stressDepth", 0);

        vm.expectRevert(ISolvencyEngine.ParameterOutOfBounds.selector);
        solvencyEngine.file("reserveFactor", 0);

        vm.expectRevert(ISolvencyEngine.ParameterOutOfBounds.selector);
        solvencyEngine.file("reserveFactor", _WAD + 1);

        // Boundary values pass.
        solvencyEngine.file("stressMarkdown", _WAD);
        solvencyEngine.file("reserveFactor", _WAD);
    }

    /* ========================== 4. VOLATILE ILK VALIDATION ========================== */

    function test_addVolatileIlkValidatesExistence() public {
        vm.expectRevert();
        solvencyEngine.addVolatileIlk("GHOST-A");

        // A real ilk registers fine (and duplicates revert).
        vaultEngine.init("NEW-A");
        solvencyEngine.addVolatileIlk("NEW-A");

        vm.expectRevert();
        solvencyEngine.addVolatileIlk("NEW-A");

        // Removal restores a clean slate.
        solvencyEngine.removeVolatileIlk("NEW-A");
        assertFalse(solvencyEngine.isVolatile("NEW-A"), "removed");
    }

    /* ========================== 5. ESCROW GUARD ========================== */

    function test_recordDecreaseCannotBreachEscrow() public {
        _setRainPrice(1e18);
        _openVault(user, 800e18, 200e18);
        _sellUsdt(keeper, 100e6);

        // Commit the full reserve as escrow via a breach-level loss.
        solvencyEngine.checkInvariant();

        uint256 escrow = reserveAccounting.committedEscrow();
        assertGt(escrow, 0, "escrow committed");

        // A recorder trying to draw the reserve below the escrow must revert.
        vm.prank(address(psm));
        vm.expectRevert(IReserveAccounting.ReserveBelowEscrow.selector);
        reserveAccounting.recordDecrease(100e18);
    }

    /* ========================== 6. EXTERNAL EXPOSURE ========================== */

    function test_exposureCountedAtFaceValue() public {
        // Wiring a reporter takes no companion parameter: exposure is consumed exactly as reported, so there is no
        // ordering to get wrong and no cap that can silently shrink the number.
        MockExternalExposure exposure = new MockExternalExposure();
        solvencyEngine.file("externalExposure", address(exposure));

        exposure.setExposure(10e18);
        assertEq(solvencyEngine.worstCaseLoss(), 10e18, "real exposure counted");

        // Large reports are counted in full. Suppressing exposure the protocol has actually taken on would
        // under-size the settlement escrow and hide a breach from the gates.
        exposure.setExposure(1_000_000e18);
        assertEq(solvencyEngine.worstCaseLoss(), 1_000_000e18, "counted in full, never clamped");

        // Unwiring the reporter drops the term entirely.
        solvencyEngine.file("externalExposure", address(0));
        assertEq(solvencyEngine.worstCaseLoss(), 0, "no reporter, no exposure term");
    }

    /* ========================== 7. PSM EDGES ========================== */

    function test_psmZeroAmountAndUnknownIlkRevert() public {
        vm.expectRevert(InvalidAmount.selector);
        psm.sellStable(USDT_ILK, user, 0);

        vm.expectRevert();
        psm.sellStable("GHOST-A", user, 1e6);

        vm.expectRevert(InvalidAmount.selector);
        psm.buyStable(USDT_ILK, user, 0);
    }

    function test_redemptionBoundedByFreeSlack() public {
        _sellUsdt(keeper, 100e6);

        // Manually commit most of the reserve so slack is thin.
        _setRainPrice(1e18);
        _openVault(user, 800e18, 200e18);
        solvencyEngine.checkInvariant();

        uint256 slack = reserveAccounting.freeSlack();
        assertEq(slack, 40e18, "reserve 100 - escrow 60");

        // Redeeming more than slack reverts (breach flag is off here: loss 60 <= threshold 90).
        vm.startPrank(keeper);
        usdr.approve(address(psm), 50e18);
        vm.expectRevert(IPegStabilityModule.InsufficientFreeSlack.selector);
        psm.buyStable(USDT_ILK, keeper, 50e6);

        // Redeeming within slack succeeds.
        usdr.approve(address(psm), 40e18);
        psm.buyStable(USDT_ILK, keeper, 40e6);
        vm.stopPrank();
    }

    /* ========================== 8. SOLVENCY GATE HOOKS ========================== */

    function test_frobHardGateHoldsWithoutAnyKeeper() public {
        // No reserve at all. The FIRST draw passes: the gate recomputes on pre-frob state, where loss is still 0.
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 800e18, 200e18);

        // Now the ilk carries a stressed loss of 60 against a zero reserve.
        // NOTE: No checkInvariant call anywhere, the stale flag still says healthy and frob itself must detect the
        // breach.
        assertFalse(solvencyEngine.breached(), "flag stale-healthy");

        // Drawing more debt is blocked.
        vm.prank(user);
        vm.expectRevert(SolvencyGateActive.selector);
        vaultEngine.frob(vaultId, user, user, 0, 1);

        // Withdrawing collateral is blocked too.
        vm.prank(user);
        vm.expectRevert(SolvencyGateActive.selector);
        vaultEngine.frob(vaultId, user, user, -1, 0);

        // Risk-DECREASING changes always stay available: repayment and top-ups must never be gated (death-spiral
        // ).
        vm.prank(user);
        vaultEngine.frob(vaultId, user, user, 0, -int256(50e18));

        rain.mint(user, 10e18);
        vm.startPrank(user);
        rain.approve(address(collateralAdapter), 10e18);
        collateralAdapter.join(RAIN_ILK, user, 10e18);
        vaultEngine.frob(vaultId, user, user, int256(10e18), 0);
        vm.stopPrank();
    }

    function test_frobGateClearsOnceReserveCovers() public {
        // 199 of debt against 800 RAIN leaves mat headroom for one more 1-USDR draw (cap at spot 0.25 is 200).
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 800e18, 199e18);

        // Blocked against an empty reserve (stressed loss 199 - 70 = 129 > 0).
        vm.prank(user);
        vm.expectRevert(SolvencyGateActive.selector);
        vaultEngine.frob(vaultId, user, user, 0, int256(1e18));

        // Seeding the reserve past the stressed loss (129 / 0.9 ~ 144) reopens the gate with no keeper involved.
        _sellUsdt(keeper, 150e6);

        vm.prank(user);
        vaultEngine.frob(vaultId, user, user, 0, int256(1e18));
    }

    function test_distributeSurplusHardGateBlocksWhileBreached() public {
        balanceSheet.file("humpFloor", 1 * _RAD);
        balanceSheet.file("buybackReceiver", address(0xB0B));

        // A stressed loss of 60 against an empty reserve: breached. Surplus sits above target.
        _setRainPrice(1e18);
        _openVault(user, 800e18, 200e18);
        vaultEngine.suck(address(this), address(balanceSheet), 10 * _RAD);

        // NOTE: Stale flag says healthy; distributeSurplus recomputes and must refuse to ship value out.
        assertFalse(solvencyEngine.breached(), "flag stale-healthy");

        vm.expectRevert(SolvencyGateActive.selector);
        balanceSheet.distributeSurplus();

        // Once the reserve covers the stressed loss, distribution flows again.
        _sellUsdt(keeper, 100e6);

        assertEq(balanceSheet.distributeSurplus(), 9 * _RAD, "released after recovery");
    }

    function test_pokeSoftRefreshFlagsBreachWithoutReverting() public {
        // Healthy at $1: loss 60 <= threshold 90.
        _setRainPrice(1e18);
        _openVault(user, 800e18, 200e18);
        _sellUsdt(keeper, 100e6);

        solvencyEngine.checkInvariant();
        assertFalse(solvencyEngine.breached(), "healthy at 1.0");

        // The crash arrives through the feed. The pokes themselves must refresh the flag: no keeper, no checkInvariant
        // call. At $0.2 the loss is 200 - 800*0.2*0.175 = 172 > 90.
        _setRainPrice(0.2e18);

        assertTrue(solvencyEngine.breached(), "poke surfaced the breach");

        // And the poke path itself stayed alive through the breach (the refresh is soft): another poke works.
        _setRainPrice(0.19e18);
    }

    function test_dripSoftRefreshFlagsBreachWithoutReverting() public {
        // Healthy but tight: loss 60, reserve 68, threshold 61.2.
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 800e18, 200e18);
        _sellUsdt(keeper, 68e6);

        solvencyEngine.checkInvariant();
        assertFalse(solvencyEngine.breached(), "healthy before accrual");

        // ~10% APY. A year of fees pushes the debt to ~220 and the loss to ~80 > 61.2: accrual alone must surface the
        // breach, with no keeper and no user action.
        vaultEngine.file(RAIN_ILK, "duty", 1000000003022265980097387650);
        vm.warp(vm.getBlockTimestamp() + 365 days);

        vaultEngine.drip(RAIN_ILK);

        assertTrue(solvencyEngine.breached(), "drip surfaced the breach");

        // The gate downstream now holds: risk-increasing frobs are blocked, repayment is not.
        vm.prank(user);
        vm.expectRevert(SolvencyGateActive.selector);
        vaultEngine.frob(vaultId, user, user, 0, int256(1e18));

        vm.prank(user);
        vaultEngine.frob(vaultId, user, user, 0, -int256(1e18));
    }

    /* ========================== 9. FUZZ ========================== */

    function testFuzz_psmRoundTripAlwaysExact(uint32 amtSeed) public {
        uint256 amt = (uint256(amtSeed) % 400_000e6) + 1;

        _sellUsdt(user, amt);
        assertEq(usdr.balanceOf(user), amt * 1e12, "1:1 in");

        vm.startPrank(user);
        usdr.approve(address(psm), amt * 1e12);
        psm.buyStable(USDT_ILK, user, amt);
        vm.stopPrank();

        assertEq(usdt.balanceOf(user), amt, "1:1 out");
        assertEq(reserveAccounting.totalReserve(), 0, "reserve fully unwound");
    }
}

/* ========================== RESERVE AUDIT REGRESSIONS ========================== */

/**
 * @title ReserveRegressionTest
 * @author Rain Team
 * @notice Regression tests exercising the reserve stack: PSM round trips, the solvency invariant and gate, external
 *         exposure clamping, sin queue timing and surplus distribution around the hump.
 */
contract ReserveRegressionTest is BaseTest {
    /* ========================== HELPERS ========================== */

    /// @dev Pushes `price` [wad] through the OSM (two pokes) and into the Vault Engine's spot.
    function _setRainPrice(uint256 price) internal {
        rainPriceSource.setPrice(price);
        // The OSM snaps its delay anchor down to the HOP boundary, so warp to fresh boundaries. Read the clock via the
        // cheatcode: the compiler may otherwise rematerialize a stale block.timestamp across warps under via-ir.
        vm.warp(((vm.getBlockTimestamp() / 1800) + 2) * 1800);
        osm.poke(RAIN_ILK);
        vm.warp(vm.getBlockTimestamp() + 3600);
        osm.poke(RAIN_ILK);
        priceConverter.poke(RAIN_ILK);
    }

    /// @dev Opens a fresh RAIN vault for `who` with `ink` collateral and `art` debt (rate is RAY).
    function _openVault(address who, uint256 ink, uint256 art) internal returns (uint256 vaultId) {
        rain.mint(who, ink);

        vm.startPrank(who);
        rain.approve(address(collateralAdapter), ink);
        collateralAdapter.join(RAIN_ILK, who, ink);
        vaultId = vaultEngine.open(RAIN_ILK, who);
        vaultEngine.frob(vaultId, who, who, int256(ink), int256(art));
        vm.stopPrank();
    }

    /// @dev Mints `amt` USDT (6 decimals) to `who` and sells it through the PSM for USDR.
    function _sellUsdt(address who, uint256 amt) internal {
        usdt.mint(who, amt);

        vm.startPrank(who);
        usdt.approve(address(psm), amt);
        psm.sellStable(USDT_ILK, who, amt);
        vm.stopPrank();
    }

    /* ========================== 1. PSM ROUND TRIP ========================== */

    function test_psmRoundTripExactOneToOne() public {
        _sellUsdt(user, 100e6);

        // Exactly 1:1, no fee.
        assertEq(usdr.balanceOf(user), 100e18, "sell: exact USDR out");
        assertEq(reserveAccounting.totalReserve(), 100e18, "sell: reserve exact");

        vm.startPrank(user);
        usdr.approve(address(psm), 40e18);
        psm.buyStable(USDT_ILK, user, 40e6);
        vm.stopPrank();

        assertEq(usdr.balanceOf(user), 60e18, "buy: exact USDR in");
        assertEq(usdt.balanceOf(user), 40e6, "buy: exact stable out");
        assertEq(reserveAccounting.totalReserve(), 60e18, "buy: reserve exact");

        // No stranded balances on the PSM.
        assertEq(vaultEngine.usdr(address(psm)), 0, "no stranded internal usdr");
        assertEq(usdr.balanceOf(address(psm)), 0, "no stranded USDR");
    }

    /* ========================== 2. SOLVENCY ========================== */

    function test_solvencyBreachGatesAndRestores() public {
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 800e18, 200e18);

        // Loss = 200 - 800 * 0.5 * 0.35 = 60 USDR. Reserve = 20 -> threshold 18 -> breached.
        _sellUsdt(keeper, 20e6);

        (uint256 loss, uint256 reserve) = solvencyEngine.checkInvariant();
        assertEq(loss, 60e18, "worst-case loss priced from collateral");
        assertEq(reserve, 20e18, "reserve");
        assertTrue(solvencyEngine.breached(), "breached");

        // Risk-increasing frob is gated.
        vm.prank(user);
        vm.expectRevert(SolvencyGateActive.selector);
        vaultEngine.frob(vaultId, user, user, 0, 1e18);

        // Repayment stays open.
        vm.prank(user);
        vaultEngine.frob(vaultId, user, user, 0, -1e18);

        // Redemption recomputes the invariant lazily (no stale-flag window): while the reserve is still thin the gate
        // holds even without any keeper call.
        vm.startPrank(keeper);
        usdr.approve(address(psm), 5e18);
        vm.expectRevert(SolvencyGateActive.selector);
        psm.buyStable(USDT_ILK, keeper, 5e6);
        vm.stopPrank();

        // Reserve-increasing PSM flow stays open. Reserve becomes 100 -> threshold 90 > loss (59 after the wipe), and
        // the next redemption's lazy recompute clears the breach by itself, again no keeper needed.
        _sellUsdt(keeper, 80e6);

        vm.startPrank(keeper);
        usdr.approve(address(psm), 5e18);
        psm.buyStable(USDT_ILK, keeper, 5e6);
        vm.stopPrank();

        assertFalse(solvencyEngine.breached(), "restored by lazy recompute");

        vm.prank(user);
        vaultEngine.frob(vaultId, user, user, 0, 1e18);
    }

    function test_worstCaseLossScalesWithCollateral() public {
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 400e18, 100e18);

        uint256 lossAt400 = solvencyEngine.worstCaseLoss();
        assertEq(lossAt400, 30e18, "400% collateralized loss");

        // Same debt at 1000% collateralization must produce a smaller (here zero) loss.
        rain.mint(user, 600e18);
        vm.startPrank(user);
        rain.approve(address(collateralAdapter), 600e18);
        collateralAdapter.join(RAIN_ILK, user, 600e18);
        vaultEngine.frob(vaultId, user, user, int256(600e18), 0);
        vm.stopPrank();

        uint256 lossAt1000 = solvencyEngine.worstCaseLoss();
        assertEq(lossAt1000, 0, "1000% collateralized loss");
        assertLt(lossAt1000, lossAt400, "loss scales with collateral");
    }

    function test_externalExposureFaceValueAndFailClosedFallback() public {
        _setRainPrice(1e18);
        _openVault(user, 800e18, 200e18);

        uint256 volatileLoss = 60e18; // 200 debt - 800 * 0.5 * 0.35.
        assertEq(solvencyEngine.worstCaseLoss(), volatileLoss, "baseline with no reporter wired");

        MockExternalExposure exposure = new MockExternalExposure();
        solvencyEngine.file("externalExposure", address(exposure));

        // Exposure lands on top of the volatile loss at face value. NOTE: a type(uint256).max report now overflows
        // the sum rather than being absorbed by a clamp; the reporter settles in USDR it cannot mint, so only
        // representable exposure is in scope.
        exposure.setExposure(1_000_000e18);
        assertEq(solvencyEngine.worstCaseLoss(), volatileLoss + 1_000_000e18, "counted in full");

        // An unreachable reporter substitutes outstanding debt instead of bricking the invariant or reading zero:
        // every USDR that could be exposed was minted here, so total debt is the structural ceiling.
        exposure.setShouldRevert(true);
        assertEq(vaultEngine.debt(), 200 * _RAD, "debt baseline");
        assertEq(solvencyEngine.worstCaseLoss(), volatileLoss + 200e18, "fails closed at outstanding debt");

        // checkInvariant never reverts, and it surfaces the substitution for monitoring.
        vm.expectEmit(false, false, false, true);
        emit ISolvencyEngine.ExposureReportFailed(200e18);
        solvencyEngine.checkInvariant();
    }

    /* ========================== 3. FESS / FLOG / HEAL ========================== */

    function test_fessQueuesSinAndFlogReleasesAfterWait() public {
        balanceSheet.file("wait", 561600);

        // Creating matching surplus and bad debt on the balance sheet.
        vaultEngine.suck(address(balanceSheet), address(balanceSheet), 50 * _RAD);
        balanceSheet.fess(50 * _RAD);

        // Using the cheatcode (not block.timestamp) so via-ir cannot rematerialize the value after the warp below.
        uint256 era = vm.getBlockTimestamp();

        // Queued sin cannot be healed.
        vm.expectRevert(IBalanceSheet.InsufficientDebt.selector);
        balanceSheet.heal(50 * _RAD);

        // The queue cannot be released before the wait elapses.
        vm.expectRevert(IBalanceSheet.WaitNotElapsed.selector);
        balanceSheet.flog(era);

        // After the wait, flog releases the era and heal works.
        vm.warp(era + 561600);
        balanceSheet.flog(era);
        assertEq(balanceSheet.totalQueuedSin(), 0, "queue drained");

        balanceSheet.heal(50 * _RAD);
        assertEq(vaultEngine.sin(address(balanceSheet)), 0, "healed");
    }

    /* ========================== 4. DISTRIBUTE SURPLUS AROUND HUMP ========================== */

    function test_distributeSurplusBelowHumpReturnsZero() public {
        balanceSheet.file("humpFloor", 1000 * _RAD);
        balanceSheet.file("buybackReceiver", address(0xB0B));

        // Surplus (without bad debt on the balance sheet) below the target.
        vaultEngine.suck(address(this), address(balanceSheet), 10 * _RAD);

        uint256 excess = balanceSheet.distributeSurplus();
        assertEq(excess, 0, "no-op below target");
        assertEq(vaultEngine.usdr(address(balanceSheet)), 10 * _RAD, "surplus untouched");
    }

    function test_distributeSurplusAboveHumpReleasesExcess() public {
        balanceSheet.file("humpFloor", 10 * _RAD);
        balanceSheet.file("buybackReceiver", address(0xB0B));

        vaultEngine.suck(address(this), address(balanceSheet), 25 * _RAD);

        uint256 excess = balanceSheet.distributeSurplus();
        assertEq(excess, 15 * _RAD, "excess above target released");
        assertEq(vaultEngine.usdr(address(0xB0B)), 15 * _RAD, "receiver credited");
    }

    /* ========================== 5. PSM FEE EXEMPTION ========================== */

    function test_dutyOnStableIlkIsRejected() public {
        // Regression: the PSM's 1:1 accounting is only sound at rate == RAY. The stable ilks are fee-exempt from
        // BaseTest wiring (as in deploy), so ANY duty above RAY — including the minimal RAY + 1 — must be rejected.
        vm.expectRevert(InvalidDuty.selector);
        vaultEngine.file(USDT_ILK, "duty", _RAY + 1);

        vm.expectRevert(InvalidDuty.selector);
        vaultEngine.file(USDC_ILK, "duty", 1000000001547125957863212448);

        // Refiling the zero-fee duty is a legal no-op.
        vaultEngine.file(USDT_ILK, "duty", _RAY);
    }

    function test_psmRoundTripStaysExactAfterYearsAndDrips() public {
        // The blast radius, inverted: with the exemption in place, drips over long horizons
        // must leave the PSM's round trip bit-exact — the broken scenario redeemed 0 of 100,000.
        _sellUsdt(user, 100_000e6);

        skip(3650 days);

        vaultEngine.drip(USDT_ILK);

        (, , uint256 rate, , , , , ) = vaultEngine.ilks(USDT_ILK);
        assertEq(rate, _RAY, "stable rate pinned at RAY after 10 years");

        // Full redemption succeeds to the last unit.
        vm.startPrank(user);
        usdr.approve(address(psm), 100_000e18);
        psm.buyStable(USDT_ILK, user, 100_000e6);
        vm.stopPrank();

        assertEq(usdt.balanceOf(user), 100_000e6, "100% redeemable");
        assertEq(reserveAccounting.totalReserve(), 0, "reserve fully unwound");
    }

    function test_psmInitRequiresFeeExemptIlk() public {
        // A new stable ilk that is NOT fee-exempt must be refused by PSM.init: registration is where the fee-exemption
        // invariant is anchored, so it can never be forgotten in a later deploy.
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);
        bytes32 daiIlk = "DAI-A";

        collateralAdapter.init(daiIlk, IERC20Metadata(address(dai)));
        vaultEngine.init(daiIlk);

        vm.expectRevert(IPegStabilityModule.StableIlkNotFeeExempt.selector);
        psm.init(daiIlk);

        // Exempting it makes registration pass.
        vaultEngine.exemptFee(daiIlk);
        psm.init(daiIlk);

        (, , uint256 vaultId) = psm.ilks(daiIlk);
        assertGt(vaultId, 0, "registered once exempt");
    }

    /* ========================== 6. RESERVE BACKING NET ========================== */

    function test_distributeRevertsWhenReserveNoLongerBacksStableDebt() public {
        // System-level net: if the stable reserve ever stops covering the PSM ilks' debt — unbacked
        // USDR exists — no surplus may leave toward the buyback. The primary fee-exemption guard makes the fee path
        // unreachable, so the imbalance is simulated directly on the reserve ledger.
        balanceSheet.file("reserveAccounting", address(reserveAccounting));
        balanceSheet.file("buybackReceiver", address(0xB0B));

        _sellUsdt(user, 1_000e6);

        vaultEngine.suck(address(this), address(balanceSheet), 100 * _RAD);

        // Healthy state distributes fine (hump target 0).
        assertEq(balanceSheet.distributeSurplus(), 100 * _RAD, "backed distribution passes");

        // The reserve shrinks with NO matching PSM debt change: stable debt (1000) > reserve (600).
        reserveAccounting.grantRole(_RECORDER_ROLE, address(this));
        reserveAccounting.recordDecrease(400e18);

        vaultEngine.suck(address(this), address(balanceSheet), 50 * _RAD);

        vm.expectRevert(IBalanceSheet.ReserveBackingShortfall.selector);
        balanceSheet.distributeSurplus();

        // Restoring the backing restores distribution.
        reserveAccounting.recordIncrease(400e18);
        assertEq(balanceSheet.distributeSurplus(), 50 * _RAD, "distribution resumes once backed");
    }

    /* ========================== 7. HUMP TARGET GAMING ========================== */

    function test_humpTargetCannotBeShrunkBySameWindowRedemption() public {
        // Regression: the dynamic hump term used to read the LIVE reserve, so redeem-shrink-distribute in one
        // transaction lowered the target and drained extra surplus. The term now reads max(live, lagged snapshot).
        balanceSheet.file("reserveAccounting", address(reserveAccounting));
        balanceSheet.file("buybackReceiver", address(0xB0B));
        balanceSheet.file("humpRate", _WAD / 10);

        // Reserve 200k -> dynamic target 20k [rad]. Snapshot it (one lag window must have elapsed since genesis).
        _sellUsdt(user, 200_000e6);
        skip(1 days);
        balanceSheet.snapshotReserve();
        assertEq(balanceSheet.laggedReserve(), 200_000e18, "snapshot taken");

        uint256 target = balanceSheet.humpTarget();
        assertEq(target, 20_000e18 * _RAY, "10% of reserve");

        // The attacker redeems 150k in the same window: the live reserve drops to 50k, but the target must not.
        vm.startPrank(user);
        usdr.approve(address(psm), 150_000e18);
        psm.buyStable(USDT_ILK, user, 150_000e6);
        vm.stopPrank();

        assertEq(balanceSheet.humpTarget(), target, "target unchanged by same-window outflow");

        // Surplus of 20,300: only 300 above the un-gamed target may leave.
        vaultEngine.suck(address(this), address(balanceSheet), 20_300e18 * _RAY);
        assertEq(balanceSheet.distributeSurplus(), 300e18 * _RAY, "drain capped by the lagged target");

        // Growth takes effect immediately (max semantics): selling stables in RAISES the target with no lag
        // (reserve 50k + 250k = 300k -> 30k target).
        _sellUsdt(user, 250_000e6);
        assertEq(balanceSheet.humpTarget(), 30_000e18 * _RAY, "growth is instant");

        // Shrinkage only lands after the lag window, via a fresh snapshot (300k - 200k = 100k live).
        vm.startPrank(user);
        usdr.approve(address(psm), 200_000e18);
        psm.buyStable(USDT_ILK, user, 200_000e6);
        vm.stopPrank();

        balanceSheet.snapshotReserve();
        assertEq(balanceSheet.laggedReserve(), 200_000e18, "same-window snapshot refused");

        skip(1 days);
        balanceSheet.snapshotReserve();
        assertEq(balanceSheet.laggedReserve(), 100_000e18, "shrinkage lands after the lag");
        assertEq(balanceSheet.humpTarget(), 10_000e18 * _RAY, "target follows after the lag");
    }

    function test_backstopSellsTreasuryRainAndHealsSin() public {
        // Fresh OSM price for the RAIN sale.
        rainPriceSource.setPrice(1e18);
        vm.warp(((vm.getBlockTimestamp() / 1800) + 2) * 1800);
        osm.poke(RAIN_ILK);
        vm.warp(vm.getBlockTimestamp() + 3600);
        osm.poke(RAIN_ILK);

        // Unqueued bad debt with no surplus on the balance sheet.
        vaultEngine.suck(address(balanceSheet), address(this), 10 * _RAD);
        assertEq(vaultEngine.usdr(address(balanceSheet)), 0, "no surplus");
        assertEq(vaultEngine.sin(address(balanceSheet)), 10 * _RAD, "sin outstanding");

        // Treasury RAIN: join into the Balance Sheet's free collateral.
        uint256 rainAmt = 20e18;
        rain.mint(address(this), rainAmt);
        rain.approve(address(collateralAdapter), rainAmt);
        collateralAdapter.join(RAIN_ILK, address(balanceSheet), rainAmt);

        // Buyer hopes the Balance Sheet so it can pull USDR, then calls backstop.
        vaultEngine.hope(address(balanceSheet));

        uint256 rainBefore = vaultEngine.collateral(RAIN_ILK, address(this));
        uint256 rainSold = balanceSheet.backstop(10 * _RAD);

        // At $1 and 90% haircut, 10 USDR buys ceil(10 / 0.9) RAIN.
        assertEq(rainSold, (10e18 * _WAD + ((_WAD * 90) / 100) - 1) / ((_WAD * 90) / 100), "RAIN priced at haircut");
        assertEq(vaultEngine.sin(address(balanceSheet)), 0, "sin healed");
        assertEq(vaultEngine.usdr(address(balanceSheet)), 0, "USDR consumed");
        assertEq(balanceSheet.backstopUsed(), 10 * _RAD, "cap consumed");
        assertEq(vaultEngine.collateral(RAIN_ILK, address(this)), rainBefore + rainSold, "buyer received RAIN");

        // No further hole → backstop refuses.
        vm.expectRevert(IBalanceSheet.BackstopNotNeeded.selector);
        balanceSheet.backstop(1 * _RAD);
    }

    /* ========================== 8. EXPOSURE ESCROW COMMITMENT ========================== */

    function test_exposureCommitsEscrowAndStarvesRedemption() public {
        // There used to be a fail-open in the (now removed) cap setter: zeroing the cap behind a wired reporter reduced
        // exposure to nothing. Without a cap there is no knob to zero, so what is left to protect is the downstream
        // effect the cap used to distort: reported exposure must fully reserve reserve capital.
        _sellUsdt(keeper, 100_000e6);

        MockExternalExposure exposure = new MockExternalExposure();
        solvencyEngine.file("externalExposure", address(exposure));

        exposure.setExposure(40_000e18);
        solvencyEngine.checkInvariant();

        assertEq(reserveAccounting.committedEscrow(), 40_000e18, "exposure escrowed in full");
        assertEq(reserveAccounting.freeSlack(), 60_000e18, "only the remainder is redeemable");

        // Unwiring the reporter releases the escrow on the next check.
        solvencyEngine.file("externalExposure", address(0));
        solvencyEngine.checkInvariant();

        assertEq(reserveAccounting.committedEscrow(), 0, "escrow released");
        assertEq(reserveAccounting.freeSlack(), 100_000e18, "reserve fully redeemable again");
    }
}
