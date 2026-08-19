// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IPegStabilityModule } from "../contracts/interfaces/IPegStabilityModule.sol";
import { IReserveAccounting } from "../contracts/interfaces/IReserveAccounting.sol";
import { ISolvencyEngine } from "../contracts/interfaces/ISolvencyEngine.sol";
import { InvalidAmount, SolvencyGateActive } from "../contracts/shared/Errors.sol";
import { _RAY, _WAD } from "../contracts/shared/Constants.sol";

import { BaseTest } from "./Base.t.sol";
import { MockExternalExposure } from "./mocks/MockExternalExposure.sol";

/**
 * @title ReserveTest
 * @author Rain Team
 * @notice Adversarial coverage of the reserve stack: the H-1 direct-OSM pricing (mat-change immunity), the M-3
 *         lazy redemption gate, parameter bounds (L-4), volatile ilk validation (L-5) and escrow guards (L-1).
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

    /* ========================== 1. H-1: DIRECT OSM PRICING ========================== */

    function test_worstCaseLossImmuneToMatChange() public {
        // THE rev-4 headline scenario. Loss must be identical before and after a mat change with no poke: the
        // engine prices collateral straight from the OSM, so mat desynchronization cannot bend it.
        _setRainPrice(1e18);
        _openVault(user, 800e18, 200e18);

        uint256 lossBefore = solvencyEngine.worstCaseLoss();
        assertEq(lossBefore, 60e18, "baseline: 200 - 800*0.5*0.35");

        // Governance responds to rising risk by RAISING mat (the standard action) -- no poke yet.
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

    /* ========================== 2. M-3: LAZY REDEMPTION GATE ========================== */

    function test_redemptionGateHoldsWithoutAnyKeeper() public {
        // Price collapse with the keeper dead: buyStable itself must detect the breach.
        _setRainPrice(1e18);
        _openVault(user, 800e18, 200e18);
        _sellUsdt(keeper, 20e6);

        // NOTE: no checkInvariant call anywhere. The stale flag says healthy.
        assertFalse(solvencyEngine.breached(), "flag stale-healthy");

        vm.startPrank(keeper);
        usdr.approve(address(psm), 5e18);
        vm.expectRevert(SolvencyGateActive.selector);
        psm.buyStable(USDT_ILK, keeper, 5e6);
        vm.stopPrank();

        // NOTE: the revert rolls the recompute back with the rest of the transaction -- the persistent flag is
        // still refreshed by keepers and by any SUCCESSFUL redemption; what the lazy gate guarantees is that no
        // redemption can ever pass on stale data, which the revert above just proved.
        assertFalse(solvencyEngine.breached(), "flag untouched by the reverted attempt");
    }

    /* ========================== 3. PARAMETER BOUNDS (L-4) ========================== */

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

    /* ========================== 4. L-5: VOLATILE ILK VALIDATION ========================== */

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

    /* ========================== 5. L-1: ESCROW GUARD ========================== */

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

    /* ========================== 6. M-2: EXPOSURE CAP ORDERING ========================== */

    function test_exposureReporterRequiresCapFirst() public {
        MockExternalExposure exposure = new MockExternalExposure();

        vm.expectRevert(ISolvencyEngine.ExposureCapNotSet.selector);
        solvencyEngine.file("externalExposure", address(exposure));

        solvencyEngine.file("exposureCap", 50e18);
        solvencyEngine.file("externalExposure", address(exposure));

        // Real reports below the cap pass through unclamped.
        exposure.setExposure(10e18);
        assertEq(solvencyEngine.worstCaseLoss(), 10e18, "real exposure counted");

        // Above-cap and reverting reporters clamp to the cap (fail conservative).
        exposure.setExposure(1_000_000e18);
        assertEq(solvencyEngine.worstCaseLoss(), 50e18, "clamped");

        exposure.setShouldRevert(true);
        assertEq(solvencyEngine.worstCaseLoss(), 50e18, "revert falls back to cap");
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

    /* ========================== 8. FUZZ ========================== */

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
