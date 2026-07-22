const hardhat = require("hardhat");

const { configure } = require("./helpers/config/config");
const { verifyContract } = require("./helpers/libraries/auxiliary");
const { deployContract } = require("./helpers/libraries/workflows");
const { LOG_TYPE } = require("./helpers/shared/types");
const { updateEnv } = require("./helpers/utils/env");
const { logTag, wait } = require("./helpers/utils/tools");

const deployReserve = async () => {
    // Configuring.
    const feeDataLogType = LOG_TYPE.PRIMARY_QUIET;
    await configure({ feeDataLogType: feeDataLogType });

    // Definition variables.
    const reserveAccountingName = "ReserveAccounting";
    const solvencyEngineName = "SolvencyEngine";
    const balanceSheetName = "BalanceSheet";

    // Deployment variables.
    const vaultEngineAddress = process.env.VAULT_ENGINE_ADDRESS;

    // Collateral type identifiers.
    const rainIlk = hardhat.ethers.encodeBytes32String("RAIN-A");

    // Logging tag.
    logTag("Reserve");

    // Deploying the reserve stack.
    const reserveAccountingConstructorArguments = [];
    const reserveAccountingAddress = await deployContract(reserveAccountingName, reserveAccountingConstructorArguments);

    const solvencyEngineConstructorArguments = [vaultEngineAddress, reserveAccountingAddress];
    const solvencyEngineAddress = await deployContract(solvencyEngineName, solvencyEngineConstructorArguments);

    const balanceSheetConstructorArguments = [vaultEngineAddress];
    const balanceSheetAddress = await deployContract(balanceSheetName, balanceSheetConstructorArguments);

    // Setting up the reserve stack.
    const reserveAccountingInstance = await hardhat.ethers.getContractAt(
        reserveAccountingName,
        reserveAccountingAddress
    );
    const solvencyEngineInstance = await hardhat.ethers.getContractAt(solvencyEngineName, solvencyEngineAddress);
    const vaultEngineInstance = await hardhat.ethers.getContractAt("VaultEngine", vaultEngineAddress);

    // Allowing the Solvency Engine to commit escrow in Reserve Accounting.
    await (await reserveAccountingInstance.addCommitter(solvencyEngineAddress)).wait();

    // Registering RAIN as a volatile collateral in the solvency stress calculation.
    await (await solvencyEngineInstance.addVolatileIlk(rainIlk)).wait();

    // Authorizing the Balance Sheet to heal and suck on the ledger.
    await (await vaultEngineInstance.rely(balanceSheetAddress)).wait();
    console.log("Reserve setup complete");

    // Updating env.
    updateEnv("RESERVE_ACCOUNTING_ADDRESS", reserveAccountingAddress);
    updateEnv("SOLVENCY_ENGINE_ADDRESS", solvencyEngineAddress);
    updateEnv("BALANCE_SHEET_ADDRESS", balanceSheetAddress);

    // Waiting for block explorer.
    await wait("60 seconds");

    // Verifying reserve contracts.
    await verifyContract(reserveAccountingAddress, reserveAccountingConstructorArguments);
    await verifyContract(solvencyEngineAddress, solvencyEngineConstructorArguments);
    await verifyContract(balanceSheetAddress, balanceSheetConstructorArguments);
};

deployReserve()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
