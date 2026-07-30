const hardhat = require("hardhat");

const { configure } = require("./helpers/config/config");
const { verifyContract } = require("./helpers/libraries/auxiliary");
const { deployContract } = require("./helpers/libraries/workflows");
const { WARD_ROLE } = require("./helpers/shared/constants");
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

    // Deploying the token adapter (a single instance serving USDR and every collateral).
    const collateralAdapterConstructorArguments = [vaultEngineAddress];
    const collateralAdapterAddress = await deployContract(collateralAdapterName, collateralAdapterConstructorArguments);

    // Setting up the core.
    const vaultEngineInstance = await hardhat.ethers.getContractAt(vaultEngineName, vaultEngineAddress);
    const usdrInstance = await hardhat.ethers.getContractAt(usdrName, usdrAddress);
    const collateralAdapterInstance = await hardhat.ethers.getContractAt(
        collateralAdapterName,
        collateralAdapterAddress
    );

    // Registering collateral types on the ledger.
    await (await vaultEngineInstance.init(rainIlk)).wait();
    await (await vaultEngineInstance.init(usdtIlk)).wait();
    await (await vaultEngineInstance.init(usdcIlk)).wait();

    // Registering the USDR ilk and the collateral ilks on the adapter.
    const usdrIlk = hardhat.ethers.encodeBytes32String("USDR");
    await (await collateralAdapterInstance.init(usdrIlk, usdrAddress)).wait();
    await (await collateralAdapterInstance.init(rainIlk, rainAddress)).wait();
    await (await collateralAdapterInstance.init(usdtIlk, usdtAddress)).wait();
    await (await collateralAdapterInstance.init(usdcIlk, usdcAddress)).wait();

    // Authorizing the adapter on the ledger and as a token minter.
    await (await vaultEngineInstance.grantRole(WARD_ROLE, collateralAdapterAddress)).wait();
    await (await usdrInstance.grantRole(WARD_ROLE, collateralAdapterAddress)).wait();
    console.log("Core setup complete");

    // Updating env.
    updateEnv("USDR_ADDRESS", usdrAddress);
    updateEnv("VAULT_ENGINE_ADDRESS", vaultEngineAddress);
    updateEnv("COLLATERAL_ADAPTER_ADDRESS", collateralAdapterAddress);

    // Waiting for block explorer.
    await wait("30 seconds");

    // Verifying core contracts.
    await verifyContract(usdrAddress, usdrConstructorArguments);
    await verifyContract(vaultEngineAddress, vaultEngineConstructorArguments);
    await verifyContract(collateralAdapterAddress, collateralAdapterConstructorArguments);
};

deployCore()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
