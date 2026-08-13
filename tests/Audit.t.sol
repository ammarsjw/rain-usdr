// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IPegStabilityModule } from "../contracts/interfaces/IPegStabilityModule.sol";
import { ILiquidationTrigger } from "../contracts/interfaces/ILiquidationTrigger.sol";
import { IBalanceSheet } from "../contracts/interfaces/IBalanceSheet.sol";
import { IVaultEngine } from "../contracts/interfaces/IVaultEngine.sol";
import { SolvencyGateActive } from "../contracts/shared/Errors.sol";
import { _RAD, _RAY, _USDR_ILK, _WAD } from "../contracts/shared/Constants.sol";

import { BaseTest } from "./Base.t.sol";
import { MockExternalExposure } from "./mocks/MockExternalExposure.sol";

/**
 * @title AuditTest
 * @author Rain Team
 * @notice Starter regression suite for the rev2 audit fixes (H-1).
 */
contract AuditTest is BaseTest {
    /* ========================== HELPERS ========================== */

    /// @dev Pushes `price` [wad] through the OSM (two pokes) and into the Vault Engine's spot.
    function _setRainPrice(uint256 price) internal {
        rainPriceSource.setPrice(price);
        // The OSM snaps its delay anchor down to the HOP boundary, so warp to fresh boundaries. Read the clock via
        // the cheatcode: the compiler may otherwise rematerialize a stale block.timestamp across warps under via-ir.
        vm.warp(((vm.getBlockTimestamp() / 1800) + 2) * 1800);
        osm.poke(RAIN_ILK);
        vm.warp(vm.getBlockTimestamp() + 3600);
        osm.poke(RAIN_ILK);
        priceConverter.poke(RAIN_ILK);
    }

    /// @dev Opens a RAIN vault for `who` with `ink` collateral and `art` debt (rate is RAY).
    function _openVault(address who, uint256 ink, uint256 art) internal {
        rain.mint(who, ink);

        vm.startPrank(who);
        rain.approve(address(collateralAdapter), ink);
        collateralAdapter.join(RAIN_ILK, who, ink);
        vaultEngine.frob(RAIN_ILK, who, who, who, int256(ink), int256(art));
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

    /* ========================== 2. CDP AT MAT ========================== */

    function test_frobDrawAtExactlyMatSucceedsAboveFails() public {
        _setRainPrice(1e18);

        // 400 RAIN at $1 with 400% mat allows exactly 100 USDR.
        _openVault(user, 400e18, 100e18);

        (, uint256 art) = vaultEngine.urns(RAIN_ILK, user);
        assertEq(art, 100e18, "draw at exactly mat");

        // One wei of extra debt breaks the safety check.
        vm.prank(user);
        vm.expectRevert(IVaultEngine.NotSafe.selector);
        vaultEngine.frob(RAIN_ILK, user, user, user, 0, 1);

        // Wipe works.
        vm.prank(user);
        vaultEngine.frob(RAIN_ILK, user, user, user, 0, -100e18);

        (, art) = vaultEngine.urns(RAIN_ILK, user);
        assertEq(art, 0, "wipe clears debt");
    }

    /* ========================== 3. BARK THRESHOLD ========================== */

    function test_barkThresholdAt65PercentOfMat() public {
        _setRainPrice(1e18);
        _openVault(user, 400e18, 100e18);

        // At 66% of the required ratio the vault is NOT barkable.
        _setRainPrice(0.66e18);
        vm.expectRevert(ILiquidationTrigger.NotUnsafe.selector);
        liquidationTrigger.bark(RAIN_ILK, user, keeper);

        // Below 65% it is barkable.
        _setRainPrice(0.64e18);
        uint256 id = liquidationTrigger.bark(RAIN_ILK, user, keeper);
        assertEq(id, 1, "auction started");
    }

    /* ========================== 4. DART PRECISION (H-3) ========================== */

    function test_barkDartPrecisionMakerOrdering() public {
        _setRainPrice(1e18);
        _openVault(user, 1600e18, 400e18);

        // Limiting room to force a partial liquidation.
        liquidationTrigger.file(RAIN_ILK, "hole", 150 * _RAD);
        _setRainPrice(0.6e18);

        liquidationTrigger.bark(RAIN_ILK, user, keeper);

        // Maker's ordering: dart = room * WAD / rate / chop, computed before flooring by rate.
        uint256 expectedDart = ((150 * _RAD) * _WAD) / _RAY / ((_WAD * 113) / 100);
        (, uint256 art) = vaultEngine.urns(RAIN_ILK, user);

        assertGt(expectedDart, 0, "dart nonzero");
        assertEq(art, 400e18 - expectedDart, "dart correctly scaled");
    }

    /* ========================== 5. SOLVENCY ========================== */

    function test_solvencyBreachGatesAndRestores() public {
        _setRainPrice(1e18);
        _openVault(user, 800e18, 200e18);

        // Loss = 200 - 800 * 0.5 * 0.35 = 60 USDR. Reserve = 20 -> threshold 18 -> breached.
        _sellUsdt(keeper, 20e6);

        (uint256 loss, uint256 reserve) = solvencyEngine.checkInvariant();
        assertEq(loss, 60e18, "worst-case loss priced from collateral");
        assertEq(reserve, 20e18, "reserve");
        assertTrue(solvencyEngine.breached(), "breached");

        // Risk-increasing frob is gated.
        vm.prank(user);
        vm.expectRevert(SolvencyGateActive.selector);
        vaultEngine.frob(RAIN_ILK, user, user, user, 0, 1e18);

        // Repayment stays open.
        vm.prank(user);
        vaultEngine.frob(RAIN_ILK, user, user, user, 0, -1e18);

        // Reserve-increasing PSM flow stays open; redemption is gated.
        _sellUsdt(keeper, 80e6);

        vm.startPrank(keeper);
        usdr.approve(address(psm), 5e18);
        vm.expectRevert(SolvencyGateActive.selector);
        psm.buyStable(USDT_ILK, keeper, 5e6);
        vm.stopPrank();

        // Reserve is now 100 -> threshold 90 > loss (59 after the wipe) -> invariant restored.
        solvencyEngine.checkInvariant();
        assertFalse(solvencyEngine.breached(), "restored");

        vm.startPrank(keeper);
        usdr.approve(address(psm), 5e18);
        psm.buyStable(USDT_ILK, keeper, 5e6);
        vm.stopPrank();

        vm.prank(user);
        vaultEngine.frob(RAIN_ILK, user, user, user, 0, 1e18);
    }

    function test_worstCaseLossScalesWithCollateral() public {
        _setRainPrice(1e18);
        _openVault(user, 400e18, 100e18);

        uint256 lossAt400 = solvencyEngine.worstCaseLoss();
        assertEq(lossAt400, 30e18, "400% collateralized loss");

        // Same debt at 1000% collateralization must produce a smaller (here zero) loss.
        rain.mint(user, 600e18);
        vm.startPrank(user);
        rain.approve(address(collateralAdapter), 600e18);
        collateralAdapter.join(RAIN_ILK, user, 600e18);
        vaultEngine.frob(RAIN_ILK, user, user, user, int256(600e18), 0);
        vm.stopPrank();

        uint256 lossAt1000 = solvencyEngine.worstCaseLoss();
        assertEq(lossAt1000, 0, "1000% collateralized loss");
        assertLt(lossAt1000, lossAt400, "loss scales with collateral");
    }

    function test_externalExposureClampAndRevertFallback() public {
        MockExternalExposure exposure = new MockExternalExposure();

        solvencyEngine.file("externalExposure", address(exposure));
        solvencyEngine.file("exposureCap", 7e18);

        // A hostile max-value report is clamped to the cap instead of overflowing.
        exposure.setExposure(type(uint256).max);
        assertEq(solvencyEngine.worstCaseLoss(), 7e18, "clamped to cap");

        // A reverting reporter falls back to the cap instead of bricking the invariant.
        exposure.setShouldRevert(true);
        assertEq(solvencyEngine.worstCaseLoss(), 7e18, "revert falls back to cap");

        // checkInvariant never reverts.
        solvencyEngine.checkInvariant();
    }

    /* ========================== 6. DUTCH AUCTION CHOST ========================== */

    function test_redoPaysNoRewardBelowChost() public {
        _setRainPrice(1e18);
        _openVault(user, 400e18, 100e18);
        _setRainPrice(0.6e18);

        uint256 id = liquidationTrigger.bark(RAIN_ILK, user, keeper);

        // Letting the auction expire, then crashing the price so lot * feedPrice < chost.
        vm.warp(vm.getBlockTimestamp() + 1801);
        _setRainPrice(0.0001e18);

        uint256 before = vaultEngine.usdr(keeper);
        dutchAuction.redo(id, keeper);
        assertEq(vaultEngine.usdr(keeper), before, "no reward below chost");
    }

    function test_redoPaysRewardAboveChost() public {
        _setRainPrice(1e18);
        _openVault(user, 400e18, 100e18);
        _setRainPrice(0.6e18);

        uint256 id = liquidationTrigger.bark(RAIN_ILK, user, keeper);

        vm.warp(vm.getBlockTimestamp() + 1801);
        _setRainPrice(0.6e18);

        uint256 before = vaultEngine.usdr(keeper);
        dutchAuction.redo(id, keeper);
        assertGt(vaultEngine.usdr(keeper), before, "reward above chost");
    }

    function test_takePartialPurchaseAdjustsDownAtChostBoundary() public {
        _setRainPrice(1e18);
        _openVault(user, 800e18, 200e18);
        _setRainPrice(0.6e18);

        uint256 id = liquidationTrigger.bark(RAIN_ILK, user, keeper);
        uint256 chost = dutchAuction.chost();

        (, , , uint256 tab) = dutchAuction.getStatus(id);
        assertEq(tab, 226 * _RAD, "tab = 2x chost");

        // Funding the keeper with internal USDR and permitting the auction to pull it.
        _sellUsdt(keeper, 250e6);
        vm.startPrank(keeper);
        usdr.approve(address(collateralAdapter), 250e18);
        collateralAdapter.join(_USDR_ILK, keeper, 250e18);
        vaultEngine.hope(address(dutchAuction));

        // Requesting a slice whose owe would leave a remainder below chost: the purchase must adjust down to leave
        // exactly chost instead of reverting.
        (, uint256 price, , ) = dutchAuction.getStatus(id);
        uint256 amt = ((tab - chost / 2) / price) + 1;

        dutchAuction.take(id, amt, price, keeper, "");
        vm.stopPrank();

        (, , , uint256 tabAfter) = dutchAuction.getStatus(id);
        assertEq(tabAfter, chost, "remainder adjusted down to exactly chost");
    }

    /* ========================== 7. FESS / FLOG / HEAL ========================== */

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

    /* ========================== 8. DISTRIBUTE SURPLUS BELOW HUMP ========================== */

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
}
