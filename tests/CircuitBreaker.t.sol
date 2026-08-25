// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { CircuitBreaker } from "../contracts/liquidation/CircuitBreaker.sol";
import { IOracleSecurityModule } from "../contracts/interfaces/IOracleSecurityModule.sol";
import { InvalidAddress, InvalidBytes, UnrecognizedParameter } from "../contracts/shared/Errors.sol";
import { _RAD, _WAD } from "../contracts/shared/Constants.sol";

import { BaseTest } from "./Base.t.sol";

/**
 * @title CircuitBreakerTest
 * @author Rain Team
 * @notice Coverage of the oracle-deviation breaker: activation, calm-period deactivation, trend anchoring,
 *         observation cadence and the liquidation throttle interaction.
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
        // = 1000 x 0.2 = 200 rad -> dart = 200/1.13 = ~177e18, a genuine partial (art 400e18) whose auction (177
        // rad) and remainder (223 rad) both clear the 100 rad dust bar.
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

        // The price recovers toward the trend... but the trend has also been absorbing crash observations, so
        // drive enough calm observations that deviation falls under threshold, then wait out the calm period.
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
