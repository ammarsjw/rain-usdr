// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IOracleSecurityModule } from "../contracts/interfaces/IOracleSecurityModule.sol";
import { IPriceConverter } from "../contracts/interfaces/IPriceConverter.sol";
import { InvalidAddress, InvalidAmount, NotLive } from "../contracts/shared/Errors.sol";
import { _RAY, _READER_ROLE } from "../contracts/shared/Constants.sol";

import { BaseTest } from "./shared/BaseTest.sol";
import { MockPriceSource } from "./mocks/MockPriceSource.sol";

/* ========================== ORACLE (OSM & PRICE CONVERTER) ========================== */

/**
 * @title OracleTest
 * @author Rain Team
 * @notice Adversarial coverage of the OSM and Price Converter: delay mechanics and the M-1 one-second
 *         worst-case bound, staleness, zero-price handling (L-10), spot derivation and the M-7/M-8 file
 *         guards.
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
        // Audit M-4 (fixed): the poke timestamp is stored UNSNAPPED, so a poke landing at the very end of a
        // window (boundary + 1799) does NOT permit another poke one second later. The minimum nxt->cur
        // residency is a hard {HOP}, and SLAs may be sized to the full 30 minutes.
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
        // L-10: a valid-but-zero report must never enter the feed.
        _warpToBoundary(0);
        rainPriceSource.setPrice(0);

        vm.expectEmit(true, true, false, false);
        emit IOracleSecurityModule.PokeFailed(RAIN_ILK, address(rainPriceSource));
        osm.poke(RAIN_ILK);

        (, bool hasNxt) = osm.peep(RAIN_ILK);
        assertFalse(hasNxt, "zero price rejected");
    }

    function test_osmChangeClearsQueuedNextPrice() public {
        // Rotating the price source must retire the outgoing source's QUEUED price. Otherwise the first
        // poke after the switch promotes the abandoned source's value into cur — the exact value a rotation
        // away from a compromised source is meant to retire.
        _warpToBoundary(0);
        rainPriceSource.setPrice(1e18);
        osm.poke(RAIN_ILK); // Queues 1e18 (honest baseline) into nxt.

        vm.warp(vm.getBlockTimestamp() + 1800);
        rainPriceSource.setPrice(9e18); // Compromised source queues a malicious price...
        osm.poke(RAIN_ILK); // ...into nxt (1e18 promotes to cur).

        // Governance rotates to a fresh, honest source.
        MockPriceSource honestSource = new MockPriceSource(1e18);
        osm.change(RAIN_ILK, honestSource);

        // The malicious queued price is gone; the fully-delayed current price survives.
        (, bool hasNxt) = osm.peep(RAIN_ILK);
        assertFalse(hasNxt, "queued price from the retired source wiped");

        (bytes32 curVal, bool hasCur) = osm.peek(RAIN_ILK);
        assertTrue(hasCur, "current price kept across the rotation");
        assertEq(uint256(curVal), 1e18, "current price unchanged");

        // The next poke queues the NEW source's price into nxt — it does not promote anything malicious.
        vm.warp(vm.getBlockTimestamp() + 1800);
        osm.poke(RAIN_ILK);

        (curVal, ) = osm.peek(RAIN_ILK);
        assertEq(uint256(curVal), 0, "empty queue promoted, never the retired source's 9e18");

        (bytes32 nxtVal, ) = osm.peep(RAIN_ILK);
        assertEq(uint256(nxtVal), 1e18, "new source's price queued under the full delay");
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
        // M-8: a sub-100% collateralization ratio would authorize under-collateralized minting at
        // origination.
        vm.expectRevert(IPriceConverter.MatBelowOne.selector);
        priceConverter.file(RAIN_ILK, "mat", _RAY - 1);

        // Exactly RAY (100%) is the floor and passes.
        priceConverter.file(RAIN_ILK, "mat", _RAY);
    }

    function test_clearingFixedFlagDirectlyIsRejected() public {
        // M-7: file(ilk, "fixed", 0) used to silently wipe the pip and freeze spot at its last value.
        vm.expectRevert(IPriceConverter.WouldOrphanIlk.selector);
        priceConverter.file(USDT_ILK, "fixed", 0);

        // The safe path: assigning an oracle clears the fixed flag atomically.
        priceConverter.file(USDT_ILK, "pip", address(osm));

        (, , bool fixedPrice) = priceConverter.ilks(USDT_ILK);
        assertFalse(fixedPrice, "pip assignment cleared fixed");
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
        vm.expectRevert(InvalidAddress.selector);
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

        // Void the OSM feed: the converter must zero the spot (freezing mints) rather than keep the stale
        // value.
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
        // Audit L-2: par == 0 would brick poke for every ilk (division by par), freezing all spots at their
        // last values — the dangerous direction — and file's live-gate means it could never be repaired after
        // a cage.
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
}
