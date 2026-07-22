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
    const usdrJoinName = "UsdrJoin";
    const collateralJoinName = "CollateralJoin";

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
    const usdrJoinConstructorArguments = [vaultEngineAddress, usdrAddress];
    const usdrJoinAddress = await deployContract(usdrJoinName, usdrJoinConstructorArguments);

    const rainJoinConstructorArguments = [vaultEngineAddress, rainIlk, rainAddress];
    const rainJoinAddress = await deployContract(collateralJoinName, rainJoinConstructorArguments);

    const usdtJoinConstructorArguments = [vaultEngineAddress, usdtIlk, usdtAddress];
    const usdtJoinAddress = await deployContract(collateralJoinName, usdtJoinConstructorArguments);

    const usdcJoinConstructorArguments = [vaultEngineAddress, usdcIlk, usdcAddress];
    const usdcJoinAddress = await deployContract(collateralJoinName, usdcJoinConstructorArguments);

    // Setting up the core.
    const vaultEngineInstance = await hardhat.ethers.getContractAt(vaultEngineName, vaultEngineAddress);
    const usdrInstance = await hardhat.ethers.getContractAt(usdrName, usdrAddress);

    // Registering collateral types.
    await (await vaultEngineInstance.init(rainIlk)).wait();
    await (await vaultEngineInstance.init(usdtIlk)).wait();
    await (await vaultEngineInstance.init(usdcIlk)).wait();

    // Authorizing the adapters on the ledger.
    await (await vaultEngineInstance.rely(usdrJoinAddress)).wait();
    await (await vaultEngineInstance.rely(rainJoinAddress)).wait();
    await (await vaultEngineInstance.rely(usdtJoinAddress)).wait();
    await (await vaultEngineInstance.rely(usdcJoinAddress)).wait();

    // Authorizing the USDR adapter as a token minter.
    await (await usdrInstance.rely(usdrJoinAddress)).wait();
    console.log("Core setup complete");

    // Updating env.
    updateEnv("USDR_ADDRESS", usdrAddress);
    updateEnv("VAULT_ENGINE_ADDRESS", vaultEngineAddress);
    updateEnv("USDR_JOIN_ADDRESS", usdrJoinAddress);
    updateEnv("RAIN_JOIN_ADDRESS", rainJoinAddress);
    updateEnv("USDT_JOIN_ADDRESS", usdtJoinAddress);
    updateEnv("USDC_JOIN_ADDRESS", usdcJoinAddress);

    // Waiting for block explorer.
    await wait("60 seconds");

    // Verifying core contracts.
    await verifyContract(usdrAddress, usdrConstructorArguments);
    await verifyContract(vaultEngineAddress, vaultEngineConstructorArguments);
    await verifyContract(usdrJoinAddress, usdrJoinConstructorArguments);
    await verifyContract(rainJoinAddress, rainJoinConstructorArguments);
    await verifyContract(usdtJoinAddress, usdtJoinConstructorArguments);
    await verifyContract(usdcJoinAddress, usdcJoinConstructorArguments);
};

deployCore()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
