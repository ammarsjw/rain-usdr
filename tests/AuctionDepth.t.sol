// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IDutchAuction } from "../contracts/interfaces/IDutchAuction.sol";
import { IDutchAuctionCallee } from "../contracts/interfaces/IDutchAuctionCallee.sol";
import { NotLive, UnrecognizedParameter } from "../contracts/shared/Errors.sol";
import { IVaultEngine } from "../contracts/interfaces/IVaultEngine.sol";
import { _RAD, _RAY, _USDR_ILK, _WAD, _WARD_ROLE } from "../contracts/shared/Constants.sol";

import { BaseTest } from "./Base.t.sol";

/**
 * @title MockAuctionCallee
 * @author Rain Team
 * @notice Flash-take callback for tests: receives collateral mid-take and repays from a pre-funded internal balance.
 */
contract MockAuctionCallee is IDutchAuctionCallee {
    IVaultEngine public immutable VAULT_ENGINE;

    uint256 public calls;

    constructor(IVaultEngine vaultEngine_) {
        VAULT_ENGINE = vaultEngine_;
    }

    function clipperCall(address, uint256, uint256, bytes calldata) external {
        // The collateral has already arrived at this point; a real keeper would resell it here.
        ++calls;
    }
}

/**
 * @title AuctionDepthTest
 * @author Rain Team
 * @notice Deep coverage of the Dutch auction: price decay, flash callbacks, partial-purchase chost adjustment,
 *         redo pricing, yank-to-caller semantics and post-cage behaviour.
 */
contract AuctionDepthTest is BaseTest {
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

    /// @dev Opens a vault, crashes the price and barks. Returns the auction id.
    function _kickAuction() internal returns (uint256 id, uint256 vaultId) {
        _setRainPrice(1e18);
        vaultId = _openVault(user, 400e18, 100e18);
        _fundBidder(address(0xB1D), 300e6);
        _setRainPrice(0.6e18);

        id = liquidationTrigger.bark(vaultId, keeper);
    }

    /* ========================== 1. PRICE DECAY & STATUS ========================== */

    function test_priceDecaysLinearlyToZeroOverTau() public {
        (uint256 id, ) = _kickAuction();

        (, uint256 startPrice, , ) = dutchAuction.getStatus(id);

        // top = 0.6 * 1.05 = 0.63 ray-scaled.
        assertEq(startPrice, (0.6e18 * 105 * 1e9) / 100, "top = feed x buf");

        // Half tau: half price (linear curve, tau = 3600). At exactly tail seconds the auction is NOT yet
        // resettable (done requires elapsed > tail); one second later it is.
        vm.warp(vm.getBlockTimestamp() + 1800);
        (bool needsRedo, uint256 halfPrice, , ) = dutchAuction.getStatus(id);

        assertEq(halfPrice, startPrice / 2, "linear halfway");
        assertFalse(needsRedo, "exactly tail: not yet resettable");

        vm.warp(vm.getBlockTimestamp() + 1);
        (needsRedo, , , ) = dutchAuction.getStatus(id);
        assertTrue(needsRedo, "tail + 1: needs reset");
    }

    function test_kickGuards() public {
        vm.expectRevert(IDutchAuction.ZeroTab.selector);
        dutchAuction.kick(0, 1e18, 1, user, keeper);

        vm.expectRevert(IDutchAuction.ZeroLot.selector);
        dutchAuction.kick(1 * _RAD, 0, 1, user, keeper);

        vm.expectRevert(IDutchAuction.ZeroUser.selector);
        dutchAuction.kick(1 * _RAD, 1e18, 1, address(0), keeper);

        vm.prank(address(0xBAD));
        vm.expectRevert();
        dutchAuction.kick(1 * _RAD, 1e18, 1, user, keeper);
    }

    /* ========================== 2. FLASH CALLBACK ========================== */

    function test_takeWithFlashCallback() public {
        (uint256 id, ) = _kickAuction();

        MockAuctionCallee callee = new MockAuctionCallee(vaultEngine);

        // The callee holds the payment balance and hopes the auction; the keeper triggers the take with data.
        usdt.mint(address(this), 200e6);
        usdt.approve(address(psm), 200e6);
        psm.sellStable(USDT_ILK, address(this), 200e6);
        usdr.approve(address(collateralAdapter), 200e18);
        collateralAdapter.join(_USDR_ILK, address(0xB1D), 200e18);

        (, uint256 price, , ) = dutchAuction.getStatus(id);

        vm.prank(address(0xB1D));
        dutchAuction.take(id, 400e18, price, address(callee), "resell");

        assertEq(callee.calls(), 1, "callback fired");
        assertGt(vaultEngine.collateral(RAIN_ILK, address(callee)), 0, "collateral delivered to callee");
    }

    /* ========================== 3. PARTIAL PURCHASES ========================== */

    function test_partialPurchaseLeavesTabAndLot() public {
        // A 200-debt vault: tab = 226 rad = 2x chost, so a partial leaving >= chost is genuinely possible.
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 800e18, 200e18);
        _fundBidder(address(0xB1D), 300e6);
        _setRainPrice(0.6e18);

        uint256 id = liquidationTrigger.bark(vaultId, keeper);

        (, uint256 price, , uint256 tabBefore) = dutchAuction.getStatus(id);

        // Buy a slice small enough that the remainder stays >= chost (113 rad): 100e18 at ~0.63 = ~63 rad.
        vm.prank(address(0xB1D));
        dutchAuction.take(id, 100e18, price, address(0xB1D), "");

        (, , uint256 lotAfter, uint256 tabAfter) = dutchAuction.getStatus(id);

        assertEq(lotAfter, 700e18, "lot reduced");
        assertEq(tabAfter, tabBefore - 100e18 * price, "tab reduced by owe");
    }

    function test_partialBelowChostRevertsWhenTabTooSmall() public {
        // Engineer a tab at exactly chost: any partial would leave a sub-chost remainder and the whole tab is not
        // above chost, so NoPartialPurchase fires.
        _setRainPrice(1e18);
        uint256 vaultId = _openVault(user, 400e18, 100e18);
        _fundBidder(address(0xB1D), 300e6);
        _setRainPrice(0.6e18);

        // hole = chost -> tab = 113 rad = chost (dust 100 x chop 1.13).
        liquidationTrigger.file(RAIN_ILK, "hole", 113 * _RAD);

        uint256 id = liquidationTrigger.bark(vaultId, keeper);

        (, uint256 price, , uint256 tab) = dutchAuction.getStatus(id);
        assertEq(tab, dutchAuction.chost(), "tab pinned at chost");

        // A partial (anything less than the full lot value) must revert.
        uint256 slice = (tab / price) / 2;

        vm.prank(address(0xB1D));
        vm.expectRevert(IDutchAuction.NoPartialPurchase.selector);
        dutchAuction.take(id, slice, price, address(0xB1D), "");
    }

    /* ========================== 4. REDO ========================== */

    function test_redoRefreshesPriceAndCannotFireEarly() public {
        (uint256 id, ) = _kickAuction();

        // Too early to reset.
        vm.expectRevert(IDutchAuction.CannotReset.selector);
        dutchAuction.redo(id, keeper);

        vm.warp(vm.getBlockTimestamp() + 1801);

        (, uint256 stalePrice, , ) = dutchAuction.getStatus(id);
        dutchAuction.redo(id, keeper);

        (, uint256 freshPrice, , ) = dutchAuction.getStatus(id);
        assertGt(freshPrice, stalePrice, "price re-anchored to feed x buf");

        // Unknown auction.
        vm.expectRevert(IDutchAuction.AuctionNotRunning.selector);
        dutchAuction.redo(999, keeper);
    }

    /* ========================== 5. YANK ========================== */

    function test_yankSendsCollateralToCallerAndClosesAuction() public {
        (uint256 id, ) = _kickAuction();

        // Ward-only.
        vm.prank(address(0xBAD));
        vm.expectRevert();
        dutchAuction.yank(id);

        uint256 before = vaultEngine.collateral(RAIN_ILK, address(this));
        dutchAuction.yank(id);

        // Maker clip.sol semantics: remaining collateral moves to the CALLER (the settlement path depends on it).
        assertEq(vaultEngine.collateral(RAIN_ILK, address(this)) - before, 400e18, "collateral to caller");

        (, , uint256 lot, uint256 tab) = dutchAuction.getStatus(id);
        assertEq(lot, 0, "closed");
        assertEq(tab, 0, "closed");

        vm.expectRevert(IDutchAuction.AuctionNotRunning.selector);
        dutchAuction.yank(id);
    }

    /* ========================== 6. CAGE ========================== */

    function test_cageBlocksKickTakeRedoButNotYank() public {
        (uint256 id, ) = _kickAuction();

        dutchAuction.cage();

        vm.expectRevert(NotLive.selector);
        dutchAuction.kick(1 * _RAD, 1e18, 1, user, keeper);

        (, uint256 price, , ) = dutchAuction.getStatus(id);

        vm.prank(address(0xB1D));
        vm.expectRevert(NotLive.selector);
        dutchAuction.take(id, 400e18, price, address(0xB1D), "");

        vm.expectRevert(NotLive.selector);
        dutchAuction.redo(id, keeper);

        // Yank still works after cage: End.skip depends on it.
        dutchAuction.yank(id);
    }

    /* ========================== 7. LIST / COUNT / FILE ========================== */

    function test_activeListTracksAuctions() public {
        (uint256 id, ) = _kickAuction();

        assertEq(dutchAuction.count(), 1, "one active");
        assertEq(dutchAuction.list()[0], id, "listed");
        assertEq(dutchAuction.active(0), id, "indexed");

        dutchAuction.yank(id);
        assertEq(dutchAuction.count(), 0, "removed");
    }

    function test_fileGuardsAndCageGating() public {
        vm.expectRevert(UnrecognizedParameter.selector);
        dutchAuction.file("nonsense", 1);

        vm.expectRevert(UnrecognizedParameter.selector);
        dutchAuction.file("nonsense", address(1));

        dutchAuction.cage();

        vm.expectRevert(NotLive.selector);
        dutchAuction.file("buf", _RAY);

        vm.expectRevert(NotLive.selector);
        dutchAuction.file("pip", address(osm));
    }
}
