// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { VaultEngine } from "../contracts/core/VaultEngine.sol";
import { ILiquidationTrigger } from "../contracts/interfaces/ILiquidationTrigger.sol";
import { IVaultEngine } from "../contracts/interfaces/IVaultEngine.sol";
import { Math } from "../contracts/libraries/Math.sol";
import { FeeRecipientNotSet, InvalidDuty } from "../contracts/shared/Errors.sol";
import { _RAD, _RAY } from "../contracts/shared/Constants.sol";

import { BaseTest } from "./Base.t.sol";

/**
 * @title StabilityFeeTest
 * @author Rain Team
 * @notice Coverage of stability fee accrual: drip idempotency and compounding, fee crediting, frob and bark
 *         auto-drip, non-retroactive duty changes, dust and liquidation math at rate > RAY, and the post-cage
 *         freeze.
 */
contract StabilityFeeTest is BaseTest {
    bytes32 internal constant TEST_ILK = "TEST-A";

    /// @dev Per-second factor for roughly 5% APY: 1.05^(1/31536000) scaled to ray (Maker's canonical value).
    uint256 internal constant DUTY_5PCT = 1000000001547125957863212448;

    /// @dev Per-second factor for roughly 100% APY (stress value): 2^(1/31536000) scaled to ray.
    uint256 internal constant DUTY_100PCT = 1000000021979553151239153027;

    address internal alice = address(0xA11CE);

    function setUp() public override {
        super.setUp();

        vaultEngine.init(TEST_ILK);
        vaultEngine.file(TEST_ILK, "line", 1_000_000_000 * _RAD);
        vaultEngine.file(TEST_ILK, "spot", _RAY);
    }

    /// @dev Opens a TEST-A vault for `who` with free collateral pre-slipped.
    function _openTestVault(address who, uint256 ink, uint256 art) internal returns (uint256 vaultId) {
        vaultEngine.slip(TEST_ILK, who, int256(ink));

        vm.startPrank(who);
        vaultId = vaultEngine.open(TEST_ILK, who);
        vaultEngine.frob(vaultId, who, who, int256(ink), int256(art));
        vm.stopPrank();
    }

    function _rate(bytes32 ilkId) internal view returns (uint256 rate) {
        (, , rate, , , , , ) = vaultEngine.ilks(ilkId);
    }

    /* ========================== 1. INIT & FILE ========================== */

    function test_initSetsZeroFeeDefaults() public view {
        (, , uint256 rate, , , , uint256 duty, uint256 rho) = vaultEngine.ilks(TEST_ILK);

        assertEq(rate, _RAY, "rate starts at RAY");
        assertEq(duty, _RAY, "duty starts at RAY (zero fee)");
        assertEq(rho, block.timestamp, "rho starts now");
    }

    function test_fileDutyRejectsBelowRay() public {
        vm.expectRevert(InvalidDuty.selector);
        vaultEngine.file(TEST_ILK, "duty", _RAY - 1);
    }

    function test_fileFeeRecipientRejectsZeroAddress() public {
        vm.expectRevert();
        vaultEngine.file("feeRecipient", address(0));
    }

    /* ========================== 2. DRIP MECHANICS ========================== */

    function test_dripRevertsOnUninitializedIlk() public {
        vm.expectRevert(IVaultEngine.IlkNotInitialized.selector);
        vaultEngine.drip("UNKNOWN-A");
    }

    function test_dripIdempotentWithinBlock() public {
        vaultEngine.file(TEST_ILK, "duty", DUTY_5PCT);
        _openTestVault(alice, 1000e18, 500e18);

        skip(365 days);

        uint256 first = vaultEngine.drip(TEST_ILK);
        uint256 debtAfterFirst = vaultEngine.debt();

        // Second drip in the same block: no state change.
        uint256 second = vaultEngine.drip(TEST_ILK);

        assertEq(second, first, "same rate");
        assertEq(vaultEngine.debt(), debtAfterFirst, "no extra debt");
    }

    function test_dripMatchesExpectedRpowCompounding() public {
        vaultEngine.file(TEST_ILK, "duty", DUTY_5PCT);

        uint256 elapsed = 365 days;

        skip(elapsed);

        uint256 expected = Math.rmul(Math.rpow(DUTY_5PCT, elapsed, _RAY), _RAY);
        uint256 newRate = vaultEngine.drip(TEST_ILK);

        assertEq(newRate, expected, "exact rpow compounding");
        assertEq(_rate(TEST_ILK), expected, "rate stored");

        // ~5% after a year: sanity band of [4.9%, 5.1%].
        assertGt(newRate, (_RAY * 1049) / 1000, "at least ~4.9%");
        assertLt(newRate, (_RAY * 1051) / 1000, "at most ~5.1%");
    }

    function test_dripCreditsFeeRecipientAndDebtEqually() public {
        vaultEngine.file(TEST_ILK, "duty", DUTY_5PCT);
        _openTestVault(alice, 1000e18, 500e18);

        uint256 debtBefore = vaultEngine.debt();
        uint256 surplusBefore = vaultEngine.usdr(address(balanceSheet));

        skip(30 days);

        uint256 rateBefore = _rate(TEST_ILK);
        uint256 newRate = vaultEngine.drip(TEST_ILK);
        uint256 expectedRad = 500e18 * (newRate - rateBefore);

        assertGt(expectedRad, 0, "nonzero accrual");
        assertEq(vaultEngine.usdr(address(balanceSheet)) - surplusBefore, expectedRad, "surplus credited");
        assertEq(vaultEngine.debt() - debtBefore, expectedRad, "debt increased equally");
    }

    function test_dripZeroDutyAccruesNothing() public {
        _openTestVault(alice, 1000e18, 500e18);

        uint256 debtBefore = vaultEngine.debt();

        skip(365 days);

        assertEq(vaultEngine.drip(TEST_ILK), _RAY, "rate stays RAY");
        assertEq(vaultEngine.debt(), debtBefore, "no debt change");
    }

    function test_dripRevertsWhenFeeRecipientUnsetAndFeesAccrue() public {
        // A fresh engine without feeRecipient wiring.
        vm.startPrank(address(this));

        // Reuse the shared engine by unsetting is impossible (file rejects zero), so deploy expectations directly:
        // this test uses a dedicated assertion on the shared engine by checking the error path via a mock is
        // unnecessary -- instead verify the error surfaces from a brand-new engine.
        vm.stopPrank();

        // Deploy a minimal standalone engine.
        VaultEngineHarness engine = new VaultEngineHarness();

        engine.init(TEST_ILK);
        engine.file("globalLine", 1_000_000_000 * _RAD);
        engine.file(TEST_ILK, "line", 1_000_000_000 * _RAD);
        engine.file(TEST_ILK, "spot", _RAY);
        engine.file(TEST_ILK, "duty", DUTY_5PCT);
        engine.slip(TEST_ILK, alice, int256(1000e18));

        vm.startPrank(alice);
        uint256 vaultId = engine.open(TEST_ILK, alice);
        engine.frob(vaultId, alice, alice, int256(1000e18), int256(500e18));
        vm.stopPrank();

        skip(1 days);

        vm.expectRevert(FeeRecipientNotSet.selector);
        engine.drip(TEST_ILK);
    }

    function test_dripNoOpAfterCage() public {
        vaultEngine.file(TEST_ILK, "duty", DUTY_5PCT);
        _openTestVault(alice, 1000e18, 500e18);

        skip(30 days);

        uint256 frozen = vaultEngine.drip(TEST_ILK);

        vaultEngine.cage();

        skip(365 days);

        uint256 debtBefore = vaultEngine.debt();

        // Post-cage drip returns the frozen rate without accruing.
        assertEq(vaultEngine.drip(TEST_ILK), frozen, "rate frozen after cage");
        assertEq(vaultEngine.debt(), debtBefore, "no accrual after cage");
    }

    /* ========================== 3. AUTO-DRIP ========================== */

    function test_frobAutoDripsOnDebtChange() public {
        vaultEngine.file(TEST_ILK, "duty", DUTY_5PCT);

        uint256 vaultId = _openTestVault(alice, 1000e18, 100e18);

        skip(365 days);

        // Borrowing after a gap: frob must accrue first, so the new debt is priced at the compounded rate.
        vm.prank(alice);
        vaultEngine.frob(vaultId, alice, alice, 0, int256(100e18));

        uint256 expectedRate = Math.rmul(Math.rpow(DUTY_5PCT, 365 days, _RAY), _RAY);

        assertEq(_rate(TEST_ILK), expectedRate, "frob dripped before pricing debt");
        assertEq(vaultEngine.usdr(alice), 100e18 * _RAY + 100e18 * expectedRate, "second draw at accrued rate");
    }

    function test_frobCollateralOnlyChangeDoesNotRequireDrip() public {
        vaultEngine.file(TEST_ILK, "duty", DUTY_5PCT);

        uint256 vaultId = _openTestVault(alice, 1000e18, 100e18);
        (, , , , , , , uint256 rhoBefore) = vaultEngine.ilks(TEST_ILK);

        skip(30 days);

        // Pure collateral top-up (dart == 0): no drip needed, rate untouched.
        vaultEngine.slip(TEST_ILK, alice, int256(10e18));

        vm.prank(alice);
        vaultEngine.frob(vaultId, alice, alice, int256(10e18), 0);

        (, , , , , , , uint256 rhoAfter) = vaultEngine.ilks(TEST_ILK);

        assertEq(rhoAfter, rhoBefore, "no drip on collateral-only frob");
    }

    function test_fileDutyDripsFirstNoRetroactiveApplication() public {
        _openTestVault(alice, 1000e18, 500e18);

        // Zero fee for a year...
        skip(365 days);

        // ...then a high duty is filed. The elapsed year must accrue at the OLD duty (RAY, zero fee): filing must not
        // apply the new duty retroactively over the gap.
        vaultEngine.file(TEST_ILK, "duty", DUTY_100PCT);

        assertEq(_rate(TEST_ILK), _RAY, "gap accrued at old (zero) duty");

        // Symmetric direction: accrue at the high duty, then file a lower one; the gap uses the old HIGH duty.
        skip(365 days);

        uint256 expected = Math.rmul(Math.rpow(DUTY_100PCT, 365 days, _RAY), _RAY);

        vaultEngine.file(TEST_ILK, "duty", DUTY_5PCT);

        assertEq(_rate(TEST_ILK), expected, "gap accrued at old (high) duty");
    }

    /* ========================== 4. DUST & LIQUIDATION AT RATE > RAY ========================== */

    function test_dustCheckUsesRadTabAtAccruedRate() public {
        vaultEngine.file(TEST_ILK, "duty", DUTY_5PCT);
        vaultEngine.file(TEST_ILK, "dust", 100 * _RAD);

        uint256 vaultId = _openTestVault(alice, 1000e18, 200e18);

        skip(365 days);

        vaultEngine.drip(TEST_ILK);

        uint256 rate = _rate(TEST_ILK);

        // Fund alice with extra internal USDR: repaying at the accrued rate costs more rad than was drawn.
        vaultEngine.suck(address(this), alice, 100 * _RAD);

        // Repay down to just under dust in rad terms: art * rate < dust must revert.
        uint256 targetArt = (99 * _RAD) / rate;
        int256 dart = -int256(200e18 - targetArt);

        vm.prank(alice);
        vm.expectRevert(IVaultEngine.DustAmount.selector);
        vaultEngine.frob(vaultId, alice, alice, 0, dart);

        // Repaying to zero is always allowed.
        vm.prank(alice);
        vaultEngine.frob(vaultId, alice, alice, 0, -int256(200e18));
    }

    function test_barkUsesFreshRateAndThresholdMathAtRateAboveRay() public {
        // RAIN priced at 1: spot = 0.25 (mat 400%). A vault at 800 ink / 190 art is safe with headroom, then fees
        // push it below the bark threshold with NO price move.
        _setRainPrice(1e18);

        uint256 vaultId = _openRainVault(address(this), 800e18, 190e18);

        vaultEngine.file(RAIN_ILK, "duty", DUTY_100PCT);

        // Not yet unsafe at the current rate (barkFactor 65%: threshold at 190 * 1.0 vs 800 * 0.25 * ... ).
        vm.expectRevert(ILiquidationTrigger.NotUnsafe.selector);
        liquidationTrigger.bark(vaultId, address(this));

        // A year of ~100% APY roughly doubles the debt: the vault becomes barkable purely through accrual. bark
        // must drip first (fresh rate) so the unsafe check and the tab see the accrued debt.
        skip(365 days);

        uint256 id = liquidationTrigger.bark(vaultId, address(this));

        assertGt(id, 0, "auction kicked");

        uint256 rate = _rate(RAIN_ILK);

        assertGt(rate, (_RAY * 199) / 100, "rate roughly doubled");

        // The auction tab reflects the accrued debt times the penalty (chop 113%).
        (, uint256 tab, , , , , ) = dutchAuction.sales(id);

        assertGt(tab, 190e18 * rate, "tab includes accrued fees plus penalty");
    }

    /* ========================== HELPERS ========================== */

    function _setRainPrice(uint256 price) internal {
        rainPriceSource.setPrice(price);
        vm.warp(((vm.getBlockTimestamp() / 1800) + 2) * 1800);
        osm.poke(RAIN_ILK);
        vm.warp(vm.getBlockTimestamp() + 3600);
        osm.poke(RAIN_ILK);
        priceConverter.poke(RAIN_ILK);
    }

    /// @dev Mirror of LiquidationTest's vault opening helper for the RAIN ilk.
    function _openRainVault(address who, uint256 ink, uint256 art) internal returns (uint256 vaultId) {
        rain.mint(who, ink);

        vm.startPrank(who);
        rain.approve(address(collateralAdapter), ink);
        collateralAdapter.join(RAIN_ILK, who, ink);
        vaultId = vaultEngine.open(RAIN_ILK, who);
        vaultEngine.frob(vaultId, who, who, int256(ink), int256(art));
        vm.stopPrank();
    }
}

/// @dev Bare VaultEngine deployment used to exercise the unset-feeRecipient error path.
contract VaultEngineHarness is VaultEngine {}
