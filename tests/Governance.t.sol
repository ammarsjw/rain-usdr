// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IEnd } from "../contracts/interfaces/IEnd.sol";
import { IGovernor } from "../contracts/interfaces/IGovernor.sol";
import { Governor } from "../contracts/governance/Governor.sol";
import { InvalidAmount, NotLive, SystemPaused } from "../contracts/shared/Errors.sol";
import { _RAD, _RAY, _USDR_ILK, _WARD_ROLE } from "../contracts/shared/Constants.sol";

import { BaseTest } from "./shared/BaseTest.sol";

/* ========================== GOVERNOR (timelock & pause) ========================== */

/**
 * @title GovernanceTest
 * @author Rain Team
 * @notice Adversarial coverage of the Governor: timelock immutability (M-4), schedule/execute/cancel lifecycle,
 *         and the real 72-hour pause auto-expiry (L-6).
 */
contract GovernanceTest is BaseTest {
    /* ========================== 1. IMMUTABLE DELAY ========================== */

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

    /* ========================== 3. REAL PAUSE AUTO-EXPIRY ========================== */

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

/* ========================== EMERGENCY SETTLEMENT (End — governance-triggered) ========================== */

/**
 * @title SettlementTest
 * @author Rain Team
 * @notice End-to-end emergency settlement scenarios: full lifecycle, in-flight auction reclaim, owner collateral
 *         reclaim and phase-ordering guards.
 */
contract SettlementTest is BaseTest {
    /* ========================== HELPERS ========================== */

    /// @dev Pushes `price` [wad] through the OSM (two pokes) and into the Vault Engine's spot.
    function _setRainPrice(uint256 price) internal {
        rainPriceSource.setPrice(price);
        vm.warp(((vm.getBlockTimestamp() / 1800) + 2) * 1800);
        osm.poke(RAIN_ILK);
        vm.warp(vm.getBlockTimestamp() + 3600);
        osm.poke(RAIN_ILK);
        priceConverter.poke(RAIN_ILK);
    }

    /// @dev Opens a fresh RAIN vault for `who` with `ink` collateral and `art` debt.
    function _openVault(address who, uint256 ink, uint256 art) internal returns (uint256 vaultId) {
        rain.mint(who, ink);

        vm.startPrank(who);
        rain.approve(address(collateralAdapter), ink);
        collateralAdapter.join(RAIN_ILK, who, ink);
        vaultId = vaultEngine.open(RAIN_ILK, who);
        vaultEngine.frob(vaultId, who, who, int256(ink), int256(art));
        vm.stopPrank();
    }

    /// @dev Mints `amt` USDT (6 decimals) to `who` and sells it through the PSM for USDR.
    function _sellUsdt(address who, uint256 amt) internal {
        usdt.mint(who, amt);

        vm.startPrank(who);
        usdt.approve(address(psm), amt);
        psm.sellStable(USDT_ILK, who, amt);
        vm.stopPrank();
    }

    /* ========================== 1. LIFECYCLE ========================== */

    function test_settlementFullLifecycle() public {
        _setRainPrice(1e18);

        // A vault and a PSM position exist; USDR circulates.
        uint256 vaultId = _openVault(user, 400e18, 100e18);
        _sellUsdt(keeper, 100e6);

        // Phase 1: freeze.
        end.cage();
        assertEq(vaultEngine.live(), 0, "vault engine caged");
        assertEq(liquidationTrigger.live(), 0, "trigger caged");
        assertEq(priceConverter.live(), 0, "converter caged");

        // Frozen system rejects new activity.
        vm.expectRevert(NotLive.selector);
        vaultEngine.open(RAIN_ILK, user);

        // Phase 2: fix settlement prices (RAIN at $1, USDT fixed at $1).
        end.cage(RAIN_ILK);
        end.cage(USDT_ILK);
        assertEq(end.tag(RAIN_ILK), _RAY, "RAIN tag = 1/price");
        assertEq(end.tag(USDT_ILK), _RAY, "USDT tag = $1");

        // Phase 3: settle the vault (solvent at $1: 100 owed of 400 held).
        end.skim(vaultId);
        (uint256 ink, uint256 art) = vaultEngine.urns(vaultId);
        assertEq(art, 0, "debt cancelled");
        assertEq(ink, 300e18, "only owed collateral confiscated");

        // Also settle the PSM's stable vault so its debt clears.
        (, , uint256 psmVaultId) = psm.ilks(USDT_ILK);
        end.skim(psmVaultId);

        // Phase 4: the owner frees leftover collateral.
        vm.prank(user);
        end.free(vaultId);
        assertEq(vaultEngine.collateral(RAIN_ILK, user), 300e18, "leftover freed to owner");

        // Phase 5: thaw (wait = 0, no surplus on the balance sheet).
        end.thaw();
        assertEq(end.debt(), vaultEngine.debt(), "debt fixed");
        assertGt(end.debt(), 0, "supply outstanding");

        // Phase 6: redemption prices.
        end.flow(RAIN_ILK);
        end.flow(USDT_ILK);
        assertGt(end.fix(RAIN_ILK), 0, "RAIN redeemable");
        assertGt(end.fix(USDT_ILK), 0, "USDT redeemable");

        // Phase 7-8: the USDR holder converts, packs and cashes both collaterals.
        vm.startPrank(keeper);
        usdr.approve(address(collateralAdapter), 100e18);
        collateralAdapter.join(_USDR_ILK, keeper, 100e18);
        vaultEngine.hope(address(end));
        end.pack(100e18);
        assertEq(end.bag(keeper), 100e18, "bag packed");

        end.cash(RAIN_ILK, 100e18);
        end.cash(USDT_ILK, 100e18);
        vm.stopPrank();

        // The holder receives a pro-rata share of each collateral pot.
        assertGt(vaultEngine.collateral(RAIN_ILK, keeper), 0, "RAIN received");
        assertGt(vaultEngine.collateral(USDT_ILK, keeper), 0, "USDT received");

        // USDT exits back to the ERC-20 through the adapter (6 decimals).
        uint256 usdtInternal = vaultEngine.collateral(USDT_ILK, keeper);
        vm.prank(keeper);
        collateralAdapter.exit(USDT_ILK, keeper, usdtInternal / 1e12);
        assertGt(usdt.balanceOf(keeper), 0, "USDT out the door");
    }

    /* ========================== 2. IN-FLIGHT AUCTION RECLAIM ========================== */

    function test_skipReclaimsInFlightAuctionIntoVault() public {
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 400e18, 100e18);

        // The vault crashes and is barked; an auction is now in flight.
        _setRainPrice(0.6e18);
        uint256 auctionId = liquidationTrigger.bark(vaultId, keeper);

        (uint256 ink, uint256 art) = vaultEngine.urns(vaultId);
        assertEq(ink, 0, "seized");
        assertEq(art, 0, "seized");

        // Settlement starts before anyone buys.
        end.cage();
        end.cage(RAIN_ILK);

        // Skip reclaims the auction into the vault: collateral and (penalty-inclusive) debt restored.
        end.skip(RAIN_ILK, auctionId);

        (ink, art) = vaultEngine.urns(vaultId);
        assertEq(ink, 400e18, "collateral restored to vault");
        assertEq(art, 113e18, "debt restored including penalty");

        // The reclaimed vault settles like any other at the last price ($0.60): owed = 113 * 1/0.6.
        end.skim(vaultId);
        (ink, art) = vaultEngine.urns(vaultId);
        assertEq(art, 0, "debt cancelled after skim");

        uint256 owed = (((uint256(113e18) * _RAY) / _RAY) * end.tag(RAIN_ILK)) / _RAY;
        assertEq(ink, 400e18 - owed, "underwater remainder");
    }

    /* ========================== 3. PHASE GUARDS ========================== */

    function test_settlementPhaseGuards() public {
        _setRainPrice(1e18);

        // Nothing works before cage.
        vm.expectRevert(IEnd.StillLive.selector);
        end.cage(RAIN_ILK);

        vm.expectRevert(IEnd.StillLive.selector);
        end.thaw();

        end.cage();

        // Cage is one-shot.
        vm.expectRevert(IEnd.AlreadyCaged.selector);
        end.cage();

        // Skim requires the ilk's tag.
        vm.expectRevert(IEnd.TagNotDefined.selector);
        end.skim(1);

        end.cage(RAIN_ILK);

        // Tag is one-shot per ilk.
        vm.expectRevert(IEnd.TagAlreadyDefined.selector);
        end.cage(RAIN_ILK);

        // Flow requires thaw.
        vm.expectRevert(IEnd.DebtNotFixed.selector);
        end.flow(RAIN_ILK);

        // Pack requires thaw.
        vm.expectRevert(IEnd.DebtNotFixed.selector);
        end.pack(1e18);

        // Cash requires flow.
        vm.expectRevert(IEnd.FixNotDefined.selector);
        end.cash(RAIN_ILK, 1e18);
    }

    function test_freeRevertsForNonOwnerAndIndebtedVault() public {
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 400e18, 100e18);

        end.cage();
        end.cage(RAIN_ILK);

        // A stranger cannot free someone else's vault.
        vm.prank(keeper);
        vm.expectRevert();
        end.free(vaultId);

        // The owner cannot free while debt remains.
        vm.prank(user);
        vm.expectRevert(IEnd.ArtNotZero.selector);
        end.free(vaultId);

        // After skim, the owner frees the leftover.
        end.skim(vaultId);
        vm.prank(user);
        end.free(vaultId);

        (uint256 ink, ) = vaultEngine.urns(vaultId);
        assertEq(ink, 0, "vault emptied");
    }

    function test_thawGuardsSurplusAndWait() public {
        _setRainPrice(1e18);
        _sellUsdt(keeper, 50e6);

        // Surplus on the balance sheet blocks thaw (matched sin lands on the balance sheet too, so it can heal).
        vaultEngine.suck(address(balanceSheet), address(balanceSheet), 5 * _RAD);

        end.cage();

        vm.expectRevert(IEnd.SurplusNotZero.selector);
        end.thaw();

        // Healing the surplus away (matched sin exists from the suck above).
        balanceSheet.heal(5 * _RAD);

        end.thaw();
        assertGt(end.debt(), 0, "debt fixed after heal");
    }
}
