// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IDutchAuction } from "../contracts/interfaces/IDutchAuction.sol";
import { ILiquidationTrigger } from "../contracts/interfaces/ILiquidationTrigger.sol";
import { SystemPaused } from "../contracts/shared/Errors.sol";
import { _RAD, _USDR_ILK, _WAD } from "../contracts/shared/Constants.sol";

import { BaseTest } from "./Base.t.sol";

/**
 * @title LiquidationTest
 * @author Rain Team
 * @notice Adversarial coverage of the liquidation stack: bark capacity accounting, the M-6 auction breaker and
 *         governance pause, take/redo economics and parameter guards.
 */
contract LiquidationTest is BaseTest {
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

    /// @dev Funds `who` with internal USDR via the PSM and hopes the auction.
    function _fundBidder(address who, uint256 amt6) internal {
        usdt.mint(who, amt6);

        vm.startPrank(who);
        usdt.approve(address(psm), amt6);
        psm.sellStable(USDT_ILK, who, amt6);
        usdr.approve(address(collateralAdapter), amt6 * 1e12);
        collateralAdapter.join(_USDR_ILK, who, amt6 * 1e12);
        vaultEngine.hope(address(dutchAuction));
        vm.stopPrank();
    }

    /* ========================== 1. BARK CAPACITY (hole/dirt) ========================== */

    function test_barkRespectsHoleAndDigsFreesCapacity() public {
        // Both vaults and the bidder are set up BEFORE the crash: _setRainPrice warps hours forward, and the
        // auction must still be fresh (tail = 1800s) when the take executes.
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 800e18, 200e18);
        uint256 second = _openVault(keeper, 400e18, 100e18);
        _fundBidder(address(0xB1D), 300e6);

        _setRainPrice(0.6e18);

        // Room for one full liquidation only.
        liquidationTrigger.file(RAIN_ILK, "hole", 226 * _RAD);

        uint256 id = liquidationTrigger.bark(vaultId, keeper);

        (, , , uint256 dirt, ) = liquidationTrigger.ilks(RAIN_ILK);
        assertEq(dirt, 226 * _RAD, "dirt filled");

        // The second vault cannot bark: no capacity.
        vm.expectRevert(ILiquidationTrigger.LiquidationLimitHit.selector);
        liquidationTrigger.bark(second, keeper);

        // A full take clears the auction and digs the capacity free again.
        (, uint256 price, , ) = dutchAuction.getStatus(id);

        vm.prank(address(0xB1D));
        dutchAuction.take(id, 800e18, price, address(0xB1D), "");

        (, , , dirt, ) = liquidationTrigger.ilks(RAIN_ILK);
        assertEq(dirt, 0, "capacity freed");

        liquidationTrigger.bark(second, keeper);
    }

    function test_barkPaysKickReward() public {
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 400e18, 100e18);
        _setRainPrice(0.6e18);

        uint256 before = vaultEngine.usdr(keeper);
        liquidationTrigger.bark(vaultId, keeper);

        // chip = 2% of tab (113 rad).
        assertEq(vaultEngine.usdr(keeper) - before, (113 * _RAD * 2) / 100, "kick reward");
    }

    /* ========================== 2. M-6: BREAKER + PAUSE ========================== */

    function test_stoppedLevelsGateKickTakeRedo() public {
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 400e18, 100e18);
        _setRainPrice(0.6e18);

        // Level 1: no new kicks (bark reverts inside kick).
        dutchAuction.file("stopped", 1);
        vm.expectRevert(IDutchAuction.Stopped.selector);
        liquidationTrigger.bark(vaultId, keeper);

        dutchAuction.file("stopped", 0);
        uint256 id = liquidationTrigger.bark(vaultId, keeper);

        // Level 2: takes stopped.
        dutchAuction.file("stopped", 2);
        _fundBidder(address(0xB1D), 200e6);

        (, uint256 price, , ) = dutchAuction.getStatus(id);
        vm.prank(address(0xB1D));
        vm.expectRevert(IDutchAuction.Stopped.selector);
        dutchAuction.take(id, 400e18, price, address(0xB1D), "");

        // Level 3: redos stopped too.
        dutchAuction.file("stopped", 3);
        vm.warp(vm.getBlockTimestamp() + 1801);
        vm.expectRevert(IDutchAuction.Stopped.selector);
        dutchAuction.redo(id, keeper);

        // Yank is never gated: settlement must always reclaim.
        dutchAuction.yank(id);
    }

    function test_governorPauseStopsAuctionHouse() public {
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 400e18, 100e18);
        _setRainPrice(0.6e18);

        uint256 id = liquidationTrigger.bark(vaultId, keeper);

        // Funding the bidder BEFORE the pause: the PSM is pause-gated too, so this must happen while live.
        _fundBidder(address(0xB1D), 200e6);

        // Pausing: in-flight takes must stop (the rev-4 scenario where keepers extracted collateral at bad-feed
        // prices during a paused incident). The governor is already wired into the auction house in Base.
        governor.pause("all");

        (, uint256 price, , ) = dutchAuction.getStatus(id);
        vm.prank(address(0xB1D));
        vm.expectRevert(SystemPaused.selector);
        dutchAuction.take(id, 400e18, price, address(0xB1D), "");

        // Unpause restores the market.
        governor.unpause();

        vm.prank(address(0xB1D));
        dutchAuction.take(id, 400e18, price, address(0xB1D), "");
    }

    /* ========================== 3. TAKE ECONOMICS ========================== */

    function test_takeRefundsLeftoverCollateralToVaultOwner() public {
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 400e18, 100e18);
        _setRainPrice(0.64e18);

        uint256 id = liquidationTrigger.bark(vaultId, keeper);

        _fundBidder(address(0xB1D), 200e6);

        // Buying the entire tab at the current price leaves collateral over; it returns to the OWNER.
        (, uint256 price, , ) = dutchAuction.getStatus(id);

        vm.prank(address(0xB1D));
        dutchAuction.take(id, 400e18, price, address(0xB1D), "");

        assertGt(vaultEngine.collateral(RAIN_ILK, user), 0, "leftover to owner");

        (, , , uint256 tab) = dutchAuction.getStatus(id);
        assertEq(tab, 0, "auction closed");
    }

    function test_takeAboveMaxPriceReverts() public {
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 400e18, 100e18);
        _setRainPrice(0.6e18);

        uint256 id = liquidationTrigger.bark(vaultId, keeper);

        _fundBidder(address(0xB1D), 200e6);

        (, uint256 price, , ) = dutchAuction.getStatus(id);

        vm.prank(address(0xB1D));
        vm.expectRevert(IDutchAuction.TooExpensive.selector);
        dutchAuction.take(id, 400e18, price - 1, address(0xB1D), "");
    }

    function test_takeNeedsResetAfterTail() public {
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 400e18, 100e18);
        _setRainPrice(0.6e18);

        uint256 id = liquidationTrigger.bark(vaultId, keeper);

        vm.warp(vm.getBlockTimestamp() + 1801);

        (bool needsRedo, uint256 price, , ) = dutchAuction.getStatus(id);
        assertTrue(needsRedo, "stale auction flagged");

        _fundBidder(address(0xB1D), 200e6);

        vm.prank(address(0xB1D));
        vm.expectRevert(IDutchAuction.NeedsReset.selector);
        dutchAuction.take(id, 400e18, price, address(0xB1D), "");
    }

    /* ========================== 4. PARAMETER GUARDS ========================== */

    function test_fileGuards() public {
        // chop below one.
        vm.expectRevert(ILiquidationTrigger.ChopBelowOne.selector);
        liquidationTrigger.file(RAIN_ILK, "chop", _WAD - 1);

        // barkFactor outside (0, 1].
        vm.expectRevert(ILiquidationTrigger.InvalidBarkFactor.selector);
        liquidationTrigger.file(RAIN_ILK, "barkFactor", 0);

        vm.expectRevert(ILiquidationTrigger.InvalidBarkFactor.selector);
        liquidationTrigger.file(RAIN_ILK, "barkFactor", _WAD + 1);

        // L-2: throttle outside (0, 1].
        vm.expectRevert(ILiquidationTrigger.InvalidThrottle.selector);
        liquidationTrigger.file("throttle", 0);

        vm.expectRevert(ILiquidationTrigger.InvalidThrottle.selector);
        liquidationTrigger.file("throttle", _WAD + 1);

        liquidationTrigger.file("throttle", _WAD / 4);
        assertEq(liquidationTrigger.throttle(), _WAD / 4, "throttle set");
    }

    function test_upchostTracksDustTimesChop() public {
        assertEq(dutchAuction.chost(), ((100 * _RAD * 113) / 100 / _WAD) * _WAD, "launch chost");

        vaultEngine.file(RAIN_ILK, "dust", 200 * _RAD);
        dutchAuction.upchost();

        assertEq(dutchAuction.chost(), ((200 * _RAD) * ((_WAD * 113) / 100)) / _WAD, "chost refreshed");
    }

    function test_barkSafeVaultReverts() public {
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 400e18, 100e18);

        // At $1 the vault sits at 400% -- exactly mat, far above the 260% bark line.
        vm.expectRevert(ILiquidationTrigger.NotUnsafe.selector);
        liquidationTrigger.bark(vaultId, keeper);
    }
}
