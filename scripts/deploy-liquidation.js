const hardhat = require("hardhat");

const { configure } = require("./helpers/config/config");
const { verifyContract } = require("./helpers/libraries/auxiliary");
const { deployContract } = require("./helpers/libraries/workflows");
const { LOG_TYPE } = require("./helpers/shared/types");
const { updateEnv } = require("./helpers/utils/env");
const { logTag, wait } = require("./helpers/utils/tools");

const deployLiquidation = async () => {
    // Configuring.
    const feeDataLogType = LOG_TYPE.PRIMARY_QUIET;
    await configure({ feeDataLogType: feeDataLogType });

    // Definition variables.
    const priceCurveName = "PriceCurve";
    const liquidationTriggerName = "LiquidationTrigger";
    const dutchAuctionName = "DutchAuction";
    const circuitBreakerName = "CircuitBreaker";

    // Deployment variables.
    const vaultEngineAddress = process.env.VAULT_ENGINE_ADDRESS;
    const balanceSheetAddress = process.env.BALANCE_SHEET_ADDRESS;
    const osmAddress = process.env.OSM_ADDRESS;

    // Collateral type identifiers.
    const rainIlk = hardhat.ethers.encodeBytes32String("RAIN-A");

    // Fixed point scalars.
    const WAD = 10n ** 18n;
    const RAY = 10n ** 27n;
    const RAD = 10n ** 45n;

    // Logging tag.
    logTag("Liquidation");

    // Deploying the liquidation stack.
    const priceCurveConstructorArguments = [];
    const priceCurveAddress = await deployContract(priceCurveName, priceCurveConstructorArguments);

    const liquidationTriggerConstructorArguments = [vaultEngineAddress];
    const liquidationTriggerAddress = await deployContract(
        liquidationTriggerName,
        liquidationTriggerConstructorArguments
    );

    const dutchAuctionConstructorArguments = [vaultEngineAddress, rainIlk];
    const dutchAuctionAddress = await deployContract(dutchAuctionName, dutchAuctionConstructorArguments);

    const circuitBreakerConstructorArguments = [osmAddress, rainIlk];
    const circuitBreakerAddress = await deployContract(circuitBreakerName, circuitBreakerConstructorArguments);

    // Setting up the liquidation stack.
    const priceCurveInstance = await hardhat.ethers.getContractAt(priceCurveName, priceCurveAddress);
    const liquidationTriggerInstance = await hardhat.ethers.getContractAt(
        liquidationTriggerName,
        liquidationTriggerAddress
    );
    const dutchAuctionInstance = await hardhat.ethers.getContractAt(dutchAuctionName, dutchAuctionAddress);
    const vaultEngineInstance = await hardhat.ethers.getContractAt("VaultEngine", vaultEngineAddress);

    // Price curve: auction lifetime of 1 hour (straight-line decline to zero).
    await (await priceCurveInstance.file(hardhat.ethers.encodeBytes32String("tau"), 3600n)).wait();

    // Liquidation trigger: global cap $100,000, RAIN cap $50,000, penalty 13%.
    await (
        await liquidationTriggerInstance["file(bytes32,uint256)"](
            hardhat.ethers.encodeBytes32String("Hole"),
            100000n * RAD
        )
    ).wait();
    await (
        await liquidationTriggerInstance["file(bytes32,address)"](
            hardhat.ethers.encodeBytes32String("balanceSheet"),
            balanceSheetAddress
        )
    ).wait();
    await (
        await liquidationTriggerInstance["file(bytes32,address)"](
            hardhat.ethers.encodeBytes32String("circuitBreaker"),
            circuitBreakerAddress
        )
    ).wait();
    await (
        await liquidationTriggerInstance["file(bytes32,bytes32,uint256)"](
            rainIlk,
            hardhat.ethers.encodeBytes32String("chop"),
            (WAD * 113n) / 100n
        )
    ).wait();
    await (
        await liquidationTriggerInstance["file(bytes32,bytes32,uint256)"](
            rainIlk,
            hardhat.ethers.encodeBytes32String("hole"),
            50000n * RAD
        )
    ).wait();
    await (
        await liquidationTriggerInstance["file(bytes32,bytes32,address)"](
            rainIlk,
            hardhat.ethers.encodeBytes32String("clip"),
            dutchAuctionAddress
        )
    ).wait();

    // Dutch auction: 5% start markup, 30 minute reset time, 40% reset threshold, 2% keeper reward.
    await (
        await dutchAuctionInstance["file(bytes32,uint256)"](
            hardhat.ethers.encodeBytes32String("buf"),
            (RAY * 105n) / 100n
        )
    ).wait();
    await (
        await dutchAuctionInstance["file(bytes32,uint256)"](hardhat.ethers.encodeBytes32String("tail"), 1800n)
    ).wait();
    await (
        await dutchAuctionInstance["file(bytes32,uint256)"](
            hardhat.ethers.encodeBytes32String("cusp"),
            (RAY * 40n) / 100n
        )
    ).wait();
    await (
        await dutchAuctionInstance["file(bytes32,uint256)"](
            hardhat.ethers.encodeBytes32String("chip"),
            (WAD * 2n) / 100n
        )
    ).wait();
    await (
        await dutchAuctionInstance["file(bytes32,address)"](hardhat.ethers.encodeBytes32String("pip"), osmAddress)
    ).wait();
    await (
        await dutchAuctionInstance["file(bytes32,address)"](
            hardhat.ethers.encodeBytes32String("dog"),
            liquidationTriggerAddress
        )
    ).wait();
    await (
        await dutchAuctionInstance["file(bytes32,address)"](
            hardhat.ethers.encodeBytes32String("vow"),
            balanceSheetAddress
        )
    ).wait();
    await (
        await dutchAuctionInstance["file(bytes32,address)"](
            hardhat.ethers.encodeBytes32String("calc"),
            priceCurveAddress
        )
    ).wait();

    // Whitelisting the auction and the breaker to read the OSM.
    const osmInstance = await hardhat.ethers.getContractAt("OracleSecurityModule", osmAddress);
    await (await osmInstance.kiss(dutchAuctionAddress)).wait();
    await (await osmInstance.kiss(circuitBreakerAddress)).wait();

    // Wiring authorizations across the ledger and the stack.
    await (await vaultEngineInstance.rely(liquidationTriggerAddress)).wait();
    await (await vaultEngineInstance.rely(dutchAuctionAddress)).wait();
    await (await liquidationTriggerInstance.rely(dutchAuctionAddress)).wait();
    await (await dutchAuctionInstance.rely(liquidationTriggerAddress)).wait();
    console.log("Liquidation setup complete");

    // Updating env.
    updateEnv("PRICE_CURVE_ADDRESS", priceCurveAddress);
    updateEnv("LIQUIDATION_TRIGGER_ADDRESS", liquidationTriggerAddress);
    updateEnv("DUTCH_AUCTION_ADDRESS", dutchAuctionAddress);
    updateEnv("CIRCUIT_BREAKER_ADDRESS", circuitBreakerAddress);

    // Waiting for block explorer.
    await wait("30 seconds");

    // Verifying liquidation contracts.
    await verifyContract(priceCurveAddress, priceCurveConstructorArguments);
    await verifyContract(liquidationTriggerAddress, liquidationTriggerConstructorArguments);
    await verifyContract(dutchAuctionAddress, dutchAuctionConstructorArguments);
    await verifyContract(circuitBreakerAddress, circuitBreakerConstructorArguments);
};

deployLiquidation()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
