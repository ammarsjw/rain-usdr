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

    // Registering RAIN's price source (Uniswap TWAP wrapper — any IPriceSource adapter works,
    // e.g. a Chainlink wrapper for future volatile collaterals like ETH or WBTC). Supported
    // stablecoins are never registered on the OSM: they are marked fixed on the Price
    // Converter and always convert at $1.
    await (await osmInstance.change(rainIlk, rainPriceSourceAddress)).wait();

    // Whitelisting the Price Converter to read the OSM.
    await (await osmInstance.kiss(priceConverterAddress)).wait();

    // Configuring RAIN as oracle-backed (400%) and the stablecoins as fixed $1 (100%).
    const RAY = 10n ** 27n;
    await (await priceConverterInstance["file(bytes32,bytes32,address)"](rainIlk, hardhat.ethers.encodeBytes32String("pip"), osmAddress)).wait();
    await (await priceConverterInstance["file(bytes32,bytes32,uint256)"](rainIlk, hardhat.ethers.encodeBytes32String("mat"), RAY * 4n)).wait();
    await (await priceConverterInstance["file(bytes32,bytes32,uint256)"](usdtIlk, hardhat.ethers.encodeBytes32String("mat"), RAY)).wait();
    await (await priceConverterInstance["file(bytes32,bytes32,uint256)"](usdcIlk, hardhat.ethers.encodeBytes32String("mat"), RAY)).wait();
    await (await priceConverterInstance["file(bytes32,bytes32,uint256)"](usdtIlk, hardhat.ethers.encodeBytes32String("fixed"), 1n)).wait();
    await (await priceConverterInstance["file(bytes32,bytes32,uint256)"](usdcIlk, hardhat.ethers.encodeBytes32String("fixed"), 1n)).wait();

    // Authorizing the Price Converter to push price factors into the ledger.
    await (await vaultEngineInstance.rely(priceConverterAddress)).wait();

    // Setting the stablecoins' price factors once; fixed ilks never need another poke unless
    // par or mat changes.
    await (await priceConverterInstance.poke(usdtIlk)).wait();
    await (await priceConverterInstance.poke(usdcIlk)).wait();
    console.log("Oracles setup complete");

    // Updating env.
    updateEnv("OSM_ADDRESS", osmAddress);
    updateEnv("PRICE_CONVERTER_ADDRESS", priceConverterAddress);

    // Waiting for block explorer.
    await wait("30 seconds");

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
