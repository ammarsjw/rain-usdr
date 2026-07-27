// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { USDR } from "../contracts/core/USDR.sol";
import { VaultEngine } from "../contracts/core/VaultEngine.sol";
import { CollateralAdapter } from "../contracts/core/CollateralAdapter.sol";
import { OracleSecurityModule } from "../contracts/oracle/OracleSecurityModule.sol";
import { PriceConverter } from "../contracts/oracle/PriceConverter.sol";
import { PegStabilityModule } from "../contracts/psm/PegStabilityModule.sol";
import { ReserveAccounting } from "../contracts/reserve/ReserveAccounting.sol";
import { SolvencyEngine } from "../contracts/reserve/SolvencyEngine.sol";
import { BalanceSheet } from "../contracts/reserve/BalanceSheet.sol";
import { PriceCurve } from "../contracts/liquidation/PriceCurve.sol";
import { LiquidationTrigger } from "../contracts/liquidation/LiquidationTrigger.sol";
import { DutchAuction } from "../contracts/liquidation/DutchAuction.sol";
import { CircuitBreaker } from "../contracts/liquidation/CircuitBreaker.sol";
import { Governor } from "../contracts/governance/Governor.sol";
import { IPriceSource } from "../contracts/interfaces/IPriceSource.sol";
import { RAD, RAY, WAD } from "../contracts/shared/Constants.sol";

import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockPriceSource } from "./mocks/MockPriceSource.sol";

/**
 * @title BaseTest.
 * @author Rain Team.
 * @notice Shared test harness that deploys and wires the full USDR system. Concrete test
 *         contracts inherit from this and add their own scenarios.
 */
abstract contract BaseTest is Test {
    /* ========================== STATE VARIABLES ========================== */

    USDR internal usdr;
    VaultEngine internal vaultEngine;
    CollateralAdapter internal usdrAdapter;
    CollateralAdapter internal rainAdapter;
    CollateralAdapter internal usdtAdapter;
    CollateralAdapter internal usdcAdapter;
    OracleSecurityModule internal osm;
    PriceConverter internal priceConverter;
    PegStabilityModule internal usdtPsm;
    PegStabilityModule internal usdcPsm;
    ReserveAccounting internal reserveAccounting;
    SolvencyEngine internal solvencyEngine;
    BalanceSheet internal balanceSheet;
    PriceCurve internal priceCurve;
    LiquidationTrigger internal liquidationTrigger;
    DutchAuction internal rainClipper;
    CircuitBreaker internal circuitBreaker;
    Governor internal governor;

    MockERC20 internal rain;
    MockERC20 internal usdt;
    MockERC20 internal usdc;
    MockPriceSource internal rainPriceSource;

    bytes32 internal constant RAIN_ILK = "RAIN-A";
    bytes32 internal constant USDT_ILK = "USDT-A";
    bytes32 internal constant USDC_ILK = "USDC-A";

    address internal user = address(0xBEEF);
    address internal keeper = address(0xCAFE);

    /* ========================== FUNCTIONS ========================== */

    function setUp() public virtual {
        // Deploying mock tokens (USDT and USDC use 6 decimals; RAIN uses 18).
        rain = new MockERC20("Rain", "RAIN", 18);
        usdt = new MockERC20("Tether USD", "USDT", 6);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        rainPriceSource = new MockPriceSource(1 * WAD);

        // Deploying the core.
        usdr = new USDR();
        vaultEngine = new VaultEngine();
        usdrAdapter = new CollateralAdapter(vaultEngine, bytes32(0), IERC20Metadata(address(usdr)), true);
        rainAdapter = new CollateralAdapter(vaultEngine, RAIN_ILK, IERC20Metadata(address(rain)), false);
        usdtAdapter = new CollateralAdapter(vaultEngine, USDT_ILK, IERC20Metadata(address(usdt)), false);
        usdcAdapter = new CollateralAdapter(vaultEngine, USDC_ILK, IERC20Metadata(address(usdc)), false);

        // Deploying the oracles.
        osm = new OracleSecurityModule();
        osm.change(RAIN_ILK, IPriceSource(address(rainPriceSource)));
        priceConverter = new PriceConverter(vaultEngine);

        // Deploying the reserve stack.
        reserveAccounting = new ReserveAccounting();
        solvencyEngine = new SolvencyEngine(vaultEngine, reserveAccounting);
        balanceSheet = new BalanceSheet(vaultEngine);

        // Deploying the liquidation stack.
        priceCurve = new PriceCurve();
        liquidationTrigger = new LiquidationTrigger(vaultEngine);
        rainClipper = new DutchAuction(vaultEngine, RAIN_ILK);
        circuitBreaker = new CircuitBreaker(osm, RAIN_ILK);

        // Deploying the PSMs and the Governor.
        usdtPsm = new PegStabilityModule(usdtAdapter, usdrAdapter, reserveAccounting);
        usdcPsm = new PegStabilityModule(usdcAdapter, usdrAdapter, reserveAccounting);
        governor = new Governor(48 hours);

        // Wiring the core.
        vaultEngine.init(RAIN_ILK);
        vaultEngine.init(USDT_ILK);
        vaultEngine.init(USDC_ILK);
        vaultEngine.rely(address(usdrAdapter));
        vaultEngine.rely(address(rainAdapter));
        vaultEngine.rely(address(usdtAdapter));
        vaultEngine.rely(address(usdcAdapter));
        vaultEngine.rely(address(priceConverter));
        vaultEngine.rely(address(liquidationTrigger));
        vaultEngine.rely(address(rainClipper));
        vaultEngine.rely(address(balanceSheet));
        usdr.rely(address(usdrAdapter));

        // Wiring the oracles (RAIN 400%, stables 100%).
        osm.kiss(address(priceConverter));
        osm.kiss(address(rainClipper));
        osm.kiss(address(circuitBreaker));
        priceConverter.file(RAIN_ILK, "pip", address(osm));
        priceConverter.file(RAIN_ILK, "mat", 4 * RAY);

        // Wiring the reserve stack.
        reserveAccounting.addCommitter(address(solvencyEngine));
        reserveAccounting.addRecorder(address(usdtPsm));
        reserveAccounting.addRecorder(address(usdcPsm));
        solvencyEngine.addVolatileIlk(RAIN_ILK);

        // Wiring the liquidation stack (launch parameters from the spec).
        priceCurve.file("tau", 3600);
        liquidationTrigger.file("Hole", 100_000 * RAD);
        liquidationTrigger.file("balanceSheet", address(balanceSheet));
        liquidationTrigger.file("circuitBreaker", address(circuitBreaker));
        liquidationTrigger.file(RAIN_ILK, "chop", (WAD * 113) / 100);
        liquidationTrigger.file(RAIN_ILK, "hole", 50_000 * RAD);
        liquidationTrigger.file(RAIN_ILK, "clip", address(rainClipper));
        liquidationTrigger.rely(address(rainClipper));
        rainClipper.file("buf", (RAY * 105) / 100);
        rainClipper.file("tail", 1800);
        rainClipper.file("cusp", (RAY * 40) / 100);
        rainClipper.file("chip", (WAD * 2) / 100);
        rainClipper.file("pip", address(osm));
        rainClipper.file("dog", address(liquidationTrigger));
        rainClipper.file("vow", address(balanceSheet));
        rainClipper.file("calc", address(priceCurve));
        rainClipper.rely(address(liquidationTrigger));

        // Setting launch ceilings and minimum vault size.
        vaultEngine.file("Line", 1_100_000 * RAD);
        vaultEngine.file(RAIN_ILK, "line", 100_000 * RAD);
        vaultEngine.file(USDT_ILK, "line", 500_000 * RAD);
        vaultEngine.file(USDC_ILK, "line", 500_000 * RAD);
        vaultEngine.file(RAIN_ILK, "dust", 100 * RAD);
    }
}
