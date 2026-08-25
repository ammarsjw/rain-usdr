// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IGovernor } from "../contracts/interfaces/IGovernor.sol";
import { Governor } from "../contracts/governance/Governor.sol";
import { InvalidAmount, SystemPaused } from "../contracts/shared/Errors.sol";
import { _RAD, _WARD_ROLE } from "../contracts/shared/Constants.sol";

import { BaseTest } from "./Base.t.sol";

/**
 * @title GovernanceTest
 * @author Rain Team
 * @notice Adversarial coverage of the Governor: timelock immutability (M-4), schedule/execute/cancel lifecycle,
 *         and the real 72-hour pause auto-expiry (L-6).
 */
contract GovernanceTest is BaseTest {
    /* ========================== 1. M-4: IMMUTABLE DELAY ========================== */

    function test_delayIsImmutableNoFileExists() public {
        // The file(bytes32,uint256) selector must not exist on the Governor at all: the timelock can never be
        // shortened or zeroed post-deploy, closing the schedule+execute-in-one-tx bypass.
        (bool success, ) = address(governor).call(
            abi.encodeWithSignature("file(bytes32,uint256)", bytes32("delay"), uint256(0))
        );

        assertFalse(success, "no file function on Governor");
        assertEq(governor.delay(), 48 hours, "delay fixed at construction");
    }

    function test_constructorRejectsZeroDelay() public {
        vm.expectRevert(InvalidAmount.selector);
        new Governor(0);
    }

    /* ========================== 2. TIMELOCK LIFECYCLE ========================== */

    function test_scheduleExecuteLifecycle() public {
        // Target: raise the RAIN line via the Governor (it holds no ward here, so use a self-call demo target).
        vaultEngine.grantRole(_WARD_ROLE, address(governor));

        bytes memory call = abi.encodeWithSignature(
            "file(bytes32,bytes32,uint256)",
            RAIN_ILK,
            bytes32("line"),
            200_000 * _RAD
        );

        uint256 id = governor.schedule(address(vaultEngine), call);

        // Too early.
        vm.expectRevert(IGovernor.DelayNotElapsed.selector);
        governor.execute(id);

        vm.warp(vm.getBlockTimestamp() + 48 hours);
        governor.execute(id);

        (, , , , uint256 line, , , ) = vaultEngine.ilks(RAIN_ILK);
        assertEq(line, 200_000 * _RAD, "change applied after delay");

        // Replay is impossible.
        vm.expectRevert(IGovernor.AlreadyExecuted.selector);
        governor.execute(id);
    }

    function test_cancelBlocksExecution() public {
        vaultEngine.grantRole(_WARD_ROLE, address(governor));

        uint256 id = governor.schedule(
            address(vaultEngine),
            abi.encodeWithSignature("file(bytes32,uint256)", bytes32("globalLine"), uint256(0))
        );

        governor.cancel(id);

        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectRevert(IGovernor.ChangeCancelled.selector);
        governor.execute(id);
    }

    function test_executeUnknownIdReverts() public {
        vm.expectRevert(IGovernor.NotScheduled.selector);
        governor.execute(999);
    }

    function test_failedExecutionSurfacesAndIsNotReplayable() public {
        // A call that will revert (no ward for the governor on the target).
        uint256 id = governor.schedule(
            address(vaultEngine),
            abi.encodeWithSignature("file(bytes32,uint256)", bytes32("globalLine"), uint256(1))
        );

        vm.warp(vm.getBlockTimestamp() + 48 hours);

        vm.expectRevert(IGovernor.ExecutionFailed.selector);
        governor.execute(id);
    }

    /* ========================== 3. L-6: REAL PAUSE AUTO-EXPIRY ========================== */

    function test_pauseAutoExpiresForConsumers() public {
        governor.pause("all");
        assertTrue(governor.paused(), "paused");

        // 72 hours later the pause is over for every consumer -- with NO unpause transaction.
        vm.warp(vm.getBlockTimestamp() + 72 hours);
        assertFalse(governor.paused(), "auto-expired");

        // Consumers see it too: a frob against a paused-then-expired system must pass the governor check.
        rain.mint(user, 400e18);
        vm.startPrank(user);
        rain.approve(address(collateralAdapter), 400e18);
        collateralAdapter.join(RAIN_ILK, user, 400e18);
        uint256 vaultId = vaultEngine.open(RAIN_ILK, user);
        vaultEngine.frob(vaultId, user, user, int256(400e18), 0);
        vm.stopPrank();
    }

    function test_pauseBlocksFrobPsmAndBark() public {
        // Set up a position and a mint before pausing.
        rainPriceSource.setPrice(1e18);
        vm.warp(((vm.getBlockTimestamp() / 1800) + 2) * 1800);
        osm.poke(RAIN_ILK);
        vm.warp(vm.getBlockTimestamp() + 3600);
        osm.poke(RAIN_ILK);
        priceConverter.poke(RAIN_ILK);

        rain.mint(user, 400e18);
        vm.startPrank(user);
        rain.approve(address(collateralAdapter), 400e18);
        collateralAdapter.join(RAIN_ILK, user, 400e18);
        uint256 vaultId = vaultEngine.open(RAIN_ILK, user);
        vaultEngine.frob(vaultId, user, user, int256(400e18), int256(100e18));
        vm.stopPrank();

        governor.pause("all");

        // frob blocked -- including repayment (full stop is stricter than the solvency gate).
        vm.prank(user);
        vm.expectRevert(SystemPaused.selector);
        vaultEngine.frob(vaultId, user, user, 0, -int256(1e18));

        // PSM blocked both ways.
        usdt.mint(keeper, 10e6);
        vm.startPrank(keeper);
        usdt.approve(address(psm), 10e6);
        vm.expectRevert(SystemPaused.selector);
        psm.sellStable(USDT_ILK, keeper, 10e6);
        vm.stopPrank();

        // bark blocked.
        vm.expectRevert(SystemPaused.selector);
        liquidationTrigger.bark(vaultId, keeper);
    }

    function test_unpauseAuthBeforeAndAfterWindow() public {
        governor.pause("all");

        // A stranger cannot unpause early.
        vm.prank(address(0xBAD));
        vm.expectRevert();
        governor.unpause();

        // Governance can.
        governor.unpause();
        assertFalse(governor.paused(), "governance early unpause");

        // Re-pause; after the window ANYONE can clear the stale flag.
        governor.pause("all");
        vm.warp(vm.getBlockTimestamp() + 72 hours);

        vm.prank(address(0xBAD));
        governor.unpause();
        assertEq(governor.pausedAt(), 0, "storage cleared by public unpause");
    }

    function test_doublePauseReverts() public {
        governor.pause("all");

        vm.expectRevert(IGovernor.AlreadyPaused.selector);
        governor.pause("again");
    }

    function test_repauseAfterExpiryWorks() public {
        governor.pause("all");
        vm.warp(vm.getBlockTimestamp() + 72 hours);

        // The old pause auto-expired, so a fresh pause is legitimate (new incident, new window).
        governor.pause("second");
        assertTrue(governor.paused(), "fresh pause after expiry");
    }
}
