const hardhat = require("hardhat");

/**
 * Verifies the post-deployment risk-parameter surface.
 *
 * Complements verify-roles.js (access control) with a systemic gate against the recurring
 * "correct code, never configured" class (rev-2 hump, rev-5 buybackReceiver):
 * every governance risk parameter must be either explicitly set or intentionally default, and
 * every intentional default is asserted here so a drive-by change is caught too.
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
        CircuitBreaker: process.env.CIRCUIT_BREAKER_ADDRESS,
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

    const assertInvariant = (label, holds) => {
        if (!holds) {
            console.error(`CONFIG INVARIANT VIOLATED: ${label}`);
            ++failures;
        } else {
            console.log(`OK: ${label}`);
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

    const expectedRainDuty = process.env.RAIN_DUTY
        ? BigInt(process.env.RAIN_DUTY)
        : // ~2% APY, must match deploy-reserve.js default
          1000000000627937192491029810n;

    for (const [name, id, line, duty] of [
        ["RAIN-A", rainIlk, 100000n * RAD, expectedRainDuty],
        ["USDT-A", usdtIlk, 500000n * RAD, RAY],
        ["USDC-A", usdcIlk, 500000n * RAD, RAY]
    ]) {
        const ilkData = await vaultEngine.ilks(id);
        assertEq(`VaultEngine.ilks(${name}).line`, ilkData.line, line);
        // Stables stay at RAY (zero fee); RAIN-A carries the duty filed by deploy-reserve.js.
        assertEq(`VaultEngine.ilks(${name}).duty`, ilkData.duty, duty);
        assertEq(`VaultEngine.ilks(${name}).rate`, ilkData.rate, RAY);
    }

    assertEq("VaultEngine.ilks(RAIN-A).dust", (await vaultEngine.ilks(rainIlk)).dust, 100n * RAD);

    // The dynamic (liquidity-based) ceiling is disabled at launch: a zero safety factor leaves the static
    // line as the only cap, so effectiveLine must equal line until governance opts in by filing fSafety and
    // liquidity.
    assertEq(
        "VaultEngine.liquidityCeilings(RAIN-A).fSafety",
        (await vaultEngine.liquidityCeilings(rainIlk)).fSafety,
        0n
    );
    assertEq(
        "VaultEngine.liquidityCeilings(USDT-A).fSafety",
        (await vaultEngine.liquidityCeilings(usdtIlk)).fSafety,
        0n
    );
    assertEq(
        "VaultEngine.liquidityCeilings(USDC-A).fSafety",
        (await vaultEngine.liquidityCeilings(usdcIlk)).fSafety,
        0n
    );
    assertEq("VaultEngine.effectiveLine(RAIN-A)", await vaultEngine.effectiveLine(rainIlk), 100000n * RAD);
    assertEq("VaultEngine.effectiveLine(USDT-A)", await vaultEngine.effectiveLine(usdtIlk), 500000n * RAD);
    assertEq("VaultEngine.effectiveLine(USDC-A)", await vaultEngine.effectiveLine(usdcIlk), 500000n * RAD);

    // Invariant: every PSM stable ilk is permanently fee-exempt; the volatile ilk is not.
    assertEq("VaultEngine.noFee(USDT-A)", await vaultEngine.noFee(usdtIlk), true);
    assertEq("VaultEngine.noFee(USDC-A)", await vaultEngine.noFee(usdcIlk), true);
    assertEq("VaultEngine.noFee(RAIN-A)", await vaultEngine.noFee(rainIlk), false);

    // Invariant: every PSM stable ilk is exclusively bound to the PSM (no third-party 1:1 vaults that would
    // desync the reserve-backing check); the volatile ilk stays open to all.
    assertEq("VaultEngine.exclusiveTo(USDT-A)", await vaultEngine.exclusiveTo(usdtIlk), addresses.PegStabilityModule);
    assertEq("VaultEngine.exclusiveTo(USDC-A)", await vaultEngine.exclusiveTo(usdcIlk), addresses.PegStabilityModule);
    assertEq(
        "VaultEngine.exclusiveTo(RAIN-A)",
        await vaultEngine.exclusiveTo(rainIlk),
        "0x0000000000000000000000000000000000000000"
    );

    // ------------------------------------------------------------------ PriceConverter

    const priceConverter = await hardhat.ethers.getContractAt("PriceConverter", addresses.PriceConverter);

    assertEq("PriceConverter.par", await priceConverter.par(), RAY);
    assertEq("PriceConverter.ilks(RAIN-A).mat", (await priceConverter.ilks(rainIlk)).mat, 4n * RAY);
    assertEq("PriceConverter.ilks(USDT-A).mat", (await priceConverter.ilks(usdtIlk)).mat, RAY);
    assertEq("PriceConverter.ilks(USDC-A).mat", (await priceConverter.ilks(usdcIlk)).mat, RAY);
    assertEq("PriceConverter.ilks(USDT-A).fixedPrice", (await priceConverter.ilks(usdtIlk)).fixedPrice, true);
    assertEq("PriceConverter.ilks(USDC-A).fixedPrice", (await priceConverter.ilks(usdcIlk)).fixedPrice, true);
    assertNonZero("PriceConverter.oracleSecurityModule", await priceConverter.oracleSecurityModule());

    // ------------------------------------------------------------------ SolvencyEngine

    const solvencyEngine = await hardhat.ethers.getContractAt("SolvencyEngine", addresses.SolvencyEngine);

    assertEq("SolvencyEngine.stressMarkdown", await solvencyEngine.stressMarkdown(), WAD / 2n);
    assertEq("SolvencyEngine.stressDepth", await solvencyEngine.stressDepth(), (WAD * 35n) / 100n);
    assertEq("SolvencyEngine.reserveFactor", await solvencyEngine.reserveFactor(), (WAD * 9n) / 10n);
    assertNonZero("SolvencyEngine.oracleSecurityModule", await solvencyEngine.oracleSecurityModule());
    assertEq("SolvencyEngine.isVolatile(RAIN-A)", await solvencyEngine.isVolatile(rainIlk), true);

    // ------------------------------------------------------------------ BalanceSheet

    const balanceSheet = await hardhat.ethers.getContractAt("BalanceSheet", addresses.BalanceSheet);

    assertEq("BalanceSheet.wait", await balanceSheet.wait(), 561600n);
    assertEq("BalanceSheet.humpFloor", await balanceSheet.humpFloor(), 500000n * RAD);
    assertEq("BalanceSheet.humpRate", await balanceSheet.humpRate(), WAD / 10n);
    assertNonZero("BalanceSheet.reserveAccounting", await balanceSheet.reserveAccounting());
    assertNonZero("BalanceSheet.solvencyEngine", await balanceSheet.solvencyEngine());
    assertNonZero("BalanceSheet.buybackReceiver", await balanceSheet.buybackReceiver());
    assertNonZero("BalanceSheet.oracleSecurityModule", await balanceSheet.oracleSecurityModule());
    assertEq("BalanceSheet.rainIlk", await balanceSheet.rainIlk(), rainIlk);
    // The genesis snapshot must exist: distributeSurplus refuses to run against a missing (or immature)
    // lagged reserve snapshot, so an unset laggedReserveAt means no distribution can ever succeed until a
    // keeper takes the first snapshot and it matures.
    assertNonZero("BalanceSheet.laggedReserveAt (genesis snapshot taken)", await balanceSheet.laggedReserveAt());
    assertNonZero("BalanceSheet.backstopCap", await balanceSheet.backstopCap());
    assertEq("BalanceSheet.backstopHaircut", await balanceSheet.backstopHaircut(), (WAD * 90n) / 100n);

    // ------------------------------------------------------------------ OSM

    const osm = await hardhat.ethers.getContractAt("OracleSecurityModule", addresses.OracleSecurityModule);
    assertEq("OracleSecurityModule.maxAge", await osm.maxAge(), 21600n);

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
    assertNonZero("LiquidationTrigger.dutchAuction", await liquidationTrigger.dutchAuction());

    const rainAuction = await dutchAuction.ilks(rainIlk);
    assertEq("DutchAuction.ilks(RAIN-A).buf", rainAuction.buf, (RAY * 105n) / 100n);
    assertEq("DutchAuction.ilks(RAIN-A).tail", rainAuction.tail, 1800n);
    assertEq("DutchAuction.ilks(RAIN-A).cusp", rainAuction.cusp, (RAY * 40n) / 100n);
    assertEq("DutchAuction.chip", await dutchAuction.chip(), (WAD * 2n) / 100n);
    // (chost covered by the all-ilks curve-invariant loop below.)

    // ------------------------------------------------------------------ Auction curve invariants (all ilks)
    //
    // Guards the zero-price take window: with `cusp == 0` the reset condition `price·RAY/top < cusp`
    // (strict <) can NEVER fire, so only `tail` ends an auction; combined with `tail >= tau` the linear
    // curve reaches price 0 while the auction still counts as running and `take` hands over the whole
    // lot for 0 USDR. Neither `DutchAuction.file` nor `PriceCurve.file` range-checks this relationship
    // (tau is global, tail/cusp are per-ilk), so it is enforced here for EVERY ilk that is liquidation-
    // or auction-configured — including future ilks onboarded through this pipeline. Invariants:
    //   buf > RAY            (auction must start above market, and a zero buf bricks kick)
    //   0 < cusp < RAY       (zero disarms the price-based reset; >= RAY resets instantly)
    //   0 < tail < tau       (the time-based reset must fire before the curve can reach zero;
    //                         with cusp > 0 the price reset fires first anyway — belt and braces)
    //   chost != 0           (upchost was run, partial-take dust protection is armed)
    const tau = await priceCurve.tau();
    const ilkIdsLength = await vaultEngine.ilkIdsLength();

    for (let i = 0n; i < ilkIdsLength; ++i) {
        const ilkId = await vaultEngine.ilkIds(i);
        const ilkName = hardhat.ethers.decodeBytes32String(ilkId);

        const triggerIlk = await liquidationTrigger.ilks(ilkId);
        const auctionIlk = await dutchAuction.ilks(ilkId);

        const liquidatable = triggerIlk.chop !== 0n || triggerIlk.hole !== 0n || triggerIlk.barkFactor !== 0n;
        const auctionConfigured = auctionIlk.buf !== 0n || auctionIlk.tail !== 0n || auctionIlk.cusp !== 0n;

        if (!liquidatable && !auctionConfigured) {
            // Never enters the auction house (e.g. PSM stable ilks). Nothing to assert.
            console.log(`OK: ${ilkName} not liquidation/auction configured - curve invariants skipped`);
            continue;
        }

        assertInvariant(`DutchAuction.ilks(${ilkName}).buf > RAY`, auctionIlk.buf > RAY);
        assertInvariant(`DutchAuction.ilks(${ilkName}).cusp > 0`, auctionIlk.cusp > 0n);
        assertInvariant(`DutchAuction.ilks(${ilkName}).cusp < RAY`, auctionIlk.cusp < RAY);
        assertInvariant(`DutchAuction.ilks(${ilkName}).tail > 0`, auctionIlk.tail > 0n);
        assertInvariant(
            `DutchAuction.ilks(${ilkName}).tail (${auctionIlk.tail}) < PriceCurve.tau (${tau})`,
            auctionIlk.tail < tau
        );
        assertNonZero(`DutchAuction.ilks(${ilkName}).chost (upchost run)`, auctionIlk.chost);
    }

    const circuitBreaker = await hardhat.ethers.getContractAt("CircuitBreaker", addresses.CircuitBreaker);
    assertEq("CircuitBreaker.isWatched(RAIN-A)", await circuitBreaker.isWatched(rainIlk), true);
    assertEq("CircuitBreaker.ilkCount", await circuitBreaker.ilkCount(), 1n);

    // ------------------------------------------------------------------ Governor & End

    const governor = await hardhat.ethers.getContractAt("Governor", addresses.Governor);
    const endInstance = await hardhat.ethers.getContractAt("End", addresses.End);

    assertNonZero("Governor.delay", await governor.delay());
    assertEq("Governor.PAUSE_MAX", await governor.PAUSE_MAX(), 72n * 3600n);
    assertEq("Governor.PAUSE_COOLDOWN", await governor.PAUSE_COOLDOWN(), 72n * 3600n);
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
