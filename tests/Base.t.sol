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
import { _RAD, _RAY, _USDR_ILK, _WAD } from "../contracts/shared/Constants.sol";

import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockPriceSource } from "./mocks/MockPriceSource.sol";

/**
 * @title BaseTest
 * @author Rain Team
 * @notice Shared test harness that deploys and wires the full USDR system. Concrete test
 *         contracts inherit from this and add their own scenarios.
 */
abstract contract BaseTest is Test {
    /* ========================== STATE VARIABLES ========================== */

    USDR internal usdr;
    VaultEngine internal vaultEngine;
    CollateralAdapter internal collateralAdapter;
    OracleSecurityModule internal osm;
    PriceConverter internal priceConverter;
    PegStabilityModule internal psm;
    ReserveAccounting internal reserveAccounting;
    SolvencyEngine internal solvencyEngine;
    BalanceSheet internal balanceSheet;
    PriceCurve internal priceCurve;
    LiquidationTrigger internal liquidationTrigger;
    DutchAuction internal dutchAuction;
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
        rainPriceSource = new MockPriceSource(1 * _WAD);

        // Deploying the core.
        usdr = new USDR();
        vaultEngine = new VaultEngine();
        collateralAdapter = new CollateralAdapter(vaultEngine);
        collateralAdapter.init(_USDR_ILK, IERC20Metadata(address(usdr)));
        collateralAdapter.init(RAIN_ILK, IERC20Metadata(address(rain)));
        collateralAdapter.init(USDT_ILK, IERC20Metadata(address(usdt)));
        collateralAdapter.init(USDC_ILK, IERC20Metadata(address(usdc)));

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
        dutchAuction = new DutchAuction(vaultEngine, RAIN_ILK);
        circuitBreaker = new CircuitBreaker(osm, RAIN_ILK);

        // Deploying the PSMs and the Governor.
        psm = new PegStabilityModule(collateralAdapter, reserveAccounting);
        psm.init(USDT_ILK);
        psm.init(USDC_ILK);
        governor = new Governor(48 hours);

        // Wiring the core.
        vaultEngine.init(RAIN_ILK);
        vaultEngine.init(USDT_ILK);
        vaultEngine.init(USDC_ILK);
        vaultEngine.rely(address(collateralAdapter));
        vaultEngine.rely(address(priceConverter));
        vaultEngine.rely(address(liquidationTrigger));
        vaultEngine.rely(address(dutchAuction));
        vaultEngine.rely(address(balanceSheet));
        usdr.rely(address(collateralAdapter));

        // Wiring the oracles (RAIN 400%, stables 100%).
        osm.kiss(address(priceConverter));
        osm.kiss(address(dutchAuction));
        osm.kiss(address(circuitBreaker));
        priceConverter.file(RAIN_ILK, "pip", address(osm));
        priceConverter.file(RAIN_ILK, "mat", 4 * _RAY);
        priceConverter.file(USDT_ILK, "mat", _RAY);
        priceConverter.file(USDC_ILK, "mat", _RAY);
        priceConverter.file(USDT_ILK, "fixed", 1);
        priceConverter.file(USDC_ILK, "fixed", 1);
        priceConverter.poke(USDT_ILK);
        priceConverter.poke(USDC_ILK);

        // Wiring the reserve stack.
        reserveAccounting.addCommitter(address(solvencyEngine));
        reserveAccounting.addRecorder(address(psm));
        solvencyEngine.addVolatileIlk(RAIN_ILK);

        // Wiring the liquidation stack (launch parameters from the spec).
        priceCurve.file("tau", 3600);
        liquidationTrigger.file("Hole", 100_000 * _RAD);
        liquidationTrigger.file("balanceSheet", address(balanceSheet));
        liquidationTrigger.file("circuitBreaker", address(circuitBreaker));
        liquidationTrigger.file(RAIN_ILK, "chop", (_WAD * 113) / 100);
        liquidationTrigger.file(RAIN_ILK, "hole", 50_000 * _RAD);
        liquidationTrigger.file(RAIN_ILK, "clip", address(dutchAuction));
        liquidationTrigger.rely(address(dutchAuction));
        dutchAuction.file("buf", (_RAY * 105) / 100);
        dutchAuction.file("tail", 1800);
        dutchAuction.file("cusp", (_RAY * 40) / 100);
        dutchAuction.file("chip", (_WAD * 2) / 100);
        dutchAuction.file("pip", address(osm));
        dutchAuction.file("dog", address(liquidationTrigger));
        dutchAuction.file("vow", address(balanceSheet));
        dutchAuction.file("calc", address(priceCurve));
        dutchAuction.rely(address(liquidationTrigger));

        // Setting launch ceilings and minimum vault size.
        vaultEngine.file("Line", 1_100_000 * _RAD);
        vaultEngine.file(RAIN_ILK, "line", 100_000 * _RAD);
        vaultEngine.file(USDT_ILK, "line", 500_000 * _RAD);
        vaultEngine.file(USDC_ILK, "line", 500_000 * _RAD);
        vaultEngine.file(RAIN_ILK, "dust", 100 * _RAD);
    }
}
