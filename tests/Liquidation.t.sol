// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { CircuitBreaker } from "../contracts/liquidation/CircuitBreaker.sol";
import { IDutchAuction } from "../contracts/interfaces/IDutchAuction.sol";
import { ILiquidationTrigger } from "../contracts/interfaces/ILiquidationTrigger.sol";
import { IOracleSecurityModule } from "../contracts/interfaces/IOracleSecurityModule.sol";
import {
    InvalidAddress,
    InvalidBytes,
    NotLive,
    SystemPaused,
    UnrecognizedParameter
} from "../contracts/shared/Errors.sol";
import { _RAD, _RAY, _USDR_ILK, _WAD } from "../contracts/shared/Constants.sol";

import { BaseTest } from "./shared/BaseTest.sol";
import { MockAuctionCallee } from "./mocks/MockAuctionCallee.sol";

/* ========================== LIQUIDATION TRIGGER ========================== */

/**
 * @title LiquidationTest
 * @author Rain Team
 * @notice Adversarial coverage of the liquidation stack: bark capacity accounting, the M-6 auction breaker and
 *         governance pause, take/redo economics and parameter guards.
 */
contract LiquidationTest is BaseTest {
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

    /// @dev Funds `who` with internal USDR via the PSM and hopes the auction.
    function _fundBidder(address who, uint256 amt6) internal {
        usdt.mint(who, amt6);

        vm.startPrank(who);
        usdt.approve(address(psm), amt6);
        psm.sellStable(USDT_ILK, who, amt6);
        usdr.approve(address(collateralAdapter), amt6 * 1e12);
        collateralAdapter.join(_USDR_ILK, who, amt6 * 1e12);
        vaultEngine.hope(address(dutchAuction));
        vm.stopPrank();
    }

    /* ========================== 1. BARK CAPACITY (hole/dirt) ========================== */

    function test_barkRespectsHoleAndDigsFreesCapacity() public {
        // Both vaults and the bidder are set up BEFORE the crash: _setRainPrice warps hours forward, and the auction
        // must still be fresh (tail = 1800s) when the take executes.
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 800e18, 200e18);
        uint256 second = _openVault(keeper, 400e18, 100e18);
        _fundBidder(address(0xB1D), 300e6);

        _setRainPrice(0.6e18);

        // Room for one full liquidation only.
        liquidationTrigger.file(RAIN_ILK, "hole", 226 * _RAD);

        uint256 id = liquidationTrigger.bark(vaultId, keeper);

        (, , , uint256 dirt, ) = liquidationTrigger.ilks(RAIN_ILK);
        assertEq(dirt, 226 * _RAD, "dirt filled");

        // The second vault cannot bark: no capacity.
        vm.expectRevert(ILiquidationTrigger.LiquidationLimitHit.selector);
        liquidationTrigger.bark(second, keeper);

        // A full take clears the auction and digs the capacity free again.
        (, uint256 price, , ) = dutchAuction.getStatus(id);

        vm.prank(address(0xB1D));
        dutchAuction.take(id, 800e18, price, address(0xB1D), "");

        (, , , dirt, ) = liquidationTrigger.ilks(RAIN_ILK);
        assertEq(dirt, 0, "capacity freed");

        liquidationTrigger.bark(second, keeper);
    }

    function test_barkPaysKickReward() public {
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 400e18, 100e18);
        _setRainPrice(0.6e18);

        uint256 before = vaultEngine.usdr(keeper);
        liquidationTrigger.bark(vaultId, keeper);

        // chip = 2% of tab (113 rad).
        assertEq(vaultEngine.usdr(keeper) - before, (113 * _RAD * 2) / 100, "kick reward");
    }

    /* ========================== 2. BREAKER + PAUSE ========================== */

    function test_stoppedLevelsGateKickTakeRedo() public {
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 400e18, 100e18);
        _setRainPrice(0.6e18);

        // Level 1: no new kicks (bark reverts inside kick).
        dutchAuction.file("stopped", 1);
        vm.expectRevert(IDutchAuction.Stopped.selector);
        liquidationTrigger.bark(vaultId, keeper);

        dutchAuction.file("stopped", 0);
        uint256 id = liquidationTrigger.bark(vaultId, keeper);

        // Level 2: takes stopped.
        dutchAuction.file("stopped", 2);
        _fundBidder(address(0xB1D), 200e6);

        (, uint256 price, , ) = dutchAuction.getStatus(id);
        vm.prank(address(0xB1D));
        vm.expectRevert(IDutchAuction.Stopped.selector);
        dutchAuction.take(id, 400e18, price, address(0xB1D), "");

        // Level 3: redos stopped too.
        dutchAuction.file("stopped", 3);
        vm.warp(vm.getBlockTimestamp() + 1801);
        vm.expectRevert(IDutchAuction.Stopped.selector);
        dutchAuction.redo(id, keeper);

        // Yank is never gated: settlement must always reclaim.
        dutchAuction.yank(id);
    }

    function test_governorPauseStopsAuctionHouse() public {
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 400e18, 100e18);
        _setRainPrice(0.6e18);

        uint256 id = liquidationTrigger.bark(vaultId, keeper);

        // Funding the bidder BEFORE the pause: the PSM is pause-gated too, so this must happen while live.
        _fundBidder(address(0xB1D), 200e6);

        // Pausing: in-flight takes must stop (the rev-4 scenario where keepers extracted collateral at bad-feed prices
        // during a paused incident). The governor is already wired into the auction house in Base.
        governor.pause("all");

        (, uint256 price, , ) = dutchAuction.getStatus(id);
        vm.prank(address(0xB1D));
        vm.expectRevert(SystemPaused.selector);
        dutchAuction.take(id, 400e18, price, address(0xB1D), "");

        // Unpause restores the market.
        governor.unpause();

        vm.prank(address(0xB1D));
        dutchAuction.take(id, 400e18, price, address(0xB1D), "");
    }

    /* ========================== 3. TAKE ECONOMICS ========================== */

    function test_takeRefundsLeftoverCollateralToVaultOwner() public {
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 400e18, 100e18);
        _setRainPrice(0.64e18);

        uint256 id = liquidationTrigger.bark(vaultId, keeper);

        _fundBidder(address(0xB1D), 200e6);

        // Buying the entire tab at the current price leaves collateral over; it returns to the OWNER.
        (, uint256 price, , ) = dutchAuction.getStatus(id);

        vm.prank(address(0xB1D));
        dutchAuction.take(id, 400e18, price, address(0xB1D), "");

        assertGt(vaultEngine.collateral(RAIN_ILK, user), 0, "leftover to owner");

        (, , , uint256 tab) = dutchAuction.getStatus(id);
        assertEq(tab, 0, "auction closed");
    }

    function test_takeAboveMaxPriceReverts() public {
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 400e18, 100e18);
        _setRainPrice(0.6e18);

        uint256 id = liquidationTrigger.bark(vaultId, keeper);

        _fundBidder(address(0xB1D), 200e6);

        (, uint256 price, , ) = dutchAuction.getStatus(id);

        vm.prank(address(0xB1D));
        vm.expectRevert(IDutchAuction.TooExpensive.selector);
        dutchAuction.take(id, 400e18, price - 1, address(0xB1D), "");
    }

    function test_takeNeedsResetAfterTail() public {
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 400e18, 100e18);
        _setRainPrice(0.6e18);

        uint256 id = liquidationTrigger.bark(vaultId, keeper);

        vm.warp(vm.getBlockTimestamp() + 1801);

        (bool needsRedo, uint256 price, , ) = dutchAuction.getStatus(id);
        assertTrue(needsRedo, "stale auction flagged");

        _fundBidder(address(0xB1D), 200e6);

        vm.prank(address(0xB1D));
        vm.expectRevert(IDutchAuction.NeedsReset.selector);
        dutchAuction.take(id, 400e18, price, address(0xB1D), "");
    }

    /* ========================== 4. PARAMETER GUARDS ========================== */

    function test_fileGuards() public {
        // chop below one.
        vm.expectRevert(ILiquidationTrigger.ChopBelowOne.selector);
        liquidationTrigger.file(RAIN_ILK, "chop", _WAD - 1);

        // barkFactor outside (0, 1].
        vm.expectRevert(ILiquidationTrigger.InvalidBarkFactor.selector);
        liquidationTrigger.file(RAIN_ILK, "barkFactor", 0);

        vm.expectRevert(ILiquidationTrigger.InvalidBarkFactor.selector);
        liquidationTrigger.file(RAIN_ILK, "barkFactor", _WAD + 1);

        // L-2: throttle outside (0, 1].
        vm.expectRevert(ILiquidationTrigger.InvalidThrottle.selector);
        liquidationTrigger.file("throttle", 0);

        vm.expectRevert(ILiquidationTrigger.InvalidThrottle.selector);
        liquidationTrigger.file("throttle", _WAD + 1);

        liquidationTrigger.file("throttle", _WAD / 4);
        assertEq(liquidationTrigger.throttle(), _WAD / 4, "throttle set");
    }

    function test_upchostTracksDustTimesChop() public {
        assertEq(dutchAuction.chost(), ((100 * _RAD * 113) / 100 / _WAD) * _WAD, "launch chost");

        vaultEngine.file(RAIN_ILK, "dust", 200 * _RAD);
        dutchAuction.upchost();

        assertEq(dutchAuction.chost(), ((200 * _RAD) * ((_WAD * 113) / 100)) / _WAD, "chost refreshed");
    }

    function test_barkSafeVaultReverts() public {
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 400e18, 100e18);

        // At $1 the vault sits at 400%, exactly mat, far above the 260% bark line.
        vm.expectRevert(ILiquidationTrigger.NotUnsafe.selector);
        liquidationTrigger.bark(vaultId, keeper);
    }
}

/* ========================== CIRCUIT BREAKER ========================== */

/**
 * @title CircuitBreakerTest
 * @author Rain Team
 * @notice Coverage of the oracle-deviation breaker: activation, calm-period deactivation, trend anchoring, observation
 *         cadence and the liquidation throttle interaction.
 */
contract CircuitBreakerTest is BaseTest {
    /* ========================== HELPERS ========================== */

    /// @dev Pushes `price` through the OSM so peek() returns it as cur.
    function _setOsmPrice(uint256 price) internal {
        rainPriceSource.setPrice(price);
        vm.warp(((vm.getBlockTimestamp() / 1800) + 2) * 1800);
        osm.poke(RAIN_ILK);
        vm.warp(vm.getBlockTimestamp() + 3600);
        osm.poke(RAIN_ILK);
        priceConverter.poke(RAIN_ILK);
    }

    /// @dev Seeds the breaker's trend buffer with `n` observations of the current price.
    function _seedTrend(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            circuitBreaker.check();
            vm.warp(vm.getBlockTimestamp() + 301);
        }
    }

    /* ========================== 1. CONSTRUCTION & FILE ========================== */

    function test_constructorGuardsAndLaunchParameters() public {
        vm.expectRevert(InvalidAddress.selector);
        new CircuitBreaker(RAIN_ILK, IOracleSecurityModule(address(0)));

        vm.expectRevert(InvalidBytes.selector);
        new CircuitBreaker(bytes32(0), osm);

        assertEq(circuitBreaker.threshold(), _WAD / 4, "25% threshold");
        assertEq(circuitBreaker.calmPeriod(), 1800, "30 min calm");
        assertEq(circuitBreaker.obsInterval(), 300, "5 min interval");
        assertEq(circuitBreaker.OBS_COUNT(), 12, "12 observations");
    }

    function test_fileParametersAndGuards() public {
        circuitBreaker.file("threshold", _WAD / 2);
        circuitBreaker.file("calmPeriod", 3600);
        circuitBreaker.file("obsInterval", 600);

        assertEq(circuitBreaker.threshold(), _WAD / 2, "threshold");
        assertEq(circuitBreaker.calmPeriod(), 3600, "calmPeriod");
        assertEq(circuitBreaker.obsInterval(), 600, "obsInterval");

        vm.expectRevert(UnrecognizedParameter.selector);
        circuitBreaker.file("nonsense", 1);

        vm.prank(address(0xBAD));
        vm.expectRevert();
        circuitBreaker.file("threshold", 1);
    }

    /* ========================== 2. ACTIVATION / DEACTIVATION ========================== */

    function test_activatesOnLargeDeviationAndThrottlesBark() public {
        _setOsmPrice(1e18);
        _seedTrend(12);

        assertFalse(circuitBreaker.active(), "calm at stable price");

        // A large vault to liquidate once the crash lands (sized so the throttled partial stays non-dusty).
        rain.mint(user, 1600e18);
        vm.startPrank(user);
        rain.approve(address(collateralAdapter), 1600e18);
        collateralAdapter.join(RAIN_ILK, user, 1600e18);
        uint256 vaultId = vaultEngine.open(RAIN_ILK, user);
        vaultEngine.frob(vaultId, user, user, int256(1600e18), int256(400e18));
        vm.stopPrank();

        // 40% crash: far beyond the 25% threshold vs the $1 trend.
        _setOsmPrice(0.6e18);
        circuitBreaker.check();

        assertTrue(circuitBreaker.active(), "activated on crash");
        assertGt(circuitBreaker.activatedAt(), 0, "activation clock set");

        // The trigger throttles available room to 20% while active. Cap the ilk hole at 1000 rad: throttled room
        // = 1000 x 0.2 = 200 rad -> dart = 200/1.13 = ~177e18, a genuine partial (art 400e18) whose auction (177 rad)
        // and remainder (223 rad) both clear the 100 rad dust bar.
        liquidationTrigger.file(RAIN_ILK, "hole", 1000 * _RAD);

        uint256 id = liquidationTrigger.bark(vaultId, keeper);
        assertEq(id, 1, "throttled partial bark started");

        (, uint256 art) = vaultEngine.urns(vaultId);
        assertGt(art, 0, "only partially seized under throttle");
        assertLt(art, 400e18, "but genuinely seized");
    }

    function test_deactivatesOnlyAfterFullCalmPeriodAndCalmReading() public {
        _setOsmPrice(1e18);
        _seedTrend(12);

        _setOsmPrice(0.6e18);
        circuitBreaker.check();
        assertTrue(circuitBreaker.active(), "active");

        // Still deviated after the calm period: every check re-anchors the clock, so it stays active.
        vm.warp(vm.getBlockTimestamp() + 1801);
        circuitBreaker.check();
        assertTrue(circuitBreaker.active(), "still deviated -> still active (clock re-anchored)");

        // The price recovers toward the trend... but the trend has also been absorbing crash observations, so drive
        // enough calm observations that deviation falls under threshold, then wait out the calm period.
        _setOsmPrice(1e18);

        for (uint256 i; i < 12; ++i) {
            circuitBreaker.check();
            vm.warp(vm.getBlockTimestamp() + 301);
        }

        vm.warp(vm.getBlockTimestamp() + 1801);
        circuitBreaker.check();

        assertFalse(circuitBreaker.active(), "deactivated after calm period + calm reading");
        assertEq(circuitBreaker.activatedAt(), 0, "clock cleared");
    }

    function test_checkNoOpsOnInvalidFeed() public {
        _setOsmPrice(1e18);
        _seedTrend(3);

        osm.void(RAIN_ILK);

        // No revert, no state change on an invalid feed.
        uint256 lastObs = circuitBreaker.lastObsTimestamp();
        vm.warp(vm.getBlockTimestamp() + 301);
        circuitBreaker.check();

        assertEq(circuitBreaker.lastObsTimestamp(), lastObs, "no observation on invalid feed");
    }

    /* ========================== 3. TREND ANCHOR MECHANICS ========================== */

    function test_singleObservationCannotPoisonTrend() public {
        _setOsmPrice(1e18);
        _seedTrend(12);

        uint256 trendBefore = circuitBreaker.trendPrice();
        assertEq(trendBefore, 1e18, "clean trend");

        // One manipulated 10x observation moves the average by at most 1/12.
        _setOsmPrice(10e18);
        circuitBreaker.check();

        uint256 trendAfter = circuitBreaker.trendPrice();
        assertLe(trendAfter, trendBefore + (10e18 - 1e18) / 12 + 1, "anchor moved by at most 1/OBS_COUNT");
    }

    function test_observationCadenceIsRateLimited() public {
        _setOsmPrice(1e18);

        circuitBreaker.check();
        uint256 firstObs = circuitBreaker.lastObsTimestamp();

        // A second check 10 seconds later must NOT record a new observation.
        vm.warp(vm.getBlockTimestamp() + 10);
        circuitBreaker.check();

        assertEq(circuitBreaker.lastObsTimestamp(), firstObs, "observation rate-limited");

        // After the interval it records.
        vm.warp(vm.getBlockTimestamp() + 300);
        circuitBreaker.check();

        assertGt(circuitBreaker.lastObsTimestamp(), firstObs, "recorded after interval");
    }

    function test_trendZeroBeforeAnyObservation() public view {
        assertEq(circuitBreaker.trendPrice(), 0, "empty buffer");
    }
}

/* ========================== AUCTION DEPTH (Dutch auction) ========================== */

/**
 * @title AuctionDepthTest
 * @author Rain Team
 * @notice Deep coverage of the Dutch auction: price decay, flash callbacks, partial-purchase chost adjustment, redo
 *         pricing, yank-to-caller semantics and post-cage behaviour.
 */
contract AuctionDepthTest is BaseTest {
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

    function _fundBidder(address who, uint256 amt6) internal {
        usdt.mint(who, amt6);

        vm.startPrank(who);
        usdt.approve(address(psm), amt6);
        psm.sellStable(USDT_ILK, who, amt6);
        usdr.approve(address(collateralAdapter), amt6 * 1e12);
        collateralAdapter.join(_USDR_ILK, who, amt6 * 1e12);
        vaultEngine.hope(address(dutchAuction));
        vm.stopPrank();
    }

    /// @dev Opens a vault, crashes the price and barks. Returns the auction id.
    function _kickAuction() internal returns (uint256 id, uint256 vaultId) {
        _setRainPrice(1e18);
        vaultId = _openVault(user, 400e18, 100e18);
        _fundBidder(address(0xB1D), 300e6);
        _setRainPrice(0.6e18);

        id = liquidationTrigger.bark(vaultId, keeper);
    }

    /* ========================== 1. PRICE DECAY & STATUS ========================== */

    function test_priceDecaysLinearlyToZeroOverTau() public {
        (uint256 id, ) = _kickAuction();

        (, uint256 startPrice, , ) = dutchAuction.getStatus(id);

        // top = 0.6 * 1.05 = 0.63 ray-scaled.
        assertEq(startPrice, (0.6e18 * 105 * 1e9) / 100, "top = feed x buf");

        // Half tau: half price (linear curve, tau = 3600). At exactly tail seconds the auction is NOT yet resettable
        // (done requires elapsed > tail); one second later it is.
        vm.warp(vm.getBlockTimestamp() + 1800);
        (bool needsRedo, uint256 halfPrice, , ) = dutchAuction.getStatus(id);

        assertEq(halfPrice, startPrice / 2, "linear halfway");
        assertFalse(needsRedo, "exactly tail: not yet resettable");

        vm.warp(vm.getBlockTimestamp() + 1);
        (needsRedo, , , ) = dutchAuction.getStatus(id);
        assertTrue(needsRedo, "tail + 1: needs reset");
    }

    function test_kickGuards() public {
        vm.expectRevert(IDutchAuction.ZeroTab.selector);
        dutchAuction.kick(0, 1e18, 1, user, keeper);

        vm.expectRevert(IDutchAuction.ZeroLot.selector);
        dutchAuction.kick(1 * _RAD, 0, 1, user, keeper);

        vm.expectRevert(IDutchAuction.ZeroUser.selector);
        dutchAuction.kick(1 * _RAD, 1e18, 1, address(0), keeper);

        vm.prank(address(0xBAD));
        vm.expectRevert();
        dutchAuction.kick(1 * _RAD, 1e18, 1, user, keeper);
    }

    /* ========================== 2. FLASH CALLBACK ========================== */

    function test_takeWithFlashCallback() public {
        (uint256 id, ) = _kickAuction();

        MockAuctionCallee callee = new MockAuctionCallee(vaultEngine);

        // The callee holds the payment balance and hopes the auction; the keeper triggers the take with data.
        usdt.mint(address(this), 200e6);
        usdt.approve(address(psm), 200e6);
        psm.sellStable(USDT_ILK, address(this), 200e6);
        usdr.approve(address(collateralAdapter), 200e18);
        collateralAdapter.join(_USDR_ILK, address(0xB1D), 200e18);

        (, uint256 price, , ) = dutchAuction.getStatus(id);

        vm.prank(address(0xB1D));
        dutchAuction.take(id, 400e18, price, address(callee), "resell");

        assertEq(callee.calls(), 1, "callback fired");
        assertGt(vaultEngine.collateral(RAIN_ILK, address(callee)), 0, "collateral delivered to callee");
    }

    /* ========================== 3. PARTIAL PURCHASES ========================== */

    function test_partialPurchaseLeavesTabAndLot() public {
        // A 200-debt vault: tab = 226 rad = 2x chost, so a partial leaving >= chost is genuinely possible.
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 800e18, 200e18);
        _fundBidder(address(0xB1D), 300e6);
        _setRainPrice(0.6e18);

        uint256 id = liquidationTrigger.bark(vaultId, keeper);

        (, uint256 price, , uint256 tabBefore) = dutchAuction.getStatus(id);

        // Buy a slice small enough that the remainder stays >= chost (113 rad): 100e18 at ~0.63 = ~63 rad.
        vm.prank(address(0xB1D));
        dutchAuction.take(id, 100e18, price, address(0xB1D), "");

        (, , uint256 lotAfter, uint256 tabAfter) = dutchAuction.getStatus(id);

        assertEq(lotAfter, 700e18, "lot reduced");
        assertEq(tabAfter, tabBefore - 100e18 * price, "tab reduced by owe");
    }

    function test_partialBelowChostRevertsWhenTabTooSmall() public {
        // Engineer a tab at exactly chost: any partial would leave a sub-chost remainder and the whole tab is not
        // above chost, so NoPartialPurchase fires.
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 400e18, 100e18);
        _fundBidder(address(0xB1D), 300e6);
        _setRainPrice(0.6e18);

        // hole = chost -> tab = 113 rad = chost (dust 100 x chop 1.13).
        liquidationTrigger.file(RAIN_ILK, "hole", 113 * _RAD);

        uint256 id = liquidationTrigger.bark(vaultId, keeper);

        (, uint256 price, , uint256 tab) = dutchAuction.getStatus(id);
        assertEq(tab, dutchAuction.chost(), "tab pinned at chost");

        // A partial (anything less than the full lot value) must revert.
        uint256 slice = (tab / price) / 2;

        vm.prank(address(0xB1D));
        vm.expectRevert(IDutchAuction.NoPartialPurchase.selector);
        dutchAuction.take(id, slice, price, address(0xB1D), "");
    }

    /* ========================== 4. REDO ========================== */

    function test_redoRefreshesPriceAndCannotFireEarly() public {
        (uint256 id, ) = _kickAuction();

        // Too early to reset.
        vm.expectRevert(IDutchAuction.CannotReset.selector);
        dutchAuction.redo(id, keeper);

        vm.warp(vm.getBlockTimestamp() + 1801);

        (, uint256 stalePrice, , ) = dutchAuction.getStatus(id);
        dutchAuction.redo(id, keeper);

        (, uint256 freshPrice, , ) = dutchAuction.getStatus(id);
        assertGt(freshPrice, stalePrice, "price re-anchored to feed x buf");

        // Unknown auction.
        vm.expectRevert(IDutchAuction.AuctionNotRunning.selector);
        dutchAuction.redo(999, keeper);
    }

    /* ========================== 5. YANK ========================== */

    function test_yankSendsCollateralToCallerAndClosesAuction() public {
        (uint256 id, ) = _kickAuction();

        // Ward-only.
        vm.prank(address(0xBAD));
        vm.expectRevert();
        dutchAuction.yank(id);

        uint256 before = vaultEngine.collateral(RAIN_ILK, address(this));
        dutchAuction.yank(id);

        // Remaining collateral moves to the CALLER (the settlement path depends on it).
        assertEq(vaultEngine.collateral(RAIN_ILK, address(this)) - before, 400e18, "collateral to caller");

        (, , uint256 lot, uint256 tab) = dutchAuction.getStatus(id);
        assertEq(lot, 0, "closed");
        assertEq(tab, 0, "closed");

        vm.expectRevert(IDutchAuction.AuctionNotRunning.selector);
        dutchAuction.yank(id);
    }

    /* ========================== 6. CAGE ========================== */

    function test_cageBlocksKickTakeRedoButNotYank() public {
        (uint256 id, ) = _kickAuction();

        dutchAuction.cage();

        vm.expectRevert(NotLive.selector);
        dutchAuction.kick(1 * _RAD, 1e18, 1, user, keeper);

        (, uint256 price, , ) = dutchAuction.getStatus(id);

        vm.prank(address(0xB1D));
        vm.expectRevert(NotLive.selector);
        dutchAuction.take(id, 400e18, price, address(0xB1D), "");

        vm.expectRevert(NotLive.selector);
        dutchAuction.redo(id, keeper);

        // Yank still works after cage: End.skip depends on it.
        dutchAuction.yank(id);
    }

    /* ========================== 7. LIST / COUNT / FILE ========================== */

    function test_activeListTracksAuctions() public {
        (uint256 id, ) = _kickAuction();

        assertEq(dutchAuction.count(), 1, "one active");
        assertEq(dutchAuction.list()[0], id, "listed");
        assertEq(dutchAuction.active(0), id, "indexed");

        dutchAuction.yank(id);
        assertEq(dutchAuction.count(), 0, "removed");
    }

    function test_fileGuardsAndCageGating() public {
        vm.expectRevert(UnrecognizedParameter.selector);
        dutchAuction.file("nonsense", 1);

        vm.expectRevert(UnrecognizedParameter.selector);
        dutchAuction.file("nonsense", address(1));

        dutchAuction.cage();

        vm.expectRevert(NotLive.selector);
        dutchAuction.file("buf", _RAY);

        vm.expectRevert(NotLive.selector);
        dutchAuction.file("pip", address(osm));
    }
}

/* ========================== LIQUIDATION AUDIT REGRESSIONS ========================== */

/**
 * @title LiquidationAuditTest
 * @author Rain Team
 * @notice Audit regressions exercising the liquidation stack: bark thresholds, dart precision ordering and the Dutch
 *         Auction chost boundary behaviour.
 */
contract LiquidationAuditTest is BaseTest {
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

    /* ========================== 1. BARK THRESHOLD ========================== */

    function test_barkThresholdAt65PercentOfMat() public {
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 400e18, 100e18);

        // At 66% of the required ratio the vault is NOT barkable.
        _setRainPrice(0.66e18);
        vm.expectRevert(ILiquidationTrigger.NotUnsafe.selector);
        liquidationTrigger.bark(vaultId, keeper);

        // Below 65% it is barkable.
        _setRainPrice(0.64e18);
        uint256 id = liquidationTrigger.bark(vaultId, keeper);
        assertEq(id, 1, "auction started");
    }

    function test_barkThresholdAppliesPerVaultIndependently() public {
        _setRainPrice(1e18);

        // Same owner, same ilk: one healthy vault (800%) and one at-mat vault (400%).
        uint256 healthyVault = _openVault(user, 800e18, 100e18);
        uint256 riskyVault = _openVault(user, 400e18, 100e18);

        // At 64% of mat for the risky vault, the healthy vault (at 128% of mat) must NOT be barkable while the risky
        // one is: the 65% barkFactor is evaluated against each vault's own ink/art in isolation.
        _setRainPrice(0.64e18);

        vm.expectRevert(ILiquidationTrigger.NotUnsafe.selector);
        liquidationTrigger.bark(healthyVault, keeper);

        uint256 id = liquidationTrigger.bark(riskyVault, keeper);
        assertEq(id, 1, "risky vault liquidated");

        // The healthy vault of the same owner is untouched by the sibling's liquidation.
        (uint256 ink, uint256 art) = vaultEngine.urns(healthyVault);
        assertEq(ink, 800e18, "healthy ink untouched");
        assertEq(art, 100e18, "healthy art untouched");

        // The risky vault was seized in full.
        (ink, art) = vaultEngine.urns(riskyVault);
        assertEq(ink, 0, "risky ink seized");
        assertEq(art, 0, "risky art seized");
    }

    function test_barkOnUnopenedVaultReverts() public {
        vm.expectRevert(ILiquidationTrigger.VaultNotFound.selector);
        liquidationTrigger.bark(999, keeper);
    }

    /* ========================== 2. DART PRECISION ========================== */

    function test_barkDartPrecisionOrdering() public {
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 1600e18, 400e18);

        // Limiting room to force a partial liquidation.
        liquidationTrigger.file(RAIN_ILK, "hole", 150 * _RAD);
        _setRainPrice(0.6e18);

        liquidationTrigger.bark(vaultId, keeper);

        // Precision ordering: dart = room * WAD / rate / chop, computed before flooring by rate.
        uint256 expectedDart = ((150 * _RAD) * _WAD) / _RAY / ((_WAD * 113) / 100);
        (, uint256 art) = vaultEngine.urns(vaultId);

        assertGt(expectedDart, 0, "dart nonzero");
        assertEq(art, 400e18 - expectedDart, "dart correctly scaled");
    }

    /* ========================== 3. DUTCH AUCTION CHOST ========================== */

    function test_redoPaysNoRewardBelowChost() public {
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 400e18, 100e18);
        _setRainPrice(0.6e18);

        uint256 id = liquidationTrigger.bark(vaultId, keeper);

        // Letting the auction expire, then crashing the price so lot * feedPrice < chost.
        vm.warp(vm.getBlockTimestamp() + 1801);
        _setRainPrice(0.0001e18);

        uint256 before = vaultEngine.usdr(keeper);
        dutchAuction.redo(id, keeper);
        assertEq(vaultEngine.usdr(keeper), before, "no reward below chost");
    }

    function test_redoPaysRewardAboveChost() public {
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 400e18, 100e18);
        _setRainPrice(0.6e18);

        uint256 id = liquidationTrigger.bark(vaultId, keeper);

        vm.warp(vm.getBlockTimestamp() + 1801);
        _setRainPrice(0.6e18);

        uint256 before = vaultEngine.usdr(keeper);
        dutchAuction.redo(id, keeper);
        assertGt(vaultEngine.usdr(keeper), before, "reward above chost");
    }

    function test_takePartialPurchaseAdjustsDownAtChostBoundary() public {
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 800e18, 200e18);
        _setRainPrice(0.6e18);

        uint256 id = liquidationTrigger.bark(vaultId, keeper);
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
}
