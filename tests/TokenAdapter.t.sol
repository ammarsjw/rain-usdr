// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { ICollateralAdapter } from "../contracts/interfaces/ICollateralAdapter.sol";
import { IlkAlreadyInitialized, InvalidAddress, InvalidAmount, NotLive } from "../contracts/shared/Errors.sol";
import { _RAY, _USDR_ILK, _WAD } from "../contracts/shared/Constants.sol";

import { BaseTest } from "./Base.t.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockFeeOnTransferERC20 } from "./mocks/MockFeeOnTransferERC20.sol";

/**
 * @title TokenAdapterTest
 * @author Rain Team
 * @notice Adversarial coverage of the Collateral Adapter and USDR token: decimal conversion, balance-delta
 *         enforcement (H-2), mint/burn authority and lifecycle guards.
 */
contract TokenAdapterTest is BaseTest {
    address internal alice = address(0xA11CE);

    /* ========================== 1. H-2: FEE-ON-TRANSFER ========================== */

    function test_joinRevertsOnFeeOnTransferToken() public {
        // A 1% fee token registered as collateral must be unusable: join measures the received delta and refuses
        // any shortfall, so the shared adapter can never be silently under-collateralized.
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

        // The adapter (BURNER_ROLE) burns without allowance -- repayment UX.
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

        // Internal -> ERC-20 (requires hope, granted in Base? no -- the adapter moves the caller's balance).
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
