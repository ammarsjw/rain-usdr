// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IOracleSecurityModule } from "../contracts/interfaces/IOracleSecurityModule.sol";
import { IPriceConverter } from "../contracts/interfaces/IPriceConverter.sol";
import { InvalidAmount, NotLive } from "../contracts/shared/Errors.sol";
import { _RAY, _READER_ROLE } from "../contracts/shared/Constants.sol";

import { BaseTest } from "./shared/BaseTest.sol";

/* ========================== ORACLE (OSM & PRICE CONVERTER) ========================== */

/**
 * @title OracleTest
 * @author Rain Team
 * @notice Adversarial coverage of the OSM and Price Converter: delay mechanics and the one-second worst-case
 *         bound, staleness, zero-price handling, spot derivation and the file-time parameter guards.
 */
contract OracleTest is BaseTest {
    function setUp() public override {
        super.setUp();

        // The test contract reads the OSM directly in several scenarios.
        osm.grantRole(_READER_ROLE, address(this));
    }

    /* ========================== HELPERS ========================== */

    /// @dev Warps to the next HOP boundary plus `offset` seconds.
    function _warpToBoundary(uint256 offset) internal {
        vm.warp(((vm.getBlockTimestamp() / 1800) + 1) * 1800 + offset);
    }

    /* ========================== 1. OSM DELAY MECHANICS ========================== */

    function test_osmRejectsPokeWithinSameWindow() public {
        _warpToBoundary(0);
        osm.poke(RAIN_ILK);

        // A second poke inside the same window reverts.
        vm.warp(vm.getBlockTimestamp() + 900);
        vm.expectRevert(IOracleSecurityModule.NotPassed.selector);
        osm.poke(RAIN_ILK);
    }

    function test_osmDelayIsHardBoundEvenAtBoundary() public {
        // Regression: the poke timestamp is stored UNSNAPPED, so a poke landing at the very end of a window
        // (boundary + 1799) does NOT permit another poke one second later. The minimum nxt->cur residency is a hard
        // {HOP}, and SLAs may be sized to the full 30 minutes.
        _warpToBoundary(1799);
        rainPriceSource.setPrice(1e18);
        osm.poke(RAIN_ILK);

        // One second later (the old worst case): rejected.
        vm.warp(vm.getBlockTimestamp() + 1);
        rainPriceSource.setPrice(9e18); // Manipulated price...
        vm.expectRevert(IOracleSecurityModule.NotPassed.selector);
        osm.poke(RAIN_ILK); // ...must wait the full HOP.

        // HOP - 1 seconds after the first poke: still rejected.
        vm.warp(vm.getBlockTimestamp() + 1798);
        vm.expectRevert(IOracleSecurityModule.NotPassed.selector);
        osm.poke(RAIN_ILK);

        // Exactly HOP after the first poke: accepted, and only now is the manipulated price queued in nxt.
        vm.warp(vm.getBlockTimestamp() + 1);
        osm.poke(RAIN_ILK);

        (bytes32 nxtVal, ) = osm.peep(RAIN_ILK);
        assertEq(uint256(nxtVal), 9e18, "manipulated price spent zero seconds shortcutting the window");

        (bytes32 curVal, ) = osm.peek(RAIN_ILK);
        assertEq(uint256(curVal), 1e18, "prior price current");
    }

    function test_osmStopStartVoidLifecycle() public {
        _warpToBoundary(0);
        osm.poke(RAIN_ILK);

        osm.stop(RAIN_ILK);

        vm.warp(vm.getBlockTimestamp() + 3600);
        vm.expectRevert(NotLive.selector);
        osm.poke(RAIN_ILK);

        osm.start(RAIN_ILK);
        osm.poke(RAIN_ILK);

        // Void wipes both feeds and stops the ilk.
        osm.void(RAIN_ILK);

        (, bool has) = osm.peek(RAIN_ILK);
        assertFalse(has, "cur wiped");

        (, bool hasNxt) = osm.peep(RAIN_ILK);
        assertFalse(hasNxt, "nxt wiped");
    }

    function test_osmZeroPriceTreatedAsFailedReport() public {
        // A valid-but-zero report must never enter the feed.
        _warpToBoundary(0);
        rainPriceSource.setPrice(0);

        vm.expectEmit(true, true, false, false);
        emit IOracleSecurityModule.PokeFailed(RAIN_ILK, address(rainPriceSource));
        osm.poke(RAIN_ILK);

        (, bool hasNxt) = osm.peep(RAIN_ILK);
        assertFalse(hasNxt, "zero price rejected");
    }

    function test_osmInvalidSourceEmitsPokeFailedWithoutReverting() public {
        _warpToBoundary(0);
        rainPriceSource.setValid(false);

        vm.expectEmit(true, true, false, false);
        emit IOracleSecurityModule.PokeFailed(RAIN_ILK, address(rainPriceSource));
        osm.poke(RAIN_ILK);
    }

    function test_osmReadsAreReaderGated() public {
        vm.startPrank(address(0xBAD));

        vm.expectRevert();
        osm.peek(RAIN_ILK);

        vm.expectRevert();
        osm.peep(RAIN_ILK);

        vm.expectRevert();
        osm.read(RAIN_ILK);

        vm.stopPrank();
    }

    function test_osmReadRevertsWithoutCurrentValue() public {
        vm.expectRevert(IOracleSecurityModule.NoCurrentValue.selector);
        osm.read(RAIN_ILK);
    }

    /* ========================== 2. PRICE CONVERTER ========================== */

    function test_matBelowRayRejected() public {
        // A sub-100% collateralization ratio would authorize under-collateralized minting at origination.
        vm.expectRevert(IPriceConverter.MatBelowOne.selector);
        priceConverter.file(RAIN_ILK, "mat", _RAY - 1);

        // Exactly RAY (100%) is the floor and passes.
        priceConverter.file(RAIN_ILK, "mat", _RAY);
    }

    function test_fixedFlagOnlyAcceptsZeroOrOne() public {
        // The flag is a strict 0/1: anything else is a fat-finger and rejected.
        vm.expectRevert(InvalidAmount.selector);
        priceConverter.file(USDT_ILK, "fixed", 2);

        // Clearing the flag makes the ilk oracle-backed via the single system-wide OSM.
        priceConverter.file(USDT_ILK, "fixed", 0);

        (, bool fixedPrice) = priceConverter.ilks(USDT_ILK);
        assertFalse(fixedPrice, "flag cleared");

        // The OSM does not serve USDT: poke fails closed to a zero spot rather than freezing the last value.
        priceConverter.poke(USDT_ILK);

        (, , , uint256 spot, , , , ) = vaultEngine.ilks(USDT_ILK);
        assertEq(spot, 0, "unserved oracle-backed ilk fails closed");
    }

    function test_spotDerivationMatchesFormula() public {
        // $2 price with 400% mat: spot = price * 1e9 * RAY / par / mat = 0.5 RAY.
        rainPriceSource.setPrice(2e18);
        vm.warp(((vm.getBlockTimestamp() / 1800) + 2) * 1800);
        osm.poke(RAIN_ILK);
        vm.warp(vm.getBlockTimestamp() + 3600);
        osm.poke(RAIN_ILK);
        priceConverter.poke(RAIN_ILK);

        (, , , uint256 spot, , , , ) = vaultEngine.ilks(RAIN_ILK);
        assertEq(spot, _RAY / 2, "spot = price / mat");
    }

    function test_pokeUnconfiguredIlkReverts() public {
        vm.expectRevert(IPriceConverter.IlkNotConfigured.selector);
        priceConverter.poke("GHOST-A");
    }

    function test_pokeWithInvalidFeedZeroesSpot() public {
        // A live spot first.
        rainPriceSource.setPrice(1e18);
        vm.warp(((vm.getBlockTimestamp() / 1800) + 2) * 1800);
        osm.poke(RAIN_ILK);
        vm.warp(vm.getBlockTimestamp() + 3600);
        osm.poke(RAIN_ILK);
        priceConverter.poke(RAIN_ILK);

        (, , , uint256 spotBefore, , , , ) = vaultEngine.ilks(RAIN_ILK);
        assertGt(spotBefore, 0, "live spot");

        // Void the OSM feed: the converter must zero the spot (freezing mints) rather than keep the stale value.
        osm.void(RAIN_ILK);
        priceConverter.poke(RAIN_ILK);

        (, , , uint256 spotAfter, , , , ) = vaultEngine.ilks(RAIN_ILK);
        assertEq(spotAfter, 0, "invalid feed freezes minting");
    }

    function test_fixedIlkPokesDollarWithoutOracle() public {
        priceConverter.poke(USDT_ILK);

        (, , , uint256 spot, , , , ) = vaultEngine.ilks(USDT_ILK);
        assertEq(spot, _RAY, "fixed $1 at 100% mat");
    }

    function test_converterFileGuards() public {
        vm.expectRevert();
        vm.prank(address(0xBAD));
        priceConverter.file(RAIN_ILK, "mat", 4 * _RAY);

        priceConverter.cage();

        vm.expectRevert(NotLive.selector);
        priceConverter.file(RAIN_ILK, "mat", 4 * _RAY);

        vm.expectRevert(NotLive.selector);
        priceConverter.file("par", _RAY);
    }

    function test_parZeroRejected() public {
        // Regression: par == 0 would brick poke for every ilk (division by par), freezing all spots at their last
        // values — the dangerous direction — and file's live-gate means it could never be repaired after a cage.
        vm.expectRevert(InvalidAmount.selector);
        priceConverter.file("par", 0);

        // Sane values still pass and poke keeps working.
        priceConverter.file("par", _RAY);
        priceConverter.poke(USDT_ILK);
    }

    /* ========================== 3. FUZZ ========================== */

    function testFuzz_spotScalesInverselyWithMat(uint8 matFactor) public {
        uint256 factor = (uint256(matFactor) % 10) + 1;

        priceConverter.file(RAIN_ILK, "mat", factor * _RAY);

        rainPriceSource.setPrice(1e18);
        vm.warp(((vm.getBlockTimestamp() / 1800) + 2) * 1800);
        osm.poke(RAIN_ILK);
        vm.warp(vm.getBlockTimestamp() + 3600);
        osm.poke(RAIN_ILK);
        priceConverter.poke(RAIN_ILK);

        (, , , uint256 spot, , , , ) = vaultEngine.ilks(RAIN_ILK);
        assertEq(spot, _RAY / factor, "spot inversely proportional to mat");
    }

    function test_staleOsmPriceFailsClosedOnPeekAndPoke() public {
        rainPriceSource.setPrice(1e18);
        vm.warp(((vm.getBlockTimestamp() / 1800) + 2) * 1800);
        osm.poke(RAIN_ILK);
        vm.warp(vm.getBlockTimestamp() + 3600);
        osm.poke(RAIN_ILK);
        priceConverter.poke(RAIN_ILK);

        (, bool hasFresh) = osm.peek(RAIN_ILK);
        assertTrue(hasFresh, "fresh after poke");

        // Past maxAge the stored value is still present but consumers must treat it as invalid.
        vm.warp(vm.getBlockTimestamp() + osm.maxAge() + 1);

        (, bool hasStale) = osm.peek(RAIN_ILK);
        assertFalse(hasStale, "stale peek is invalid");

        vm.expectRevert(IOracleSecurityModule.NoCurrentValue.selector);
        osm.read(RAIN_ILK);

        priceConverter.poke(RAIN_ILK);
        (, , , uint256 spot, , , , ) = vaultEngine.ilks(RAIN_ILK);
        assertEq(spot, 0, "stale poke zeroes spot");
    }
}
