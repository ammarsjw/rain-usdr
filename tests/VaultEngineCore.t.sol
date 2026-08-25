// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IVaultEngine } from "../contracts/interfaces/IVaultEngine.sol";
import { Math } from "../contracts/libraries/Math.sol";
import { IlkAlreadyInitialized, InvalidAddress, NotLive, UnrecognizedParameter } from "../contracts/shared/Errors.sol";
import { _RAD, _RAY } from "../contracts/shared/Constants.sol";

import { BaseTest } from "./Base.t.sol";

/**
 * @title VaultEngineCoreTest
 * @author Rain Team
 * @notice Adversarial coverage of the core ledger: authorization, conservation, overflow behaviour, permissions and
 *         vault lifecycle, diffed against MakerDAO vat.sol semantics.
 */
contract VaultEngineCoreTest is BaseTest {
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
        // ink * spot overflows 2^256 at a reachable collateral size: the revert must be the library's decodable
        // MulOverflow, never a raw arithmetic panic.
        vaultEngine.file(TEST_ILK, "spot", 100_000 * _RAY);

        uint256 hugeInk = type(uint256).max / (100_000 * _RAY) + 1;

        vaultEngine.slip(TEST_ILK, alice, int256(hugeInk));

        vm.startPrank(alice);
        uint256 vaultId = vaultEngine.open(TEST_ILK, alice);
        vaultEngine.frob(vaultId, alice, alice, int256(hugeInk), 0);

        // The safety check multiplies ink * spot on any risk-increasing change.
        vm.expectRevert(Math.MulOverflow.selector);
        vaultEngine.frob(vaultId, alice, alice, 0, 1);

        // Critically, the position is NOT bricked: deleveraging out of the overflow zone works because the pure
        // top-up/repay path skips the safety check.
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
        // Settlement path: both must remain callable post-cage (Maker vat parity; End depends on it).
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
