// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IBalanceSheet } from "../contracts/interfaces/IBalanceSheet.sol";
import { UnrecognizedParameter } from "../contracts/shared/Errors.sol";
import { _RAD, _RAY, _WAD } from "../contracts/shared/Constants.sol";

import { BaseTest } from "./Base.t.sol";

/**
 * @title BalanceSheetTest
 * @author Rain Team
 * @notice Coverage of the treasury: sin queue lifecycle, heal bounds, keeper reward suck, the fill-before-burn
 *         surplus rule and the dynamic hump target.
 */
contract BalanceSheetTest is BaseTest {
    /* ========================== 1. FILE ========================== */

    function test_fileParametersAndGuards() public {
        balanceSheet.file("humpFloor", 1000 * _RAD);
        balanceSheet.file("humpRate", _WAD / 10);
        balanceSheet.file("wait", 561600);
        balanceSheet.file("buybackReceiver", address(0xB0B));
        balanceSheet.file("reserveAccounting", address(reserveAccounting));

        assertEq(balanceSheet.humpFloor(), 1000 * _RAD, "humpFloor");
        assertEq(balanceSheet.humpRate(), _WAD / 10, "humpRate");
        assertEq(balanceSheet.wait(), 561600, "wait");
        assertEq(balanceSheet.buybackReceiver(), address(0xB0B), "receiver");

        vm.expectRevert(UnrecognizedParameter.selector);
        balanceSheet.file("nonsense", 1);

        vm.expectRevert(UnrecognizedParameter.selector);
        balanceSheet.file("nonsense", address(1));

        vm.prank(address(0xBAD));
        vm.expectRevert();
        balanceSheet.file("wait", 0);
    }

    /* ========================== 2. SIN QUEUE ========================== */

    function test_fessFlogHealFullLifecycle() public {
        balanceSheet.file("wait", 1000);

        vaultEngine.suck(address(balanceSheet), address(balanceSheet), 30 * _RAD);
        balanceSheet.fess(30 * _RAD);

        uint256 era = vm.getBlockTimestamp();
        assertEq(balanceSheet.totalQueuedSin(), 30 * _RAD, "queued");
        assertEq(balanceSheet.sin(era), 30 * _RAD, "era bucket");

        // Queued sin cannot be healed and the era cannot be flogged early.
        vm.expectRevert(IBalanceSheet.InsufficientDebt.selector);
        balanceSheet.heal(30 * _RAD);

        vm.expectRevert(IBalanceSheet.WaitNotElapsed.selector);
        balanceSheet.flog(era);

        // After the wait: flog releases, heal cancels.
        vm.warp(era + 1000);
        balanceSheet.flog(era);

        assertEq(balanceSheet.totalQueuedSin(), 0, "queue drained");
        assertEq(balanceSheet.sin(era), 0, "era cleared");

        balanceSheet.heal(30 * _RAD);
        assertEq(vaultEngine.sin(address(balanceSheet)), 0, "healed");

        // Flogging an empty era is a harmless no-op.
        balanceSheet.flog(era);
    }

    function test_healBoundedBySurplusAndReleasedSin() public {
        // Surplus 10, sin 30 (all released, wait = 0).
        vaultEngine.suck(address(balanceSheet), address(this), 20 * _RAD);
        vaultEngine.suck(address(balanceSheet), address(balanceSheet), 10 * _RAD);

        // More than the surplus.
        vm.expectRevert(IBalanceSheet.InsufficientSurplus.selector);
        balanceSheet.heal(11 * _RAD);

        // Within surplus and released sin.
        balanceSheet.heal(10 * _RAD);
        assertEq(vaultEngine.sin(address(balanceSheet)), 20 * _RAD, "partial heal");
    }

    function test_suckPaysKeeperReward() public {
        balanceSheet.suck(keeper, 2 * _RAD);

        assertEq(vaultEngine.usdr(keeper), 2 * _RAD, "keeper paid");
        assertEq(vaultEngine.sin(address(balanceSheet)), 2 * _RAD, "debt recorded");

        vm.prank(address(0xBAD));
        vm.expectRevert();
        balanceSheet.suck(keeper, 1);
    }

    /* ========================== 3. SURPLUS DISTRIBUTION ========================== */

    function test_distributeRevertsOnOutstandingBadDebt() public {
        balanceSheet.file("buybackReceiver", address(0xB0B));

        vaultEngine.suck(address(balanceSheet), address(balanceSheet), 10 * _RAD);

        vm.expectRevert(IBalanceSheet.OutstandingBadDebt.selector);
        balanceSheet.distributeSurplus();
    }

    function test_distributeRequiresReceiver() public {
        balanceSheet.file("humpFloor", 1 * _RAD);

        vaultEngine.suck(address(this), address(balanceSheet), 10 * _RAD);

        vm.expectRevert(IBalanceSheet.NoBuybackReceiver.selector);
        balanceSheet.distributeSurplus();
    }

    function test_humpTargetIsMaxOfFloorAndRate() public {
        balanceSheet.file("humpFloor", 500 * _RAD);
        balanceSheet.file("humpRate", _WAD / 10);
        balanceSheet.file("reserveAccounting", address(reserveAccounting));

        // Empty reserve: the floor rules.
        assertEq(balanceSheet.humpTarget(), 500 * _RAD, "floor rules empty reserve");

        // A large reserve: 10% of it beats the floor. Mint via the PSM.
        usdt.mint(user, 100_000e6);
        vm.startPrank(user);
        usdt.approve(address(psm), 100_000e6);
        psm.sellStable(USDT_ILK, user, 100_000e6);
        vm.stopPrank();

        assertEq(balanceSheet.humpTarget(), 10_000e18 * _RAY, "10% of 100k reserve");
    }

    function test_distributeReleasesOnlyExcessAboveTarget() public {
        balanceSheet.file("humpFloor", 20 * _RAD);
        balanceSheet.file("buybackReceiver", address(0xB0B));

        vaultEngine.suck(address(this), address(balanceSheet), 50 * _RAD);

        uint256 excess = balanceSheet.distributeSurplus();

        assertEq(excess, 30 * _RAD, "released above target");
        assertEq(vaultEngine.usdr(address(balanceSheet)), 20 * _RAD, "buffer intact");
        assertEq(vaultEngine.usdr(address(0xB0B)), 30 * _RAD, "receiver credited");

        // A second call is a clean no-op at target.
        assertEq(balanceSheet.distributeSurplus(), 0, "no-op at target");
    }
}
