const hardhat = require("hardhat");

const { configure } = require("./helpers/config/config");
const { verifyContract } = require("./helpers/libraries/auxiliary");
const { deployContract } = require("./helpers/libraries/workflows");
const { LOG_TYPE } = require("./helpers/shared/types");
const { updateEnv } = require("./helpers/utils/env");
const { logTag, wait } = require("./helpers/utils/tools");

const deployGovernance = async () => {
    // Configuring.
    const feeDataLogType = LOG_TYPE.PRIMARY_QUIET;
    await configure({ feeDataLogType: feeDataLogType });

    // Definition variables.
    const governorName = "Governor";

    // Deployment variables.
    const governorDelay = process.env.GOVERNOR_DELAY || 172800n; // 48 hours default.
    const vaultEngineAddress = process.env.VAULT_ENGINE_ADDRESS;

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

    // Setting up governance wiring.
    const vaultEngineInstance = await hardhat.ethers.getContractAt("VaultEngine", vaultEngineAddress);

    // Setting launch risk parameters: ceilings and minimum vault size.
    await (
        await vaultEngineInstance["file(bytes32,uint256)"](
            hardhat.ethers.encodeBytes32String("Line"),
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

    // Handing risk parameter control to the Governor (timelocked changes only).
    await (await vaultEngineInstance.rely(governorAddress)).wait();
    console.log("Governance setup complete");

    // Updating env.
    updateEnv("GOVERNOR_ADDRESS", governorAddress);

    // Waiting for block explorer.
    await wait("30 seconds");

    // Verifying governance contracts.
    await verifyContract(governorAddress, governorConstructorArguments);
};

deployGovernance()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
