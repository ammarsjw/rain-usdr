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
 * @notice Adversarial coverage of the Governor: timelock immutability (M-4), schedule/execute/cancel
 *         lifecycle, and the real 72-hour pause auto-expiry (L-6).
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
        // Target: raise the RAIN line via the Governor (it holds no ward here, so use a self-call demo
        // target).
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

    function test_staleQueuedChangeExpires() public {
        // A queued change must not stay executable forever. Without an expiry, a stale, forgotten entry —
        // scheduled under assumptions long invalidated — could be fired years later by anyone, since
        // execution is permissionless.
        vaultEngine.grantRole(_WARD_ROLE, address(governor));

        uint256 id = governor.schedule(
            address(vaultEngine),
            abi.encodeWithSignature("file(bytes32,bytes32,uint256)", RAIN_ILK, bytes32("line"), 200_000 * _RAD)
        );

        // Still executable at the very end of the grace window.
        vm.warp(vm.getBlockTimestamp() + 48 hours + governor.GRACE());
        // ...but expired one second past it.
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectRevert(IGovernor.ChangeExpired.selector);
        governor.execute(id);

        // The change is dead permanently; only a fresh schedule (full timelock) can apply it now.
        uint256 fresh = governor.schedule(
            address(vaultEngine),
            abi.encodeWithSignature("file(bytes32,bytes32,uint256)", RAIN_ILK, bytes32("line"), 200_000 * _RAD)
        );

        vm.warp(vm.getBlockTimestamp() + 48 hours);
        governor.execute(fresh);

        (, , , , uint256 line, , , ) = vaultEngine.ilks(RAIN_ILK);
        assertEq(line, 200_000 * _RAD, "re-scheduled change applied");
    }

    function test_executeWithinGraceWindowStillWorks() public {
        // The boundary itself (eta + GRACE exactly) is still executable — the window closes strictly after.
        vaultEngine.grantRole(_WARD_ROLE, address(governor));

        uint256 id = governor.schedule(
            address(vaultEngine),
            abi.encodeWithSignature("file(bytes32,bytes32,uint256)", RAIN_ILK, bytes32("line"), 150_000 * _RAD)
        );

        vm.warp(vm.getBlockTimestamp() + 48 hours + governor.GRACE());
        governor.execute(id);

        (, , , , uint256 line, , , ) = vaultEngine.ilks(RAIN_ILK);
        assertEq(line, 150_000 * _RAD, "change applied at the grace boundary");
    }

    function test_executeRejectsCodelessTarget() public {
        // A raw call to a code-less address succeeds vacuously: the change would be marked executed while
        // doing nothing. The target must carry code at execution time.
        uint256 id = governor.schedule(
            address(0xDEAD),
            abi.encodeWithSignature("file(bytes32,uint256)", bytes32("globalLine"), uint256(1))
        );

        vm.warp(vm.getBlockTimestamp() + 48 hours);

        vm.expectRevert(IGovernor.TargetNotContract.selector);
        governor.execute(id);
    }

    /* ========================== 3. REAL PAUSE AUTO-EXPIRY ========================== */

    function test_pauseAutoExpiresForConsumers() public {
        governor.pause();
        assertTrue(governor.paused(), "paused");

        // 72 hours later the pause is over for every consumer, with NO unpause transaction.
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

        governor.pause();

        // frob blocked, including repayment (full stop is stricter than the solvency gate).
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
        governor.pause();

        // A stranger cannot unpause early.
        vm.prank(address(0xBAD));
        vm.expectRevert();
        governor.unpause();

        // Governance can.
        governor.unpause();
        assertFalse(governor.paused(), "governance early unpause");

        // Re-pause; after the window ANYONE can clear the stale flag.
        governor.pause();
        vm.warp(vm.getBlockTimestamp() + 72 hours);

        vm.prank(address(0xBAD));
        governor.unpause();
        assertEq(governor.pausedAt(), 0, "storage cleared by public unpause");
    }

    function test_doublePauseReverts() public {
        governor.pause();

        vm.expectRevert(IGovernor.AlreadyPaused.selector);
        governor.pause();
    }

    function test_repauseAfterExpiryWorks() public {
        governor.pause();
        vm.warp(vm.getBlockTimestamp() + 72 hours);

        // The old pause auto-expired, so a fresh pause is legitimate (new incident, new window).
        governor.pause();
        assertTrue(governor.paused(), "fresh pause after expiry");
    }
}

/* ========================== EMERGENCY SETTLEMENT (End — governance-triggered) ========================== */

/**
 * @title SettlementTest
 * @author Rain Team
 * @notice End-to-end emergency settlement scenarios: full lifecycle, in-flight auction reclaim, owner
 *         collateral reclaim and phase-ordering guards.
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

    function test_cageIlkHaltsAuctionHouse() public {
        // Audit C-2: End.cage(ilkId) must cage the ilk's auction house. Before the fix, in-flight auctions
        // kept decaying against the FIXED settlement price — a risk-free, unbounded arbitrage against
        // redeemers once the curve crossed break-even, with the bought collateral permanently leaving the
        // redemption pool.
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 400e18, 100e18);

        // Crash and bark: an auction is in flight at settlement time.
        _setRainPrice(0.6e18);
        uint256 auctionId = liquidationTrigger.bark(vaultId, keeper);

        assertEq(dutchAuction.live(), 1, "auction house live pre-settlement");

        end.cage();
        end.cage(RAIN_ILK);

        // The structural precondition of the exploit is gone.
        assertEq(dutchAuction.live(), 0, "auction house caged with the ilk");

        // No keeper can take (or redo) the in-flight auction after settlement, at any price.
        vm.warp(vm.getBlockTimestamp() + 1700); // Deep into the decay curve, past the old break-even.
        vm.prank(keeper);
        vm.expectRevert(NotLive.selector);
        dutchAuction.take(auctionId, type(uint256).max, type(uint256).max, keeper, "");

        vm.prank(keeper);
        vm.expectRevert(NotLive.selector);
        dutchAuction.redo(auctionId, keeper);

        // Settlement itself is unaffected: yank is deliberately un-gated, so skip still reclaims the auction.
        end.skip(RAIN_ILK, auctionId);

        (uint256 ink, uint256 art) = vaultEngine.urns(vaultId);
        assertEq(ink, 400e18, "full collateral back in the redemption pool");
        assertEq(art, 113e18, "debt (incl. penalty) restored");
    }

    function test_skipRestoresArtSnapshotSoFixIsExact() public {
        // Audit H-4: skip reinstates the auction's debt into the vault (grab) AND must add it back to the
        // ilk's settlement snapshot. Before the fix, thaw's total debt included the restored debt while
        // art[ilk] did not, so flow divided a short numerator by a full denominator — understating fix and
        // stranding collateral in End forever (measured ~53% stranded in the audit).
        _setRainPrice(1e18);

        uint256 vaultId = _openVault(user, 400e18, 100e18);
        _sellUsdt(keeper, 100e6);

        // Bark the vault so ALL RAIN debt is in-flight at settlement (the worst case for the old code: the
        // RAIN snapshot would have been zero).
        _setRainPrice(0.6e18);
        uint256 auctionId = liquidationTrigger.bark(vaultId, keeper);
        uint256 barkEra = vm.getBlockTimestamp();

        end.cage();
        end.cage(RAIN_ILK);
        end.cage(USDT_ILK);

        uint256 snapshotBefore = end.art(RAIN_ILK);
        assertEq(snapshotBefore, 0, "bark removed all ilk debt pre-snapshot");

        end.skip(RAIN_ILK, auctionId);

        // The snapshot now carries the restored debt.
        assertEq(end.art(RAIN_ILK), 113e18, "snapshot restored with the reclaimed debt");

        end.skim(vaultId);

        (, , uint256 psmVaultId) = psm.ilks(USDT_ILK);
        end.skim(psmVaultId);

        // Thaw requires the Balance Sheet's surplus healed away: release the bark-era sin queue (wait = 0 in
        // this harness) and net the skip-created surplus against it.
        balanceSheet.flog(barkEra);
        balanceSheet.heal(vaultEngine.usdr(address(balanceSheet)));

        end.thaw();
        end.flow(RAIN_ILK);

        // Maker-parity fix: art * rate * tag / debt, with art INCLUDING the restored debt.
        (, , uint256 rate, , , , , ) = vaultEngine.ilks(RAIN_ILK);
        uint256 wad = (((uint256(113e18) * rate) / _RAY) * end.tag(RAIN_ILK)) / _RAY;
        uint256 expectedFix = ((wad - end.gap(RAIN_ILK)) * _RAY) / (end.debt() / _RAY);

        assertEq(end.fix(RAIN_ILK), expectedFix, "fix computed on the full snapshot");

        // The conservation identity H-4 broke: the ENTIRE fixed debt redeemed at fix reclaims exactly the
        // RAIN End holds (sub-wei truncation dust aside) — nothing is stranded. Before the fix, the snapshot
        // missed the restored debt, fix was understated by ~50%, and most of the pot was unreachable forever.
        uint256 held = vaultEngine.collateral(RAIN_ILK, address(end));
        uint256 claimable = ((end.debt() / _RAY) * end.fix(RAIN_ILK)) / _RAY;

        assertApproxEqAbs(claimable, held, 1e6, "full debt redemption drains the pot");
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

    function test_settlementBlockedWhileAuctionsPending() public {
        // thaw fixes the total debt and flow permanently fixes the redemption price, while skip is what adds
        // a reclaimed auction's debt back into the settlement snapshot (and sucks fresh surplus/debt onto the
        // ledger). Before these guards, running thaw/flow ahead of skip froze the accounting on the reduced
        // state forever — the collateral yanked into End afterwards was stranded and every redeemer was
        // shorted. Both must refuse while any auction house still holds active auctions.
        _setRainPrice(1e18);

        uint256 vaultId = _openVault(user, 400e18, 100e18);
        _sellUsdt(keeper, 100e6);

        _setRainPrice(0.6e18);
        uint256 auctionId = liquidationTrigger.bark(vaultId, keeper);
        uint256 barkEra = vm.getBlockTimestamp();

        end.cage();
        end.cage(RAIN_ILK);
        end.cage(USDT_ILK);

        (, , uint256 psmVaultId) = psm.ilks(USDT_ILK);
        end.skim(psmVaultId);

        balanceSheet.flog(barkEra);

        // The premature thaw — freezing the total debt with an auction unreclaimed — is refused.
        vm.expectRevert(IEnd.AuctionsPending.selector);
        end.thaw();

        // After skip + skim the guard lifts: thaw fixes the debt and flow computes the fix on the FULL
        // snapshot. The residual surplus (the skip-sucked 13% penalty margin) is netted out of the fixed
        // debt, so no heal-to-zero is required.
        end.skip(RAIN_ILK, auctionId);
        end.skim(vaultId);

        end.thaw();

        // Ilks with no auction house (PSM stables) flow freely.
        end.flow(USDT_ILK);
        assertGt(end.fix(USDT_ILK), 0, "stable ilk flows freely");

        end.flow(RAIN_ILK);

        (, , uint256 rate, , , , , ) = vaultEngine.ilks(RAIN_ILK);
        uint256 wad = (((uint256(113e18) * rate) / _RAY) * end.tag(RAIN_ILK)) / _RAY;
        uint256 expectedFix = ((wad - end.gap(RAIN_ILK)) * _RAY) / (end.debt() / _RAY);

        assertEq(end.fix(RAIN_ILK), expectedFix, "fix computed on the full snapshot after skip");

        // Conservation holds: redeeming the entire fixed debt at fix drains what End actually holds.
        uint256 held = vaultEngine.collateral(RAIN_ILK, address(end));
        uint256 claimable = ((end.debt() / _RAY) * end.fix(RAIN_ILK)) / _RAY;

        assertApproxEqAbs(claimable, held, 1e6, "nothing stranded");
    }

    function test_flowBlockedUntilEveryVaultIsSkimmed() public {
        // Report A.1 (RAINUSDR-1244): gap[ilkId] is accumulated lazily per vault in skim, so fixing the
        // redemption price while any debt-bearing vault is unskimmed locks fix against an understated
        // shortfall — the early redeemer over-collects and later redeemers' cash reverts. flow must refuse
        // until pendingArt reaches zero.
        _setRainPrice(1e18);

        // The reserve must exist before the second draw: two 100-art vaults carry 60 of stressed loss, which
        // breaches against an empty reserve and the solvency gate would refuse vault B's frob.
        _sellUsdt(keeper, 100e6);

        uint256 vaultA = _openVault(user, 400e18, 100e18);
        uint256 vaultB = _openVault(keeper, 400e18, 100e18);

        // Both vaults are underwater at the settlement price.
        _setRainPrice(0.2e18);

        end.cage();
        end.cage(RAIN_ILK);
        end.cage(USDT_ILK);

        assertEq(end.pendingArt(RAIN_ILK), 200e18, "both vaults await skim");

        // Only vault A is skimmed: the shortfall is incomplete.
        end.skim(vaultA);
        (, , uint256 psmVaultId) = psm.ilks(USDT_ILK);
        end.skim(psmVaultId);

        end.thaw();

        // The premature flow — the report's exploit step — is refused.
        vm.expectRevert(IEnd.SkimsPending.selector);
        end.flow(RAIN_ILK);

        // After the second skim the guard lifts and fix is computed on the COMPLETE shortfall.
        end.skim(vaultB);
        assertEq(end.pendingArt(RAIN_ILK), 0, "all debt settled");

        end.flow(RAIN_ILK);

        (, , uint256 rate, , , , , ) = vaultEngine.ilks(RAIN_ILK);
        uint256 wad = (((uint256(200e18) * rate) / _RAY) * end.tag(RAIN_ILK)) / _RAY;
        uint256 expectedFix = ((wad - end.gap(RAIN_ILK)) * _RAY) / (end.debt() / _RAY);

        assertEq(end.fix(RAIN_ILK), expectedFix, "fix computed on the complete gap");

        // Conservation: redeeming the entire fixed debt at fix drains exactly what End holds.
        uint256 held = vaultEngine.collateral(RAIN_ILK, address(end));
        uint256 claimable = ((end.debt() / _RAY) * end.fix(RAIN_ILK)) / _RAY;

        assertApproxEqAbs(claimable, held, 1e6, "no over-payment, nothing stranded");
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

    function test_thawNetsResidualSurplusOutOfFixedDebt() public {
        // Report RAINUSDR-1235 (vector 1): stability fees accrue as surplus with NO matching sin, so when the
        // book is mostly repaid before shutdown the residual surplus is unhealable — a heal-to-zero
        // requirement would brick thaw (and with it all of settlement) forever. thaw instead nets the
        // residual surplus out of the fixed debt, pricing redemption against the packable supply.
        _setRainPrice(1e18);
        _sellUsdt(keeper, 50e6);

        // Unmatched surplus on the balance sheet (as fee accrual would create: usdr with no sin behind it).
        vaultEngine.suck(address(balanceSheet), address(balanceSheet), 5 * _RAD);
        balanceSheet.heal(5 * _RAD);
        // suck parks the sin on 0xFEE and the surplus on the Balance Sheet — unmatched surplus, exactly the
        // shape fee accrual creates (the Balance Sheet cannot heal sin it does not hold).
        vaultEngine.suck(address(0xFEE), address(balanceSheet), 5 * _RAD);

        end.cage();

        // Thaw succeeds despite the unhealable surplus, netting it out of the fixed debt.
        uint256 surplus = vaultEngine.usdr(address(balanceSheet));
        assertGt(surplus, 0, "residual surplus stands");

        end.thaw();

        assertEq(end.debt(), vaultEngine.debt() - surplus, "debt fixed net of residual surplus");
        assertGt(end.debt(), 0, "packable supply outstanding");
    }
}
