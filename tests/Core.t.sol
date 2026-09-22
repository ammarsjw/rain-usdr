// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { ICollateralAdapter } from "../contracts/interfaces/ICollateralAdapter.sol";
import { ILiquidationTrigger } from "../contracts/interfaces/ILiquidationTrigger.sol";
import { IVaultEngine } from "../contracts/interfaces/IVaultEngine.sol";
import { Math } from "../contracts/libraries/Math.sol";
import {
    FeeRecipientNotSet,
    IlkAlreadyInitialized,
    InvalidAddress,
    InvalidAmount,
    InvalidAssignment,
    InvalidDuty,
    NotLive,
    UnrecognizedParameter
} from "../contracts/shared/Errors.sol";
import { _RAD, _RAY, _USDR_ILK } from "../contracts/shared/Constants.sol";

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { BaseTest } from "./shared/BaseTest.sol";
import { VaultEngineHarness } from "./shared/VaultEngineHarness.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockFeeOnTransferERC20 } from "./mocks/MockFeeOnTransferERC20.sol";

/* ========================== VAULT ENGINE CORE ========================== */

/**
 * @title VaultEngineCoreTest
 * @author Rain Team
 * @notice Adversarial coverage of the core ledger: authorization, conservation, overflow behaviour,
 *         permissions and vault lifecycle.
 */
contract VaultEngineCoreTest is BaseTest {
    /// @dev This suite asserts global conservation figures (e.g. debt == 0 after a round trip), which the
    ///      shared baseline seed would skew. TEST-A is not a volatile ilk, so no draw here faces the
    ///      solvency gate and an empty starting reserve is safe.
    function _baselineReserve() internal pure override returns (uint256) {
        return 0;
    }

    bytes32 internal constant TEST_ILK = "TEST-A";

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public override {
        super.setUp();

        // A clean, unconstrained ilk for arithmetic probing.
        vaultEngine.init(TEST_ILK);
        vaultEngine.file(TEST_ILK, "line", type(uint256).max / 2);
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

    /* ========================== 1. AUTHORIZATION ========================== */

    function test_wardGatesAreEnforced() public {
        vm.startPrank(alice);

        vm.expectRevert();
        vaultEngine.init("EVIL-A");

        vm.expectRevert();
        vaultEngine.file("globalLine", type(uint256).max);

        vm.expectRevert();
        vaultEngine.file(TEST_ILK, "spot", type(uint256).max);

        vm.expectRevert();
        vaultEngine.slip(TEST_ILK, alice, int256(1e30));

        vm.expectRevert();
        vaultEngine.grab(1, alice, alice, 0, 0);

        vm.expectRevert();
        vaultEngine.suck(alice, alice, 1e45);

        vm.expectRevert();
        vaultEngine.cage();

        vm.stopPrank();
    }

    function test_initRejectsDuplicate() public {
        vm.expectRevert(IlkAlreadyInitialized.selector);
        vaultEngine.init(TEST_ILK);
    }

    function test_fileRejectsUnknownKeysAndRespectsCage() public {
        vm.expectRevert(UnrecognizedParameter.selector);
        vaultEngine.file("nonsense", 1);

        vm.expectRevert(UnrecognizedParameter.selector);
        vaultEngine.file(TEST_ILK, "nonsense", 1);

        vaultEngine.cage();

        vm.expectRevert(NotLive.selector);
        vaultEngine.file("globalLine", 1);

        vm.expectRevert(NotLive.selector);
        vaultEngine.file(TEST_ILK, "spot", 1);
    }

    /* ========================== 2. OPEN ========================== */

    function test_openAssignsSequentialIdsAndBindings() public {
        vm.prank(alice);
        uint256 first = vaultEngine.open(TEST_ILK, alice);

        vm.prank(bob);
        uint256 second = vaultEngine.open(TEST_ILK, bob);

        assertEq(second, first + 1, "sequential ids");
        assertEq(vaultEngine.ownerOf(first), alice, "owner binding");
        assertEq(vaultEngine.ilkOf(first), TEST_ILK, "ilk binding");
        assertEq(vaultEngine.vaultCount(), second, "count tracks latest");
    }

    function test_openForThirdPartyAssignsOwnershipToUsr() public {
        // A router opens on behalf of a user: the vault belongs to the user, not the router.
        vm.prank(bob);
        uint256 vaultId = vaultEngine.open(TEST_ILK, alice);

        assertEq(vaultEngine.ownerOf(vaultId), alice, "usr owns, not caller");
    }

    function test_openRejectsUnknownIlkZeroUsrAndCage() public {
        vm.expectRevert(IVaultEngine.IlkNotInitialized.selector);
        vaultEngine.open("UNKNOWN-A", alice);

        vm.expectRevert(InvalidAddress.selector);
        vaultEngine.open(TEST_ILK, address(0));

        vaultEngine.cage();

        vm.expectRevert(NotLive.selector);
        vaultEngine.open(TEST_ILK, alice);
    }

    /* ========================== 3. FROB CONSERVATION ========================== */

    function test_frobRoundTripConservesAllBalances() public {
        uint256 vaultId = _openTestVault(alice, 1000e18, 500e18);

        vm.prank(alice);
        vaultEngine.frob(vaultId, alice, alice, -int256(1000e18), -int256(500e18));

        (uint256 ink, uint256 art) = vaultEngine.urns(vaultId);
        (uint256 globalArt, uint256 globalInk, , , , , , ) = vaultEngine.ilks(TEST_ILK);

        assertEq(ink, 0, "ink zeroed");
        assertEq(art, 0, "art zeroed");
        assertEq(globalArt, 0, "globalArt zeroed");
        assertEq(globalInk, 0, "globalInk zeroed");
        assertEq(vaultEngine.debt(), 0, "debt zeroed");
        assertEq(vaultEngine.collateral(TEST_ILK, alice), 1000e18, "free collateral restored");
        assertEq(vaultEngine.usdr(alice), 0, "usdr zeroed");
    }

    function test_frobMovesCollateralFromVAndUsdrToW() public {
        vaultEngine.slip(TEST_ILK, alice, int256(1000e18));

        vm.prank(alice);
        uint256 vaultId = vaultEngine.open(TEST_ILK, alice);

        // Alice permits bob to manage her positions; bob supplies nothing.
        vm.prank(alice);
        vaultEngine.hope(bob);

        // Collateral drawn from v = alice, USDR paid to w = bob.
        vm.prank(bob);
        vaultEngine.frob(vaultId, alice, bob, int256(1000e18), int256(100e18));

        assertEq(vaultEngine.collateral(TEST_ILK, alice), 0, "v debited");
        assertEq(vaultEngine.usdr(bob), 100e18 * _RAY, "w credited");
    }

    function test_frobDustBoundaryExactAndOneWeiBelow() public {
        vaultEngine.file(TEST_ILK, "dust", 100 * _RAD);
        vaultEngine.slip(TEST_ILK, alice, int256(1000e18));

        vm.startPrank(alice);
        uint256 vaultId = vaultEngine.open(TEST_ILK, alice);

        // One wei of art below dust reverts.
        vm.expectRevert(IVaultEngine.DustAmount.selector);
        vaultEngine.frob(vaultId, alice, alice, int256(1000e18), int256(100e18 - 1));

        // Exactly dust passes.
        vaultEngine.frob(vaultId, alice, alice, int256(1000e18), int256(100e18));
        vm.stopPrank();
    }

    function test_frobCeilingBoundaries() public {
        vaultEngine.file(TEST_ILK, "line", 100 * _RAD);
        vaultEngine.slip(TEST_ILK, alice, int256(1000e18));

        vm.startPrank(alice);
        uint256 vaultId = vaultEngine.open(TEST_ILK, alice);

        // One wei over the ilk line reverts.
        vm.expectRevert(IVaultEngine.CeilingExceeded.selector);
        vaultEngine.frob(vaultId, alice, alice, int256(1000e18), int256(100e18 + 1));

        // Exactly at the line passes.
        vaultEngine.frob(vaultId, alice, alice, int256(1000e18), int256(100e18));
        vm.stopPrank();

        // The global line binds independently of the ilk line.
        vaultEngine.file(TEST_ILK, "line", 200 * _RAD);
        uint256 debtNow = vaultEngine.debt();
        vaultEngine.file("globalLine", debtNow);

        vaultEngine.slip(TEST_ILK, bob, int256(1000e18));

        vm.startPrank(bob);
        uint256 bobVault = vaultEngine.open(TEST_ILK, bob);
        vm.expectRevert(IVaultEngine.CeilingExceeded.selector);
        vaultEngine.frob(bobVault, bob, bob, int256(1000e18), int256(1));
        vm.stopPrank();
    }

    function test_frobRepaymentBypassesCeilings() public {
        uint256 vaultId = _openTestVault(alice, 1000e18, 500e18);

        // Ceilings slam shut afterwards; repayment must still pass (dart <= 0 short-circuits the check).
        vaultEngine.file(TEST_ILK, "line", 0);
        vaultEngine.file("globalLine", 0);

        vm.prank(alice);
        vaultEngine.frob(vaultId, alice, alice, 0, -int256(100e18));

        (, uint256 art) = vaultEngine.urns(vaultId);
        assertEq(art, 400e18, "repaid despite zero ceilings");
    }

    /* ========================== 4. OVERFLOW BEHAVIOUR ========================== */

    function test_frobSafetyCheckOverflowRevertsDecodably() public {
        // ink * spot overflows 2^256 at a reachable collateral size: the revert must be the library's
        // decodable MulOverflow, never a raw arithmetic panic.
        vaultEngine.file(TEST_ILK, "spot", 100_000 * _RAY);

        uint256 hugeInk = type(uint256).max / (100_000 * _RAY) + 1;

        vaultEngine.slip(TEST_ILK, alice, int256(hugeInk));

        vm.startPrank(alice);
        uint256 vaultId = vaultEngine.open(TEST_ILK, alice);
        vaultEngine.frob(vaultId, alice, alice, int256(hugeInk), 0);

        // The safety check multiplies ink * spot on any risk-increasing change.
        vm.expectRevert(Math.MulOverflow.selector);
        vaultEngine.frob(vaultId, alice, alice, 0, 1);

        // Critically, the position is NOT bricked: deleveraging out of the overflow zone works because the
        // pure top-up/repay path skips the safety check.
        vaultEngine.frob(vaultId, alice, alice, -int256(hugeInk / 2), 0);
        vm.stopPrank();

        (uint256 ink, ) = vaultEngine.urns(vaultId);
        assertEq(ink, hugeInk - hugeInk / 2, "deleveraged out");
    }

    /* ========================== 5. PERMISSIONS (hope/nope) ========================== */

    function test_hopeNopeLifecycle() public {
        uint256 vaultId = _openTestVault(alice, 1000e18, 0);

        // Bob cannot draw against alice's vault.
        vm.prank(bob);
        vm.expectRevert(IVaultEngine.NotAllowed.selector);
        vaultEngine.frob(vaultId, bob, bob, 0, int256(1e18));

        // Alice hopes bob; bob can now manage (still needs his own w consent, which he has as sender).
        vm.prank(alice);
        vaultEngine.hope(bob);

        vm.prank(bob);
        vaultEngine.frob(vaultId, bob, bob, 0, int256(1e18));

        // Nope revokes.
        vm.prank(alice);
        vaultEngine.nope(bob);

        vm.prank(bob);
        vm.expectRevert(IVaultEngine.NotAllowed.selector);
        vaultEngine.frob(vaultId, bob, bob, 0, int256(1e18));
    }

    function test_frobRequiresVConsentForCollateralAndWConsentForUsdr() public {
        vaultEngine.slip(TEST_ILK, bob, int256(1000e18));

        vm.prank(alice);
        uint256 vaultId = vaultEngine.open(TEST_ILK, alice);

        // Alice cannot pull bob's free collateral without his consent.
        vm.prank(alice);
        vm.expectRevert(IVaultEngine.NotAllowed.selector);
        vaultEngine.frob(vaultId, bob, alice, int256(1000e18), 0);

        // Bob consents; now alice can lock bob's collateral into her vault.
        vm.prank(bob);
        vaultEngine.hope(alice);

        vm.prank(alice);
        vaultEngine.frob(vaultId, bob, alice, int256(1000e18), 0);

        // Repaying with bob's internal USDR requires his consent too. Fund bob via a draw to him first.
        vm.prank(alice);
        vaultEngine.frob(vaultId, alice, bob, 0, int256(10e18));

        vm.prank(bob);
        vaultEngine.nope(alice);

        vm.prank(alice);
        vm.expectRevert(IVaultEngine.NotAllowed.selector);
        vaultEngine.frob(vaultId, alice, bob, 0, -int256(10e18));
    }

    function test_fluxAndMoveRequireConsent() public {
        vaultEngine.slip(TEST_ILK, alice, int256(100e18));

        vm.prank(bob);
        vm.expectRevert(IVaultEngine.NotAllowed.selector);
        vaultEngine.flux(TEST_ILK, alice, bob, 100e18);

        vm.prank(alice);
        vaultEngine.flux(TEST_ILK, alice, bob, 100e18);
        assertEq(vaultEngine.collateral(TEST_ILK, bob), 100e18, "flux by owner");

        vaultEngine.suck(address(this), alice, 5 * _RAD);

        vm.prank(bob);
        vm.expectRevert(IVaultEngine.NotAllowed.selector);
        vaultEngine.move(alice, bob, 5 * _RAD);

        vm.prank(alice);
        vaultEngine.hope(bob);

        vm.prank(bob);
        vaultEngine.move(alice, bob, 5 * _RAD);
        assertEq(vaultEngine.usdr(bob), 5 * _RAD, "move by operator");
    }

    /* ========================== 6. SUCK / HEAL / GRAB ACCOUNTING ========================== */

    function test_suckCreatesMatchedDebtAndVice() public {
        uint256 debtBefore = vaultEngine.debt();

        vaultEngine.suck(alice, bob, 7 * _RAD);

        assertEq(vaultEngine.sin(alice), 7 * _RAD, "sin");
        assertEq(vaultEngine.usdr(bob), 7 * _RAD, "usdr");
        assertEq(vaultEngine.vice(), 7 * _RAD, "vice");
        assertEq(vaultEngine.debt(), debtBefore + 7 * _RAD, "debt");
    }

    function test_healCancelsOwnSinAgainstOwnUsdr() public {
        vaultEngine.suck(address(this), address(this), 9 * _RAD);

        vaultEngine.heal(4 * _RAD);

        assertEq(vaultEngine.sin(address(this)), 5 * _RAD, "sin reduced");
        assertEq(vaultEngine.usdr(address(this)), 5 * _RAD, "usdr reduced");
        assertEq(vaultEngine.vice(), 5 * _RAD, "vice reduced");
    }

    function test_healAndGrabWorkAfterCage() public {
        // Settlement path: both must remain callable post-cage (End depends on it).
        uint256 vaultId = _openTestVault(alice, 100e18, 10e18);

        vaultEngine.suck(address(this), address(this), 3 * _RAD);
        vaultEngine.cage();

        vaultEngine.heal(3 * _RAD);
        assertEq(vaultEngine.sin(address(this)), 0, "healed after cage");

        vaultEngine.grab(vaultId, address(this), address(this), -int256(100e18), -int256(10e18));

        (uint256 ink, uint256 art) = vaultEngine.urns(vaultId);
        assertEq(ink, 0, "grabbed after cage");
        assertEq(art, 0, "grabbed after cage");
    }

    function test_grabRejectsUnopenedVault() public {
        vm.expectRevert(IVaultEngine.VaultNotFound.selector);
        vaultEngine.grab(999_999, address(this), address(this), 0, 0);
    }

    /* ========================== 7. FUZZ ========================== */

    function testFuzz_frobConservation(uint96 inkSeed, uint96 artSeed) public {
        uint256 ink = uint256(inkSeed) + 1e18;

        // Art is bounded by both the collateral (spot = RAY) and the harness's global line (1.1M rad).
        uint256 art = uint256(artSeed) % ink;
        art = art % (1_000_000e18);

        uint256 vaultId = _openTestVault(alice, ink, art);

        (uint256 storedInk, uint256 storedArt) = vaultEngine.urns(vaultId);
        (uint256 globalArt, uint256 globalInk, , , , , , ) = vaultEngine.ilks(TEST_ILK);

        assertEq(storedInk, ink, "ink stored");
        assertEq(storedArt, art, "art stored");
        assertEq(globalInk, ink, "globalInk aggregates");
        assertEq(globalArt, art, "globalArt aggregates");
        assertEq(vaultEngine.usdr(alice), art * _RAY, "usdr = art x rate");
    }

    function testFuzz_openBindsArbitraryOwners(address usr) public {
        vm.assume(usr != address(0));

        uint256 vaultId = vaultEngine.open(TEST_ILK, usr);

        assertEq(vaultEngine.ownerOf(vaultId), usr, "arbitrary owner bound");
    }
}

/* ========================== COLLATERAL ADAPTER & USDR TOKEN ========================== */

/**
 * @title TokenAdapterTest
 * @author Rain Team
 * @notice Adversarial coverage of the Collateral Adapter and USDR token: decimal conversion, balance-delta
 *         enforcement (H-2), mint/burn authority and lifecycle guards.
 */
contract TokenAdapterTest is BaseTest {
    address internal alice = address(0xA11CE);

    /* ========================== 1. FEE-ON-TRANSFER ========================== */

    function test_joinRevertsOnFeeOnTransferToken() public {
        // A 1% fee token registered as collateral must be unusable: join measures the received delta and
        // refuses any shortfall, so the shared adapter can never be silently under-collateralized.
        MockFeeOnTransferERC20 feeToken = new MockFeeOnTransferERC20("Fee Token", "FEE", 18, 100);
        bytes32 feeIlk = "FEE-A";

        collateralAdapter.init(feeIlk, IERC20Metadata(address(feeToken)));

        feeToken.mint(alice, 1000e18);

        vm.startPrank(alice);
        feeToken.approve(address(collateralAdapter), 1000e18);

        vm.expectRevert(ICollateralAdapter.FeeOnTransferToken.selector);
        collateralAdapter.join(feeIlk, alice, 1000e18);
        vm.stopPrank();
    }

    function test_joinWithZeroFeePasses() public {
        // The same token with the fee switched off behaves like a normal ERC-20 and joins cleanly.
        MockFeeOnTransferERC20 feeToken = new MockFeeOnTransferERC20("Fee Token", "FEE", 18, 0);
        bytes32 feeIlk = "FEE-B";

        collateralAdapter.init(feeIlk, IERC20Metadata(address(feeToken)));

        feeToken.mint(alice, 1000e18);

        vm.startPrank(alice);
        feeToken.approve(address(collateralAdapter), 1000e18);
        collateralAdapter.join(feeIlk, alice, 1000e18);
        vm.stopPrank();

        assertEq(vaultEngine.collateral(feeIlk, alice), 1000e18, "full amount credited");
    }

    /* ========================== 2. DECIMAL CONVERSION ========================== */

    function test_sixDecimalRoundTripExact() public {
        usdt.mint(alice, 123_456789); // 123.456789 USDT.

        vm.startPrank(alice);
        usdt.approve(address(collateralAdapter), 123_456789);
        collateralAdapter.join(USDT_ILK, alice, 123_456789);

        assertEq(vaultEngine.collateral(USDT_ILK, alice), 123_456789 * 1e12, "scaled to 18 decimals");

        collateralAdapter.exit(USDT_ILK, alice, 123_456789);
        vm.stopPrank();

        assertEq(usdt.balanceOf(alice), 123_456789, "round trip exact");
        assertEq(vaultEngine.collateral(USDT_ILK, alice), 0, "ledger cleared");
    }

    function test_initRejectsAboveEighteenDecimals() public {
        MockERC20 weird = new MockERC20("Weird", "W24", 24);

        vm.expectRevert(ICollateralAdapter.InvalidDecimals.selector);
        collateralAdapter.init("W24-A", IERC20Metadata(address(weird)));
    }

    function test_initRejectsDuplicateAndZeroToken() public {
        vm.expectRevert(IlkAlreadyInitialized.selector);
        collateralAdapter.init(USDT_ILK, IERC20Metadata(address(usdt)));

        vm.expectRevert(InvalidAddress.selector);
        collateralAdapter.init("NEW-A", IERC20Metadata(address(0)));
    }

    /* ========================== 3. LIFECYCLE GUARDS ========================== */

    function test_zeroAmountJoinAndExitRevert() public {
        vm.startPrank(alice);

        vm.expectRevert(InvalidAmount.selector);
        collateralAdapter.join(USDT_ILK, alice, 0);

        vm.expectRevert(InvalidAmount.selector);
        collateralAdapter.exit(USDT_ILK, alice, 0);

        vm.expectRevert(InvalidAmount.selector);
        collateralAdapter.join(_USDR_ILK, alice, 0);

        vm.stopPrank();
    }

    function test_unregisteredIlkJoinExitAndCageRevert() public {
        vm.expectRevert(InvalidAddress.selector);
        collateralAdapter.join("GHOST-A", alice, 1);

        vm.expectRevert(InvalidAddress.selector);
        collateralAdapter.exit("GHOST-A", alice, 1);

        // L-7: caging an unregistered ilk must fail loudly, not silently succeed.
        vm.expectRevert(InvalidAddress.selector);
        collateralAdapter.cage("GHOST-A");
    }

    function test_cageBlocksDepositsButNotWithdrawals() public {
        usdt.mint(alice, 100e6);

        vm.startPrank(alice);
        usdt.approve(address(collateralAdapter), 100e6);
        collateralAdapter.join(USDT_ILK, alice, 50e6);
        vm.stopPrank();

        collateralAdapter.cage(USDT_ILK);

        vm.startPrank(alice);
        vm.expectRevert(NotLive.selector);
        collateralAdapter.join(USDT_ILK, alice, 50e6);

        // Withdrawal continues to work after cage.
        collateralAdapter.exit(USDT_ILK, alice, 50e6);
        vm.stopPrank();

        assertEq(usdt.balanceOf(alice), 100e6, "withdrawal after cage");
    }

    /* ========================== 4. USDR TOKEN ========================== */

    function test_usdrMintIsWardGatedAndRejectsZero() public {
        vm.prank(alice);
        vm.expectRevert();
        usdr.mint(alice, 1e18);

        vm.expectRevert(InvalidAmount.selector);
        usdr.mint(alice, 0);
    }

    function test_usdrBurnRequiresAllowanceUnlessBurnerOrSelf() public {
        usdr.mint(alice, 100e18);

        // A stranger without allowance cannot burn alice's tokens.
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        usdr.burn(alice, 1e18);

        // Self-burn works without allowance.
        vm.prank(alice);
        usdr.burn(alice, 1e18);

        // L-9: zero burns are rejected.
        vm.prank(alice);
        vm.expectRevert(InvalidAmount.selector);
        usdr.burn(alice, 0);

        // The adapter (BURNER_ROLE) burns without allowance, repayment UX.
        vm.prank(address(collateralAdapter));
        usdr.burn(alice, 1e18);

        assertEq(usdr.balanceOf(alice), 98e18, "burn accounting");
    }

    /* ========================== 5. USDR JOIN/EXIT (internal <-> ERC-20) ========================== */

    function test_usdrJoinExitRoundTrip() public {
        // Mint via the PSM to get real internal balance behind the ERC-20.
        usdt.mint(alice, 100e6);

        vm.startPrank(alice);
        usdt.approve(address(psm), 100e6);
        psm.sellStable(USDT_ILK, alice, 100e6);

        // ERC-20 -> internal.
        collateralAdapter.join(_USDR_ILK, alice, 40e18);
        assertEq(usdr.balanceOf(alice), 60e18, "ERC-20 burned");
        assertEq(vaultEngine.usdr(alice), 40e18 * _RAY, "internal credited");

        // Internal -> ERC-20 (requires hope, granted in Base? no, the adapter moves the caller's balance).
        vaultEngine.hope(address(collateralAdapter));
        collateralAdapter.exit(_USDR_ILK, alice, 40e18);
        vm.stopPrank();

        assertEq(usdr.balanceOf(alice), 100e18, "restored");
        assertEq(vaultEngine.usdr(alice), 0, "internal cleared");
    }

    /* ========================== 6. FUZZ ========================== */

    function testFuzz_sixDecimalJoinExitConservation(uint64 amountSeed) public {
        uint256 amount = (uint256(amountSeed) % 1_000_000e6) + 1;

        usdt.mint(alice, amount);

        vm.startPrank(alice);
        usdt.approve(address(collateralAdapter), amount);
        collateralAdapter.join(USDT_ILK, alice, amount);
        collateralAdapter.exit(USDT_ILK, alice, amount);
        vm.stopPrank();

        assertEq(usdt.balanceOf(alice), amount, "conservation");
        assertEq(vaultEngine.collateral(USDT_ILK, alice), 0, "no residue");
    }
}

/* ========================== STABILITY FEE (VaultEngine accrual logic) ========================== */

/**
 * @title StabilityFeeTest
 * @author Rain Team
 * @notice Coverage of stability fee accrual: drip idempotency and compounding, fee crediting, frob and bark
 *         auto-drip, non-retroactive duty changes, dust and liquidation math at rate > RAY, and the post-cage
 *         freeze.
 */
contract StabilityFeeTest is BaseTest {
    bytes32 internal constant TEST_ILK = "TEST-A";

    /// @dev Per-second factor for roughly 5% APY: 1.05^(1/31536000) scaled to ray.
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

    function test_fileDutyRevertsOnUninitializedIlk() public {
        // The drip inside file("duty") is non-fatal now, so the uninitialized-ilk guard must hold explicitly:
        // filing a duty on an unknown ilk must not silently succeed.
        vm.expectRevert(IVaultEngine.IlkNotInitialized.selector);
        vaultEngine.file("UNKNOWN-A", "duty", _RAY);
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

        // Reuse the shared engine by unsetting is impossible (file rejects zero), so deploy expectations
        // directly: this test uses a dedicated assertion on the shared engine by checking the error path via
        // a mock is unnecessary, instead verify the error surfaces from a brand-new engine.
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

    function test_frobDripsUnconditionallyIncludingCollateralOnlyChanges() public {
        // Audit H-1: a pure collateral change must ALSO drip. The dangerous branch is a withdrawal (dink < 0,
        // dart == 0): its safety check prices the debt as art * rate, and a stale rate there understates the
        // debt by the entire undripped accrual, authorizing withdrawals the true debt would forbid.
        vaultEngine.file(TEST_ILK, "duty", DUTY_5PCT);

        uint256 vaultId = _openTestVault(alice, 1000e18, 100e18);
        (, , , , , , , uint256 rhoBefore) = vaultEngine.ilks(TEST_ILK);

        skip(30 days);

        // Collateral top-up (dart == 0): the rate must be brought current anyway.
        vaultEngine.slip(TEST_ILK, alice, int256(10e18));

        vm.prank(alice);
        vaultEngine.frob(vaultId, alice, alice, int256(10e18), 0);

        (, , , , , , , uint256 rhoAfter) = vaultEngine.ilks(TEST_ILK);

        assertEq(rhoAfter, rhoBefore + 30 days, "collateral-only frob drips");
        assertGt(_rate(TEST_ILK), _RAY, "rate accrued");
    }

    function test_collateralWithdrawalPricedAtFreshRate() public {
        // Audit H-1, the attack shape: draw at rate RAY, wait years without any drip, then withdraw
        // collateral down to the minimum the STALE rate would allow. With the fix, frob drips first, so the
        // withdrawal is checked against the true accrued debt and reverts.
        vaultEngine.file(TEST_ILK, "duty", DUTY_5PCT);

        uint256 vaultId = _openTestVault(alice, 1000e18, 100e18);

        // 10 years undripped: nobody touches the ilk.
        skip(3650 days);

        // Stale-rate math would allow withdrawing down to 100 ink (spot = 1, art = 100, rate stale at RAY).
        // True rate after 10 years at 5% APY is ~1.628: minimum safe ink is ~163.
        vm.prank(alice);
        vm.expectRevert(IVaultEngine.NotSafe.selector);
        vaultEngine.frob(vaultId, alice, alice, -int256(900e18), 0);

        // A withdrawal that IS safe at the true rate still works (leave 200 > ~163).
        vm.prank(alice);
        vaultEngine.frob(vaultId, alice, alice, -int256(800e18), 0);

        // And the rate was genuinely accrued in the process.
        assertGt(_rate(TEST_ILK), (_RAY * 162) / 100, "true rate applied");
    }

    function test_fileDutyDripsFirstNoRetroactiveApplication() public {
        _openTestVault(alice, 1000e18, 500e18);

        // Zero fee for a year...
        skip(365 days);

        // ...then a high duty is filed. The elapsed year must accrue at the OLD duty (RAY, zero fee): filing
        // must not apply the new duty retroactively over the gap.
        vaultEngine.file(TEST_ILK, "duty", DUTY_100PCT);

        assertEq(_rate(TEST_ILK), _RAY, "gap accrued at old (zero) duty");

        // Symmetric direction: accrue at the high duty, then file a lower one; the gap uses the old HIGH
        // duty.
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
        // RAIN priced at 1: spot = 0.25 (mat 400%). A vault at 800 ink / 190 art is safe with headroom, then
        // fees push it below the bark threshold with NO price move.
        _setRainPrice(1e18);

        // Seed the stable reserve BEFORE the draw: the solvency gate measures the post-change position, so
        // the opening draw itself must be covered by the reserve (stressed loss ~50e18 at these numbers).
        usdt.mint(address(this), 100e6);
        usdt.approve(address(psm), 100e6);
        psm.sellStable(USDT_ILK, address(this), 100e6);

        // Advance one block so the inflow counts as settled reserve (audit H05: same-block inflow is
        // discounted from the effective reserve).
        vm.roll(vm.getBlockNumber() + 1);

        uint256 vaultId = _openRainVault(address(this), 800e18, 190e18);

        vaultEngine.file(RAIN_ILK, "duty", DUTY_100PCT);

        // Not yet unsafe at the current rate (barkFactor 65%: threshold at 190 * 1.0 vs 800 * 0.25 * ... ).
        vm.expectRevert(ILiquidationTrigger.NotUnsafe.selector);
        liquidationTrigger.bark(vaultId, address(this));

        // A year of ~100% APY roughly doubles the debt: the vault becomes barkable purely through accrual.
        // bark must drip first (fresh rate) so the unsafe check and the tab see the accrued debt.
        skip(365 days);

        uint256 id = liquidationTrigger.bark(vaultId, address(this));

        assertGt(id, 0, "auction kicked");

        uint256 rate = _rate(RAIN_ILK);

        assertGt(rate, (_RAY * 199) / 100, "rate roughly doubled");

        // The auction tab reflects the accrued debt times the penalty (chop 113%).
        (, uint256 tab, , , , , ) = dutchAuction.sales(id);

        assertGt(tab, 190e18 * rate, "tab includes accrued fees plus penalty");
    }

    /* ========================== 5. FEE EXEMPTION (C-1) ========================== */

    function test_exemptFeePinsDutyToRay() public {
        // Audit C-1: a fee-exempt ilk rejects any duty above RAY, forever. Filing RAY itself stays legal
        // (no-op).
        vaultEngine.exemptFee(TEST_ILK);

        vm.expectRevert(InvalidDuty.selector);
        vaultEngine.file(TEST_ILK, "duty", DUTY_5PCT);

        vm.expectRevert(InvalidDuty.selector);
        vaultEngine.file(TEST_ILK, "duty", _RAY + 1);

        vaultEngine.file(TEST_ILK, "duty", _RAY);

        (, , uint256 rate, , , , uint256 duty, ) = vaultEngine.ilks(TEST_ILK);
        assertEq(duty, _RAY, "duty pinned");
        assertEq(rate, _RAY, "rate pinned");
    }

    function test_exemptFeeGuards() public {
        // Uninitialized ilk: rejected.
        vm.expectRevert(IVaultEngine.IlkNotInitialized.selector);
        vaultEngine.exemptFee("GHOST-A");

        // An ilk whose duty has already left RAY: rejected (the invariant the flag pins is already broken).
        vaultEngine.file(TEST_ILK, "duty", DUTY_5PCT);

        vm.expectRevert(InvalidAssignment.selector);
        vaultEngine.exemptFee(TEST_ILK);

        // Resetting duty alone is not enough once fees have accrued into the rate.
        _openTestVault(alice, 1000e18, 100e18);
        skip(365 days);
        vaultEngine.drip(TEST_ILK);
        vaultEngine.file(TEST_ILK, "duty", _RAY);

        vm.expectRevert(InvalidAssignment.selector);
        vaultEngine.exemptFee(TEST_ILK);

        // Ward-only.
        vm.prank(alice);
        vm.expectRevert();
        vaultEngine.exemptFee(TEST_ILK);
    }

    /* ========================== 6. DUTY BOUND & ESCAPE HATCH (H-2) ========================== */

    function test_dutyUpperBoundRejectsBrickingValues() public {
        // Audit H-2: unbounded duty values brick the ilk via rpow overflow. The classic fat-finger (1.5e27 =
        // 50% per SECOND, intending 1.0000000015e27) and the audit's 2.0e27 case must both be rejected at
        // file time.
        vm.expectRevert(InvalidDuty.selector);
        vaultEngine.file(TEST_ILK, "duty", 2 * _RAY);

        vm.expectRevert(InvalidDuty.selector);
        vaultEngine.file(TEST_ILK, "duty", 15e26);

        // The maximum legal duty (100% APY) is accepted and stays computable over long horizons.
        vaultEngine.file(TEST_ILK, "duty", DUTY_100PCT);
        _openTestVault(alice, 1000e18, 100e18);

        skip(3650 days);

        uint256 newRate = vaultEngine.drip(TEST_ILK);
        assertGt(newRate, 1000 * _RAY, "10 years at 100% APY is roughly 2^10");

        vm.expectRevert(InvalidDuty.selector);
        vaultEngine.file(TEST_ILK, "duty", DUTY_100PCT + 1);
    }

    function test_fileDutyRemainsUsableEvenIfDripReverts() public {
        // Audit H-2 (escape hatch): file("duty") drips first, and on a standalone engine with fees accrued
        // but no feeRecipient, that drip REVERTS. Filing a duty must survive it (non-fatal drip) so
        // governance can always reconfigure — the deadlock was: bad duty -> drip reverts -> file reverts ->
        // unrecoverable.
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

        skip(365 days);

        // Direct drip reverts (fees accrued, no recipient) — the poisoned state.
        vm.expectRevert(FeeRecipientNotSet.selector);
        engine.drip(TEST_ILK);

        // Filing a sane duty still works: the inner drip failure is swallowed, the duty lands.
        engine.file(TEST_ILK, "duty", _RAY);

        (, , , , , , uint256 duty, ) = engine.ilks(TEST_ILK);
        assertEq(duty, _RAY, "duty recovered despite reverting drip");
    }

    /* ========================== 7. CAGE SETTLES FEES (M-1) ========================== */

    function test_cageDripsAllIlksSoNoFeeIsForgiven() public {
        // Audit M-1: fees undripped at cage time used to be silently forgiven (rates freeze), shorting
        // redeemers. cage() must drip every registered ilk first so settlement sees the exact accrued debt.
        vaultEngine.file(TEST_ILK, "duty", DUTY_5PCT);
        _openTestVault(alice, 1000e18, 500e18);

        uint256 debtBefore = vaultEngine.debt();

        // A year passes with NO drip from anyone.
        skip(365 days);

        vaultEngine.cage();

        // The rate was accrued through cage itself, not frozen stale.
        uint256 rate = _rate(TEST_ILK);
        assertGt(rate, (_RAY * 104) / 100, "accrual settled at cage");

        // The fee revenue landed on the fee recipient and in total debt — nothing forgiven.
        assertGt(vaultEngine.debt(), debtBefore, "debt includes the accrued year");
        assertGt(vaultEngine.usdr(address(balanceSheet)), 0, "fee revenue credited");

        // And the rate is frozen from here on.
        skip(365 days);
        assertEq(vaultEngine.drip(TEST_ILK), rate, "rate frozen post-cage");
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

/* ========================== CORE AUDIT REGRESSIONS ========================== */

/**
 * @title CoreAuditTest
 * @author Rain Team
 * @notice Audit regressions exercising the core ledger: draw-at-mat boundaries, multi-vault independence and
 *         vault existence/permission guards.
 */
contract CoreAuditTest is BaseTest {
    /* ========================== HELPERS ========================== */

    /// @dev Pushes `price` [wad] through the OSM (two pokes) and into the Vault Engine's spot.
    function _setRainPrice(uint256 price) internal {
        rainPriceSource.setPrice(price);
        // The OSM snaps its delay anchor down to the HOP boundary, so warp to fresh boundaries. Read the
        // clock via the cheatcode: the compiler may otherwise rematerialize a stale block.timestamp across
        // warps under via-ir.
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

    /* ========================== 1. CDP AT MAT ========================== */

    function test_frobDrawAtExactlyMatSucceedsAboveFails() public {
        _setRainPrice(1e18);

        // Seed the stable reserve: frob now recomputes the solvency invariant on every risk-increasing
        // change, and a 100 USDR draw against 400 RAIN carries a stressed loss of 30 (100 - 400 * 0.5 * 0.35
        // * 1). Without a reserve the gate (correctly) fires before the safety check this test targets.
        usdt.mint(keeper, 100e6);
        vm.startPrank(keeper);
        usdt.approve(address(psm), 100e6);
        psm.sellStable(USDT_ILK, keeper, 100e6);
        vm.stopPrank();

        // 400 RAIN at $1 with 400% mat allows exactly 100 USDR.
        uint256 vaultId = _openVault(user, 400e18, 100e18);

        (, uint256 art) = vaultEngine.urns(vaultId);
        assertEq(art, 100e18, "draw at exactly mat");

        // One wei of extra debt breaks the safety check.
        vm.prank(user);
        vm.expectRevert(IVaultEngine.NotSafe.selector);
        vaultEngine.frob(vaultId, user, user, 0, 1);

        // Wipe works.
        vm.prank(user);
        vaultEngine.frob(vaultId, user, user, 0, -100e18);

        (, art) = vaultEngine.urns(vaultId);
        assertEq(art, 0, "wipe clears debt");
    }

    /* ========================== 2. MULTI-VAULT ========================== */

    function test_multipleVaultsPerUserPerIlkAreIndependent() public {
        _setRainPrice(1e18);

        // The same user opens two RAIN vaults with different risk profiles.
        uint256 safeVault = _openVault(user, 1000e18, 100e18); // 1000%
        uint256 riskyVault = _openVault(user, 400e18, 100e18); // 400% (at mat)

        assertEq(vaultEngine.ownerOf(safeVault), user, "owner 1");
        assertEq(vaultEngine.ownerOf(riskyVault), user, "owner 2");
        assertTrue(safeVault != riskyVault, "distinct ids");

        // Depositing into the risky vault touches only the risky vault.
        rain.mint(user, 50e18);
        vm.startPrank(user);
        rain.approve(address(collateralAdapter), 50e18);
        collateralAdapter.join(RAIN_ILK, user, 50e18);
        vaultEngine.frob(riskyVault, user, user, int256(50e18), 0);
        vm.stopPrank();

        (uint256 ink1, ) = vaultEngine.urns(safeVault);
        (uint256 ink2, ) = vaultEngine.urns(riskyVault);
        assertEq(ink1, 1000e18, "safe vault untouched");
        assertEq(ink2, 450e18, "risky vault credited");
    }

    function test_frobOnUnopenedVaultReverts() public {
        vm.expectRevert(IVaultEngine.VaultNotFound.selector);
        vaultEngine.frob(999, user, user, 0, 0);
    }

    function test_frobOnSomeoneElsesVaultRevertsUnlessRiskDecreasing() public {
        _setRainPrice(1e18);

        // Head-room below mat so that the permission check (not the safety check) is what fires.
        uint256 vaultId = _openVault(user, 800e18, 100e18);

        // A stranger cannot draw debt against another owner's vault.
        vm.prank(keeper);
        vm.expectRevert(IVaultEngine.NotAllowed.selector);
        vaultEngine.frob(vaultId, keeper, keeper, 0, 1e18);
    }
}
