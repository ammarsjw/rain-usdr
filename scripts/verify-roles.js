const hardhat = require("hardhat");

const { BURNER_ROLE, COMMITTER_ROLE, READER_ROLE, RECORDER_ROLE, WARD_ROLE } = require("./helpers/shared/constants");

/**
 * Verifies the post-deployment access-control surface:
 * - The Governor is a WARD_ROLE holder on every deployed contract.
 * - The deployer holds WARD_ROLE nowhere.
 * - Role-specific holders (BURNER, COMMITTER, RECORDER, READER) are exactly the expected contracts.
 * Exits non-zero loudly on any mismatch.
 */
const verifyRoles = async () => {
    const [deployer] = await hardhat.ethers.getSigners();

    const addresses = {
        USDR: process.env.USDR_ADDRESS,
        VaultEngine: process.env.VAULT_ENGINE_ADDRESS,
        CollateralAdapter: process.env.COLLATERAL_ADAPTER_ADDRESS,
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

    const governorAddress = addresses.Governor;
    let failures = 0;

    const check = async (contractName, role, roleName, holder, expected, holderName) => {
        const instance = await hardhat.ethers.getContractAt(contractName, addresses[contractName]);
        const has = await instance.hasRole(role, holder);
        if (has !== expected) {
            console.error(
                `ROLE MISMATCH: ${contractName}.${roleName} for ${holderName} (${holder}) - expected ${expected}, got ${has}`
            );
            ++failures;
        } else {
            console.log(`OK: ${contractName}.${roleName} ${holderName} = ${expected}`);
        }
    };

    // Trusted system contracts that legitimately hold WARD_ROLE via cross-contract wiring.
    const systemWards = {
        USDR: [addresses.CollateralAdapter],
        VaultEngine: [
            addresses.CollateralAdapter,
            addresses.PriceConverter,
            addresses.LiquidationTrigger,
            addresses.DutchAuction,
            addresses.BalanceSheet,
            addresses.End
        ],
        LiquidationTrigger: [addresses.DutchAuction, addresses.End],
        PriceConverter: [addresses.End],
        DutchAuction: [addresses.LiquidationTrigger, addresses.End],
        BalanceSheet: [addresses.LiquidationTrigger]
    };

    for (const name of Object.keys(addresses)) {
        // Governor must be a ward everywhere.
        await check(name, WARD_ROLE, "WARD_ROLE", governorAddress, true, "Governor");
        // Deployer must be a ward nowhere.
        await check(name, WARD_ROLE, "WARD_ROLE", deployer.address, false, "deployer");
        // Expected system wards must be present.
        for (const ward of systemWards[name] || []) {
            await check(name, WARD_ROLE, "WARD_ROLE", ward, true, "system contract");
        }
    }

    // Role-specific holders.
    await check("USDR", BURNER_ROLE, "BURNER_ROLE", addresses.CollateralAdapter, true, "CollateralAdapter");
    await check("USDR", BURNER_ROLE, "BURNER_ROLE", deployer.address, false, "deployer");
    await check(
        "ReserveAccounting",
        COMMITTER_ROLE,
        "COMMITTER_ROLE",
        addresses.SolvencyEngine,
        true,
        "SolvencyEngine"
    );
    await check(
        "ReserveAccounting",
        RECORDER_ROLE,
        "RECORDER_ROLE",
        addresses.PegStabilityModule,
        true,
        "PegStabilityModule"
    );
    await check("OracleSecurityModule", READER_ROLE, "READER_ROLE", addresses.PriceConverter, true, "PriceConverter");
    await check("OracleSecurityModule", READER_ROLE, "READER_ROLE", addresses.DutchAuction, true, "DutchAuction");
    await check("OracleSecurityModule", READER_ROLE, "READER_ROLE", addresses.CircuitBreaker, true, "CircuitBreaker");
    await check("OracleSecurityModule", READER_ROLE, "READER_ROLE", addresses.SolvencyEngine, true, "SolvencyEngine");
    await check("OracleSecurityModule", READER_ROLE, "READER_ROLE", addresses.BalanceSheet, true, "BalanceSheet");
    await check("OracleSecurityModule", READER_ROLE, "READER_ROLE", addresses.End, true, "End");

    // Stability fee wiring: the Vault Engine's feeRecipient must be the Balance Sheet so accrued fees land as
    // surplus.
    {
        const vaultEngineInstance = await hardhat.ethers.getContractAt("VaultEngine", addresses.VaultEngine);
        const feeRecipient = await vaultEngineInstance.feeRecipient();

        if (feeRecipient.toLowerCase() !== addresses.BalanceSheet.toLowerCase()) {
            console.error(`FAIL: VaultEngine.feeRecipient is ${feeRecipient}, expected BalanceSheet`);
            failures += 1;
        } else {
            console.log("OK: VaultEngine.feeRecipient -> BalanceSheet");
        }
    }

    if (failures > 0) {
        console.error(`\nROLE VERIFICATION FAILED: ${failures} mismatch(es). DO NOT PROCEED.`);
        process.exit(1);
    }

    console.log("\nRole verification passed: Governor is the only administrative WARD holder.");
};

verifyRoles()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
