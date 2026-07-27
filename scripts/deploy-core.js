const hardhat = require("hardhat");

const { configure } = require("./helpers/config/config");
const { verifyContract } = require("./helpers/libraries/auxiliary");
const { deployContract } = require("./helpers/libraries/workflows");
const { CONFIG_STATE } = require("./helpers/shared/states");
const { LOG_TYPE } = require("./helpers/shared/types");
const { updateEnv } = require("./helpers/utils/env");
const { logTag, wait } = require("./helpers/utils/tools");

const deployCore = async () => {
    // Configuring.
    const feeDataLogType = LOG_TYPE.PRIMARY_QUIET;
    await configure({ feeDataLogType: feeDataLogType });

    // Definition variables.
    const usdrName = "USDR";
    const vaultEngineName = "VaultEngine";
    const collateralAdapterName = "CollateralAdapter";

    // Deployment variables.
    let initialOwnerAddress = process.env.INITIAL_OWNER_ADDRESS;
    const rainAddress = process.env.RAIN_ADDRESS;
    const usdtAddress = process.env.USDT_ADDRESS;
    const usdcAddress = process.env.USDC_ADDRESS;

    // Collateral type identifiers.
    const rainIlk = hardhat.ethers.encodeBytes32String("RAIN-A");
    const usdtIlk = hardhat.ethers.encodeBytes32String("USDT-A");
    const usdcIlk = hardhat.ethers.encodeBytes32String("USDC-A");

    // Conditional variables.
    if (CONFIG_STATE.environment === "hardhat" || CONFIG_STATE.environment === "localhost") {
        const [deployer] = await hardhat.ethers.getSigners();
        initialOwnerAddress = deployer.address;
    }

    // Compiling constructor arguments.
    const usdrConstructorArguments = [];
    const vaultEngineConstructorArguments = [];

    // Logging tag.
    logTag("Core");

    // Deploying the token and the core ledger.
    const usdrAddress = await deployContract(usdrName, usdrConstructorArguments);
    const vaultEngineAddress = await deployContract(vaultEngineName, vaultEngineConstructorArguments);

    // Deploying the USDR adapter and the collateral adapters.
    const zeroIlk = hardhat.ethers.ZeroHash;
    const usdrAdapterConstructorArguments = [vaultEngineAddress, zeroIlk, usdrAddress, true];
    const usdrAdapterAddress = await deployContract(collateralAdapterName, usdrAdapterConstructorArguments);

    const rainAdapterConstructorArguments = [vaultEngineAddress, rainIlk, rainAddress, false];
    const rainAdapterAddress = await deployContract(collateralAdapterName, rainAdapterConstructorArguments);

    const usdtAdapterConstructorArguments = [vaultEngineAddress, usdtIlk, usdtAddress, false];
    const usdtAdapterAddress = await deployContract(collateralAdapterName, usdtAdapterConstructorArguments);

    const usdcAdapterConstructorArguments = [vaultEngineAddress, usdcIlk, usdcAddress, false];
    const usdcAdapterAddress = await deployContract(collateralAdapterName, usdcAdapterConstructorArguments);

    // Setting up the core.
    const vaultEngineInstance = await hardhat.ethers.getContractAt(vaultEngineName, vaultEngineAddress);
    const usdrInstance = await hardhat.ethers.getContractAt(usdrName, usdrAddress);

    // Registering collateral types.
    await (await vaultEngineInstance.init(rainIlk)).wait();
    await (await vaultEngineInstance.init(usdtIlk)).wait();
    await (await vaultEngineInstance.init(usdcIlk)).wait();

    // Authorizing the adapters on the ledger.
    await (await vaultEngineInstance.rely(usdrAdapterAddress)).wait();
    await (await vaultEngineInstance.rely(rainAdapterAddress)).wait();
    await (await vaultEngineInstance.rely(usdtAdapterAddress)).wait();
    await (await vaultEngineInstance.rely(usdcAdapterAddress)).wait();

    // Authorizing the USDR adapter as a token minter.
    await (await usdrInstance.rely(usdrAdapterAddress)).wait();
    console.log("Core setup complete");

    // Updating env.
    updateEnv("USDR_ADDRESS", usdrAddress);
    updateEnv("VAULT_ENGINE_ADDRESS", vaultEngineAddress);
    updateEnv("USDR_ADAPTER_ADDRESS", usdrAdapterAddress);
    updateEnv("RAIN_ADAPTER_ADDRESS", rainAdapterAddress);
    updateEnv("USDT_ADAPTER_ADDRESS", usdtAdapterAddress);
    updateEnv("USDC_ADAPTER_ADDRESS", usdcAdapterAddress);

    // Waiting for block explorer.
    await wait("60 seconds");

    // Verifying core contracts.
    await verifyContract(usdrAddress, usdrConstructorArguments);
    await verifyContract(vaultEngineAddress, vaultEngineConstructorArguments);
    await verifyContract(usdrAdapterAddress, usdrAdapterConstructorArguments);
    await verifyContract(rainAdapterAddress, rainAdapterConstructorArguments);
    await verifyContract(usdtAdapterAddress, usdtAdapterConstructorArguments);
    await verifyContract(usdcAdapterAddress, usdcAdapterConstructorArguments);
};

deployCore()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
