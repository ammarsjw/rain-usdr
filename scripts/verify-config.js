const hardhat = require("hardhat");

/**
 * Verifies the post-deployment risk-parameter surface.
 *
 * Complements verify-roles.js (access control) with a systemic gate against the recurring "correct code,
 * never configured" class (rev-2 hump, rev-4 exposureCap, rev-5 buybackReceiver): every governance risk
 * parameter must be either explicitly set or intentionally default, and every intentional default is asserted
 * here so a drive-by change is caught too.
 *
 * Exits non-zero loudly on any mismatch.
 */
const verifyConfig = async () => {
    const WAD = 10n ** 18n;
    const RAY = 10n ** 27n;
    const RAD = 10n ** 45n;

    const addresses = {
        VaultEngine: process.env.VAULT_ENGINE_ADDRESS,
        OracleSecurityModule: process.env.OSM_ADDRESS,
        PriceConverter: process.env.PRICE_CONVERTER_ADDRESS,
        ReserveAccounting: process.env.RESERVE_ACCOUNTING_ADDRESS,
        SolvencyEngine: process.env.SOLVENCY_ENGINE_ADDRESS,
        BalanceSheet: process.env.BALANCE_SHEET_ADDRESS,
        PegStabilityModule: process.env.PSM_ADDRESS,
        PriceCurve: process.env.PRICE_CURVE_ADDRESS,
        LiquidationTrigger: process.env.LIQUIDATION_TRIGGER_ADDRESS,
        DutchAuction: process.env.DUTCH_AUCTION_ADDRESS,
        Governor: process.env.GOVERNOR_ADDRESS,
        End: process.env.END_ADDRESS
    };

    for (const [name, address] of Object.entries(addresses)) {
        if (!address) {
            console.error(`MISSING ADDRESS: ${name} (env not set)`);
            process.exitCode = 1;
        }
    }
    if (process.exitCode) process.exit(1);

    const ilk = (name) => hardhat.ethers.encodeBytes32String(name);
    const rainIlk = ilk("RAIN-A");
    const usdtIlk = ilk("USDT-A");
    const usdcIlk = ilk("USDC-A");

    let failures = 0;

    const assertEq = (label, actual, expected) => {
        if (actual.toString() !== expected.toString()) {
            console.error(`CONFIG MISMATCH: ${label} - expected ${expected}, got ${actual}`);
            ++failures;
        } else {
            console.log(`OK: ${label} = ${expected}`);
        }
    };

    const assertNonZero = (label, actual) => {
        const zero = actual === 0n || actual === "0x0000000000000000000000000000000000000000";
        if (zero) {
            console.error(`CONFIG UNSET: ${label} is zero/default - must be explicitly configured`);
            ++failures;
        } else {
            console.log(`OK: ${label} set (${actual})`);
        }
    };

    // ------------------------------------------------------------------ VaultEngine
    const vaultEngine = await hardhat.ethers.getContractAt("VaultEngine", addresses.VaultEngine);

    assertEq("VaultEngine.globalLine", await vaultEngine.globalLine(), 1100000n * RAD);
    assertNonZero("VaultEngine.solvencyEngine", await vaultEngine.solvencyEngine());
    assertNonZero("VaultEngine.governor", await vaultEngine.governor());
    assertNonZero("VaultEngine.feeRecipient", await vaultEngine.feeRecipient());

    for (const [name, id, line] of [
        ["RAIN-A", rainIlk, 100000n * RAD],
        ["USDT-A", usdtIlk, 500000n * RAD],
        ["USDC-A", usdcIlk, 500000n * RAD]
    ]) {
        const ilkData = await vaultEngine.ilks(id);
        assertEq(`VaultEngine.ilks(${name}).line`, ilkData.line, line);
        // duty defaults to RAY (zero fee) and RAY is the intended launch value for every ilk: asserted, not
        // assumed.
        assertEq(`VaultEngine.ilks(${name}).duty`, ilkData.duty, RAY);
        assertEq(`VaultEngine.ilks(${name}).rate`, ilkData.rate, RAY);
    }

    assertEq("VaultEngine.ilks(RAIN-A).dust", (await vaultEngine.ilks(rainIlk)).dust, 100n * RAD);

    // Invariant: every PSM stable ilk is permanently fee-exempt; the volatile ilk is not.
    assertEq("VaultEngine.noFee(USDT-A)", await vaultEngine.noFee(usdtIlk), true);
    assertEq("VaultEngine.noFee(USDC-A)", await vaultEngine.noFee(usdcIlk), true);
    assertEq("VaultEngine.noFee(RAIN-A)", await vaultEngine.noFee(rainIlk), false);

    // ------------------------------------------------------------------ PriceConverter
    const priceConverter = await hardhat.ethers.getContractAt("PriceConverter", addresses.PriceConverter);

    assertEq("PriceConverter.par", await priceConverter.par(), RAY);
    assertEq("PriceConverter.ilks(RAIN-A).mat", (await priceConverter.ilks(rainIlk)).mat, 4n * RAY);
    assertEq("PriceConverter.ilks(USDT-A).mat", (await priceConverter.ilks(usdtIlk)).mat, RAY);
    assertEq("PriceConverter.ilks(USDC-A).mat", (await priceConverter.ilks(usdcIlk)).mat, RAY);
    assertEq("PriceConverter.ilks(USDT-A).fixedPrice", (await priceConverter.ilks(usdtIlk)).fixedPrice, true);
    assertEq("PriceConverter.ilks(USDC-A).fixedPrice", (await priceConverter.ilks(usdcIlk)).fixedPrice, true);
    assertNonZero("PriceConverter.ilks(RAIN-A).pip", (await priceConverter.ilks(rainIlk)).pip);

    // ------------------------------------------------------------------ SolvencyEngine
    const solvencyEngine = await hardhat.ethers.getContractAt("SolvencyEngine", addresses.SolvencyEngine);

    assertEq("SolvencyEngine.stressMarkdown", await solvencyEngine.stressMarkdown(), WAD / 2n);
    assertEq("SolvencyEngine.stressDepth", await solvencyEngine.stressDepth(), (WAD * 35n) / 100n);
    assertEq("SolvencyEngine.reserveFactor", await solvencyEngine.reserveFactor(), (WAD * 9n) / 10n);
    assertEq("SolvencyEngine.exposureCap", await solvencyEngine.exposureCap(), 250000n * WAD);
    assertNonZero("SolvencyEngine.osm", await solvencyEngine.osm());
    assertEq("SolvencyEngine.isVolatile(RAIN-A)", await solvencyEngine.isVolatile(rainIlk), true);

    // ------------------------------------------------------------------ BalanceSheet
    const balanceSheet = await hardhat.ethers.getContractAt("BalanceSheet", addresses.BalanceSheet);

    assertEq("BalanceSheet.wait", await balanceSheet.wait(), 561600n);
    assertEq("BalanceSheet.humpFloor", await balanceSheet.humpFloor(), 500000n * RAD);
    assertEq("BalanceSheet.humpRate", await balanceSheet.humpRate(), WAD / 10n);
    assertNonZero("BalanceSheet.reserveAccounting", await balanceSheet.reserveAccounting());
    assertNonZero("BalanceSheet.solvencyEngine", await balanceSheet.solvencyEngine());
    assertNonZero("BalanceSheet.buybackReceiver", await balanceSheet.buybackReceiver());

    // ------------------------------------------------------------------ PSM
    const psm = await hardhat.ethers.getContractAt("PegStabilityModule", addresses.PegStabilityModule);

    assertNonZero("PegStabilityModule.solvencyEngine", await psm.solvencyEngine());
    assertNonZero("PegStabilityModule.governor", await psm.governor());
    assertNonZero("PegStabilityModule.ilks(USDT-A).vaultId", (await psm.ilks(usdtIlk)).vaultId);
    assertNonZero("PegStabilityModule.ilks(USDC-A).vaultId", (await psm.ilks(usdcIlk)).vaultId);

    // ------------------------------------------------------------------ Liquidation stack
    const priceCurve = await hardhat.ethers.getContractAt("PriceCurve", addresses.PriceCurve);
    const liquidationTrigger = await hardhat.ethers.getContractAt("LiquidationTrigger", addresses.LiquidationTrigger);
    const dutchAuction = await hardhat.ethers.getContractAt("DutchAuction", addresses.DutchAuction);

    assertEq("PriceCurve.tau", await priceCurve.tau(), 3600n);
    assertEq("LiquidationTrigger.globalHole", await liquidationTrigger.globalHole(), 100000n * RAD);

    const rainLiquidation = await liquidationTrigger.ilks(rainIlk);
    assertEq("LiquidationTrigger.ilks(RAIN-A).chop", rainLiquidation.chop, (WAD * 113n) / 100n);
    assertEq("LiquidationTrigger.ilks(RAIN-A).hole", rainLiquidation.hole, 50000n * RAD);
    assertEq("LiquidationTrigger.ilks(RAIN-A).barkFactor", rainLiquidation.barkFactor, (WAD * 65n) / 100n);
    assertNonZero("LiquidationTrigger.ilks(RAIN-A).clip", rainLiquidation.clip);

    assertEq("DutchAuction.buf", await dutchAuction.buf(), (RAY * 105n) / 100n);
    assertEq("DutchAuction.tail", await dutchAuction.tail(), 1800n);
    assertEq("DutchAuction.cusp", await dutchAuction.cusp(), (RAY * 40n) / 100n);
    assertEq("DutchAuction.chip", await dutchAuction.chip(), (WAD * 2n) / 100n);
    assertNonZero("DutchAuction.chost (upchost run)", await dutchAuction.chost());

    // ------------------------------------------------------------------ Governor & End
    const governor = await hardhat.ethers.getContractAt("Governor", addresses.Governor);
    const endInstance = await hardhat.ethers.getContractAt("End", addresses.End);

    assertNonZero("Governor.delay", await governor.delay());
    assertNonZero("End.wait", await endInstance.wait());
    assertNonZero("End.liquidationTrigger", await endInstance.liquidationTrigger());
    assertNonZero("End.balanceSheet", await endInstance.balanceSheet());
    assertNonZero("End.priceConverter", await endInstance.priceConverter());

    if (failures > 0) {
        console.error(`\nverify-config FAILED with ${failures} mismatch(es).`);
        process.exit(1);
    }

    console.log("\nverify-config passed: every risk parameter is explicitly set or intentionally default.");
};

verifyConfig()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
