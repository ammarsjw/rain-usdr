const hardhat = require("hardhat");

const { configure } = require("./helpers/config/config");
const { verifyContract } = require("./helpers/libraries/auxiliary");
const { deployContract } = require("./helpers/libraries/workflows");
const { READER_ROLE, WARD_ROLE } = require("./helpers/shared/constants");
const { LOG_TYPE } = require("./helpers/shared/types");
const { updateEnv } = require("./helpers/utils/env");
const { logTag, wait } = require("./helpers/utils/tools");

const deployGovernance = async () => {
    // Configuring.
    const feeDataLogType = LOG_TYPE.PRIMARY_QUIET;
    await configure({ feeDataLogType: feeDataLogType });

    // Definition variables.
    const governorName = "Governor";
    const endName = "End";

    // Deployment variables.
    const governorDelay = process.env.GOVERNOR_DELAY || 172800n; // 48 hours default.
    const endWait = process.env.END_WAIT || 604800n; // 7 days default.
    const governorHandover = process.env.GOVERNOR_HANDOVER === "true" || false; // false default.
    const vaultEngineAddress = process.env.VAULT_ENGINE_ADDRESS;
    const usdrAddress = process.env.USDR_ADDRESS;
    const collateralAdapterAddress = process.env.COLLATERAL_ADAPTER_ADDRESS;
    const osmAddress = process.env.OSM_ADDRESS;
    const priceConverterAddress = process.env.PRICE_CONVERTER_ADDRESS;
    const reserveAccountingAddress = process.env.RESERVE_ACCOUNTING_ADDRESS;
    const solvencyEngineAddress = process.env.SOLVENCY_ENGINE_ADDRESS;
    const balanceSheetAddress = process.env.BALANCE_SHEET_ADDRESS;
    const psmAddress = process.env.PSM_ADDRESS;
    const priceCurveAddress = process.env.PRICE_CURVE_ADDRESS;
    const liquidationTriggerAddress = process.env.LIQUIDATION_TRIGGER_ADDRESS;
    const dutchAuctionAddress = process.env.DUTCH_AUCTION_ADDRESS;
    const circuitBreakerAddress = process.env.CIRCUIT_BREAKER_ADDRESS;

    // Collateral type identifiers.
    const rainIlk = hardhat.ethers.encodeBytes32String("RAIN-A");
    const usdtIlk = hardhat.ethers.encodeBytes32String("USDT-A");
    const usdcIlk = hardhat.ethers.encodeBytes32String("USDC-A");

    // Fixed point scalars.
    const RAD = 10n ** 45n;

    // Logging tag.
    logTag("Governance");

    // Deploying the Governor.
    const governorConstructorArguments = [governorDelay];
    const governorAddress = await deployContract(governorName, governorConstructorArguments);

    // Deploying the End (emergency settlement).
    const endConstructorArguments = [vaultEngineAddress];
    const endAddress = await deployContract(endName, endConstructorArguments);

    // Wiring the End's dependencies and settlement cooldown (must exceed the Balance Sheet's sin queue wait so
    // thaw can heal all queued sin first).
    const endInstance = await hardhat.ethers.getContractAt(endName, endAddress);
    await (
        await endInstance["file(bytes32,address)"](
            hardhat.ethers.encodeBytes32String("liquidationTrigger"),
            liquidationTriggerAddress
        )
    ).wait();
    await (
        await endInstance["file(bytes32,address)"](
            hardhat.ethers.encodeBytes32String("balanceSheet"),
            balanceSheetAddress
        )
    ).wait();
    await (
        await endInstance["file(bytes32,address)"](
            hardhat.ethers.encodeBytes32String("priceConverter"),
            priceConverterAddress
        )
    ).wait();
    await (await endInstance["file(bytes32,uint256)"](hardhat.ethers.encodeBytes32String("wait"), endWait)).wait();

    // Setting up governance wiring.
    const vaultEngineInstance = await hardhat.ethers.getContractAt("VaultEngine", vaultEngineAddress);

    // Setting launch risk parameters: ceilings and minimum vault size.
    await (
        await vaultEngineInstance["file(bytes32,uint256)"](
            hardhat.ethers.encodeBytes32String("globalLine"),
            1100000n * RAD
        )
    ).wait();
    await (
        await vaultEngineInstance["file(bytes32,bytes32,uint256)"](
            rainIlk,
            hardhat.ethers.encodeBytes32String("line"),
            100000n * RAD
        )
    ).wait();
    await (
        await vaultEngineInstance["file(bytes32,bytes32,uint256)"](
            usdtIlk,
            hardhat.ethers.encodeBytes32String("line"),
            500000n * RAD
        )
    ).wait();
    await (
        await vaultEngineInstance["file(bytes32,bytes32,uint256)"](
            usdcIlk,
            hardhat.ethers.encodeBytes32String("line"),
            500000n * RAD
        )
    ).wait();
    await (
        await vaultEngineInstance["file(bytes32,bytes32,uint256)"](
            rainIlk,
            hardhat.ethers.encodeBytes32String("dust"),
            100n * RAD
        )
    ).wait();

    // Refreshing the auction's dust-times-chop cache now that dust is final.
    const dutchAuctionInstance = await hardhat.ethers.getContractAt("DutchAuction", dutchAuctionAddress);
    await (await dutchAuctionInstance.upchost()).wait();

    // Wiring the Governor's emergency pause into the gated entry points.
    const governorWhat = hardhat.ethers.encodeBytes32String("governor");
    const psmInstance = await hardhat.ethers.getContractAt("PegStabilityModule", psmAddress);
    const liquidationTriggerInstance = await hardhat.ethers.getContractAt(
        "LiquidationTrigger",
        liquidationTriggerAddress
    );
    await (await vaultEngineInstance["file(bytes32,address)"](governorWhat, governorAddress)).wait();
    await (await psmInstance["file(bytes32,address)"](governorWhat, governorAddress)).wait();
    await (await liquidationTriggerInstance["file(bytes32,address)"](governorWhat, governorAddress)).wait();
    await (await dutchAuctionInstance["file(bytes32,address)"](governorWhat, governorAddress)).wait();

    // Granting the End authority over the contracts its settlement path drives:
    // - VaultEngine: cage, grab, suck, and post-cage heal
    // - LiquidationTrigger: cage
    // - PriceConverter: cage
    // - DutchAuction: cage and yank (skip reclaims in-flight auctions)
    // - OSM READER_ROLE: cage(ilkId) reads the last delayed price
    const priceConverterInstance = await hardhat.ethers.getContractAt("PriceConverter", priceConverterAddress);
    const osmInstance = await hardhat.ethers.getContractAt("OracleSecurityModule", osmAddress);
    await (await vaultEngineInstance.grantRole(WARD_ROLE, endAddress)).wait();
    await (await liquidationTriggerInstance.grantRole(WARD_ROLE, endAddress)).wait();
    await (await priceConverterInstance.grantRole(WARD_ROLE, endAddress)).wait();
    await (await dutchAuctionInstance.grantRole(WARD_ROLE, endAddress)).wait();
    await (await osmInstance.grantRole(READER_ROLE, endAddress)).wait();

    if (governorHandover) {
        // Handing full control of EVERY deployed contract to the Governor and renouncing the deployer's WARD role.
        // Ordering matters: renounce only after all cross-contract wiring and file calls are complete (this script runs
        // last in the deploy sequence).
        const [deployer] = await hardhat.ethers.getSigners();
        const wardedContracts = [
            ["USDR", usdrAddress],
            ["VaultEngine", vaultEngineAddress],
            ["CollateralAdapter", collateralAdapterAddress],
            ["OracleSecurityModule", osmAddress],
            ["PriceConverter", priceConverterAddress],
            ["ReserveAccounting", reserveAccountingAddress],
            ["SolvencyEngine", solvencyEngineAddress],
            ["BalanceSheet", balanceSheetAddress],
            ["PegStabilityModule", psmAddress],
            ["PriceCurve", priceCurveAddress],
            ["LiquidationTrigger", liquidationTriggerAddress],
            ["DutchAuction", dutchAuctionAddress],
            ["CircuitBreaker", circuitBreakerAddress],
            ["Governor", governorAddress],
            ["End", endAddress]
        ];

        for (const [name, address] of wardedContracts) {
            const instance = await hardhat.ethers.getContractAt(name, address);
            await (await instance.grantRole(WARD_ROLE, governorAddress)).wait();
            await (await instance.renounceRole(WARD_ROLE, deployer.address)).wait();
            console.log(`WARD_ROLE: ${name} handed to Governor, deployer renounced`);
        }
    }

    console.log("Governance setup complete");

    // Updating env.
    updateEnv("GOVERNOR_ADDRESS", governorAddress);
    updateEnv("END_ADDRESS", endAddress);

    // Waiting for block explorer.
    await wait("30 seconds");

    // Verifying governance contracts.
    await verifyContract(governorAddress, governorConstructorArguments);
    await verifyContract(endAddress, endConstructorArguments);
};

deployGovernance()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
