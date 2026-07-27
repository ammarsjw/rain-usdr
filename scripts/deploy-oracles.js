const hardhat = require("hardhat");

const { configure } = require("./helpers/config/config");
const { verifyContract } = require("./helpers/libraries/auxiliary");
const { deployContract } = require("./helpers/libraries/workflows");
const { LOG_TYPE } = require("./helpers/shared/types");
const { updateEnv } = require("./helpers/utils/env");
const { logTag, wait } = require("./helpers/utils/tools");

const deployOracles = async () => {
    // Configuring.
    const feeDataLogType = LOG_TYPE.PRIMARY_QUIET;
    await configure({ feeDataLogType: feeDataLogType });

    // Definition variables.
    const osmName = "OracleSecurityModule";
    const priceConverterName = "PriceConverter";

    // Deployment variables.
    const vaultEngineAddress = process.env.VAULT_ENGINE_ADDRESS;
    const rainPriceSourceAddress = process.env.RAIN_PRICE_SOURCE_ADDRESS;
    const usdtPriceSourceAddress = process.env.USDT_PRICE_SOURCE_ADDRESS;
    const usdcPriceSourceAddress = process.env.USDC_PRICE_SOURCE_ADDRESS;

    // Collateral type identifiers.
    const rainIlk = hardhat.ethers.encodeBytes32String("RAIN-A");
    const usdtIlk = hardhat.ethers.encodeBytes32String("USDT-A");
    const usdcIlk = hardhat.ethers.encodeBytes32String("USDC-A");

    // Logging tag.
    logTag("Oracles");

    // Deploying the Oracle Security Module (a single instance serving every priced collateral).
    const osmConstructorArguments = [];
    const osmAddress = await deployContract(osmName, osmConstructorArguments);

    // Deploying the Price Converter.
    const priceConverterConstructorArguments = [vaultEngineAddress];
    const priceConverterAddress = await deployContract(priceConverterName, priceConverterConstructorArguments);

    // Setting up the oracles.
    const osmInstance = await hardhat.ethers.getContractAt(osmName, osmAddress);
    const priceConverterInstance = await hardhat.ethers.getContractAt(priceConverterName, priceConverterAddress);
    const vaultEngineInstance = await hardhat.ethers.getContractAt("VaultEngine", vaultEngineAddress);

    // Registering each collateral's price source (Uniswap TWAP wrapper or Chainlink wrapper —
    // any IPriceSource adapter).
    await (await osmInstance.change(rainIlk, rainPriceSourceAddress)).wait();
    await (await osmInstance.change(usdtIlk, usdtPriceSourceAddress)).wait();
    await (await osmInstance.change(usdcIlk, usdcPriceSourceAddress)).wait();

    // Whitelisting the Price Converter to read the OSM.
    await (await osmInstance.kiss(priceConverterAddress)).wait();

    // Assigning oracles and collateralization ratios (RAIN 400%, USDT/USDC 100%).
    const RAY = 10n ** 27n;
    await (await priceConverterInstance["file(bytes32,bytes32,address)"](rainIlk, hardhat.ethers.encodeBytes32String("pip"), osmAddress)).wait();
    await (await priceConverterInstance["file(bytes32,bytes32,address)"](usdtIlk, hardhat.ethers.encodeBytes32String("pip"), osmAddress)).wait();
    await (await priceConverterInstance["file(bytes32,bytes32,address)"](usdcIlk, hardhat.ethers.encodeBytes32String("pip"), osmAddress)).wait();
    await (await priceConverterInstance["file(bytes32,bytes32,uint256)"](rainIlk, hardhat.ethers.encodeBytes32String("mat"), RAY * 4n)).wait();
    await (await priceConverterInstance["file(bytes32,bytes32,uint256)"](usdtIlk, hardhat.ethers.encodeBytes32String("mat"), RAY)).wait();
    await (await priceConverterInstance["file(bytes32,bytes32,uint256)"](usdcIlk, hardhat.ethers.encodeBytes32String("mat"), RAY)).wait();

    // Authorizing the Price Converter to push price factors into the ledger.
    await (await vaultEngineInstance.rely(priceConverterAddress)).wait();
    console.log("Oracles setup complete");

    // Updating env.
    updateEnv("OSM_ADDRESS", osmAddress);
    updateEnv("PRICE_CONVERTER_ADDRESS", priceConverterAddress);

    // Waiting for block explorer.
    await wait("60 seconds");

    // Verifying oracle contracts.
    await verifyContract(osmAddress, osmConstructorArguments);
    await verifyContract(priceConverterAddress, priceConverterConstructorArguments);
};

deployOracles()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
