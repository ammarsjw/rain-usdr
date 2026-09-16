// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { CollateralAdapter } from "../../contracts/core/CollateralAdapter.sol";
import { USDR } from "../../contracts/token/USDR.sol";
import { VaultEngine } from "../../contracts/core/VaultEngine.sol";
import { Governor } from "../../contracts/governance/Governor.sol";
import { IPriceSource } from "../../contracts/interfaces/IPriceSource.sol";
import { CircuitBreaker } from "../../contracts/liquidation/CircuitBreaker.sol";
import { DutchAuction } from "../../contracts/liquidation/DutchAuction.sol";
import { LiquidationTrigger } from "../../contracts/liquidation/LiquidationTrigger.sol";
import { PriceCurve } from "../../contracts/liquidation/PriceCurve.sol";
import { OracleSecurityModule } from "../../contracts/oracle/OracleSecurityModule.sol";
import { PriceConverter } from "../../contracts/oracle/PriceConverter.sol";
import { BalanceSheet } from "../../contracts/reserve/BalanceSheet.sol";
import { PegStabilityModule } from "../../contracts/reserve/PegStabilityModule.sol";
import { ReserveAccounting } from "../../contracts/reserve/ReserveAccounting.sol";
import { SolvencyEngine } from "../../contracts/reserve/SolvencyEngine.sol";
import { End } from "../../contracts/governance/End.sol";
import {
    _BURNER_ROLE,
    _COMMITTER_ROLE,
    _RAD,
    _RAY,
    _READER_ROLE,
    _RECORDER_ROLE,
    _USDR_ILK,
    _WAD,
    _WARD_ROLE
} from "../../contracts/shared/Constants.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockPriceSource } from "../mocks/MockPriceSource.sol";

/**
 * @title BaseTest
 * @author Rain Team
 * @notice Shared test harness that deploys and wires the full USDR system. Concrete test contracts inherit
 *         from this and add their own scenarios.
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
    End internal end;

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
        dutchAuction = new DutchAuction(vaultEngine);
        circuitBreaker = new CircuitBreaker(vaultEngine, osm);

        // Wiring the core. Vault Engine ilks must exist before the PSM registers its ilks: PSM registration
        // opens the module's dedicated vault in the Vault Engine.
        vaultEngine.init(RAIN_ILK);
        vaultEngine.init(USDT_ILK);
        vaultEngine.init(USDC_ILK);

        // Permanently pinning the stable (PSM) ilks' stability fee to zero. PSM.init requires this.
        vaultEngine.file(USDT_ILK, "noFee", 1);
        vaultEngine.file(USDC_ILK, "noFee", 1);

        // Deploying the PSMs and the Governor.
        psm = new PegStabilityModule(collateralAdapter, reserveAccounting);

        // Binding the stable (PSM) ilks exclusively to the PSM BEFORE it opens its vaults: no other owner
        // may ever hold a vault on a 1:1 ilk (the reserve-backing check in the Balance Sheet assumes all
        // debt on these ilks is the PSM's).
        vaultEngine.file(USDT_ILK, "exclusiveTo", address(psm));
        vaultEngine.file(USDC_ILK, "exclusiveTo", address(psm));

        psm.init(USDT_ILK);
        psm.init(USDC_ILK);
        governor = new Governor(48 hours);

        vaultEngine.grantRole(_WARD_ROLE, address(collateralAdapter));
        vaultEngine.grantRole(_WARD_ROLE, address(priceConverter));
        vaultEngine.grantRole(_WARD_ROLE, address(liquidationTrigger));
        vaultEngine.grantRole(_WARD_ROLE, address(dutchAuction));
        vaultEngine.grantRole(_WARD_ROLE, address(balanceSheet));

        // Stability fee wiring: accrued fees are credited to the Balance Sheet as surplus.
        vaultEngine.file("feeRecipient", address(balanceSheet));
        usdr.grantRole(_WARD_ROLE, address(collateralAdapter));
        usdr.grantRole(_BURNER_ROLE, address(collateralAdapter));

        // Wiring the oracles (RAIN 400%, stables 100%).
        osm.grantRole(_READER_ROLE, address(priceConverter));
        osm.grantRole(_READER_ROLE, address(dutchAuction));
        osm.grantRole(_READER_ROLE, address(circuitBreaker));
        // Staleness: a current price older than six hours fails closed on peek/read (and therefore on poke →
        // spot=0).
        osm.file("maxAge", 6 hours);
        priceConverter.file("oracleSecurityModule", address(osm));
        priceConverter.file(RAIN_ILK, "mat", 4 * _RAY);
        priceConverter.file(USDT_ILK, "mat", _RAY);
        priceConverter.file(USDC_ILK, "mat", _RAY);
        priceConverter.file(USDT_ILK, "fixed", 1);
        priceConverter.file(USDC_ILK, "fixed", 1);
        priceConverter.poke(USDT_ILK);
        priceConverter.poke(USDC_ILK);

        // Wiring the reserve stack.
        reserveAccounting.grantRole(_COMMITTER_ROLE, address(solvencyEngine));
        reserveAccounting.grantRole(_RECORDER_ROLE, address(psm));
        solvencyEngine.addVolatileIlk(RAIN_ILK);
        solvencyEngine.file("oracleSecurityModule", address(osm));
        osm.grantRole(_READER_ROLE, address(solvencyEngine));

        // Wiring the solvency gate: hard gates (frob, PSM redemption, surplus distribution) and soft refresh
        // hooks (OSM poke, drip inside the Vault Engine).
        vaultEngine.file("solvencyEngine", address(solvencyEngine));
        psm.file("solvencyEngine", address(solvencyEngine));
        balanceSheet.file("solvencyEngine", address(solvencyEngine));
        balanceSheet.file("oracleSecurityModule", address(osm));
        balanceSheet.file("rainIlk", RAIN_ILK);
        balanceSheet.file("backstopCap", 50_000 * _RAD);
        osm.grantRole(_READER_ROLE, address(balanceSheet));
        osm.file("solvencyEngine", address(solvencyEngine));

        // Wiring the liquidation stack (launch parameters from the spec).
        priceCurve.file("tau", 3600);
        liquidationTrigger.file("globalHole", 100_000 * _RAD);
        liquidationTrigger.file("balanceSheet", address(balanceSheet));
        liquidationTrigger.file("circuitBreaker", address(circuitBreaker));
        circuitBreaker.addIlk(RAIN_ILK);
        liquidationTrigger.file(RAIN_ILK, "chop", (_WAD * 113) / 100);
        liquidationTrigger.file(RAIN_ILK, "hole", 50_000 * _RAD);
        liquidationTrigger.file("dutchAuction", address(dutchAuction));
        liquidationTrigger.file(RAIN_ILK, "barkFactor", (_WAD * 65) / 100);
        liquidationTrigger.grantRole(_WARD_ROLE, address(dutchAuction));
        balanceSheet.grantRole(_WARD_ROLE, address(liquidationTrigger));
        balanceSheet.grantRole(_WARD_ROLE, address(dutchAuction));
        dutchAuction.file(RAIN_ILK, "buf", (_RAY * 105) / 100);
        dutchAuction.file(RAIN_ILK, "tail", 1800);
        dutchAuction.file(RAIN_ILK, "cusp", (_RAY * 40) / 100);
        dutchAuction.file("chip", (_WAD * 2) / 100);
        dutchAuction.file("oracleSecurityModule", address(osm));
        dutchAuction.file("liquidationTrigger", address(liquidationTrigger));
        dutchAuction.file("balanceSheet", address(balanceSheet));
        dutchAuction.file("priceCurve", address(priceCurve));
        dutchAuction.grantRole(_WARD_ROLE, address(liquidationTrigger));

        // Wiring the Governor's emergency pause into the gated entry points (deploy-script parity).
        vaultEngine.file("governor", address(governor));
        psm.file("governor", address(governor));
        liquidationTrigger.file("governor", address(governor));
        dutchAuction.file("governor", address(governor));

        // Deploying and wiring the End (emergency settlement).
        end = new End(vaultEngine);
        end.file("liquidationTrigger", address(liquidationTrigger));
        end.file("balanceSheet", address(balanceSheet));
        end.file("priceConverter", address(priceConverter));
        end.file("wait", 0);
        vaultEngine.grantRole(_WARD_ROLE, address(end));
        liquidationTrigger.grantRole(_WARD_ROLE, address(end));
        priceConverter.grantRole(_WARD_ROLE, address(end));
        dutchAuction.grantRole(_WARD_ROLE, address(end));
        osm.grantRole(_READER_ROLE, address(end));

        // Setting launch ceilings, liquidity-based safety factors, and minimum vault size.
        vaultEngine.file("globalLine", 1_100_000 * _RAD);
        vaultEngine.file(RAIN_ILK, "line", 100_000 * _RAD);
        vaultEngine.file(USDT_ILK, "line", 500_000 * _RAD);
        vaultEngine.file(USDC_ILK, "line", 500_000 * _RAD);
        vaultEngine.file(RAIN_ILK, "dust", 100 * _RAD);
        // Spec defaults: f_safety 0.05 RAIN / 0.50 stables. Liquidity set at the hard cap so effectiveLine ==
        // line until governance files a tighter market figure.
        vaultEngine.file(RAIN_ILK, "fSafety", (_WAD * 5) / 100);
        vaultEngine.file(USDT_ILK, "fSafety", (_WAD * 50) / 100);
        vaultEngine.file(USDC_ILK, "fSafety", (_WAD * 50) / 100);
        vaultEngine.file(RAIN_ILK, "liquidity", 2_000_000 * _WAD); // 2M * 0.05 = 100k
        vaultEngine.file(USDT_ILK, "liquidity", 1_000_000 * _WAD); // 1M * 0.50 = 500k
        vaultEngine.file(USDC_ILK, "liquidity", 1_000_000 * _WAD);

        // Caching the auction's dust-times-chop threshold now that dust and chop are set.
        dutchAuction.upchost(RAIN_ILK);
    }

    /// @dev Reads RAIN's cached dust-times-chop threshold from the auction house's per-ilk settings.
    function _rainChost() internal view returns (uint256 chost) {
        (, , , chost) = dutchAuction.ilks(RAIN_ILK);
    }
}
