const hardhat = require("hardhat");

const { configure } = require("./helpers/config/config");
const { verifyContract } = require("./helpers/libraries/auxiliary");
const { deployContract } = require("./helpers/libraries/workflows");
const { COMMITTER_ROLE, RECORDER_ROLE, WARD_ROLE } = require("./helpers/shared/constants");
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
    const psmName = "PegStabilityModule";

    // Deployment variables.
    const vaultEngineAddress = process.env.VAULT_ENGINE_ADDRESS;
    const collateralAdapterAddress = process.env.COLLATERAL_ADAPTER_ADDRESS;

    // Collateral type identifiers.
    const rainIlk = hardhat.ethers.encodeBytes32String("RAIN-A");
    const usdtIlk = hardhat.ethers.encodeBytes32String("USDT-A");
    const usdcIlk = hardhat.ethers.encodeBytes32String("USDC-A");

    // Logging tag.
    logTag("Reserve");

    // Deploying the reserve stack.
    const reserveAccountingConstructorArguments = [];
    const reserveAccountingAddress = await deployContract(reserveAccountingName, reserveAccountingConstructorArguments);

    const solvencyEngineConstructorArguments = [vaultEngineAddress, reserveAccountingAddress];
    const solvencyEngineAddress = await deployContract(solvencyEngineName, solvencyEngineConstructorArguments);

    const balanceSheetConstructorArguments = [vaultEngineAddress];
    const balanceSheetAddress = await deployContract(balanceSheetName, balanceSheetConstructorArguments);

    // Deploying the Peg Stability Module.
    const psmConstructorArguments = [collateralAdapterAddress, reserveAccountingAddress];
    const psmAddress = await deployContract(psmName, psmConstructorArguments);

    // Setting up the reserve stack.
    const reserveAccountingInstance = await hardhat.ethers.getContractAt(
        reserveAccountingName,
        reserveAccountingAddress
    );
    const solvencyEngineInstance = await hardhat.ethers.getContractAt(solvencyEngineName, solvencyEngineAddress);
    const vaultEngineInstance = await hardhat.ethers.getContractAt("VaultEngine", vaultEngineAddress);

    // Allowing the Solvency Engine to commit escrow in Reserve Accounting.
    await (await reserveAccountingInstance.grantRole(COMMITTER_ROLE, solvencyEngineAddress)).wait();

    // Registering the stablecoin ilks on the PSM and authorizing it as a reserve recorder.
    const psmInstance = await hardhat.ethers.getContractAt(psmName, psmAddress);
    await (await psmInstance.init(usdtIlk)).wait();
    await (await psmInstance.init(usdcIlk)).wait();
    await (await reserveAccountingInstance.grantRole(RECORDER_ROLE, psmAddress)).wait();

    // Registering RAIN as a volatile collateral in the solvency stress calculation.
    await (await solvencyEngineInstance.addVolatileIlk(rainIlk)).wait();

    // Authorizing the Balance Sheet to heal and suck on the ledger.
    await (await vaultEngineInstance.grantRole(WARD_ROLE, balanceSheetAddress)).wait();
    console.log("Reserve setup complete");

    // Updating env.
    updateEnv("RESERVE_ACCOUNTING_ADDRESS", reserveAccountingAddress);
    updateEnv("SOLVENCY_ENGINE_ADDRESS", solvencyEngineAddress);
    updateEnv("BALANCE_SHEET_ADDRESS", balanceSheetAddress);
    updateEnv("PSM_ADDRESS", psmAddress);

    // Waiting for block explorer.
    await wait("30 seconds");

    // Verifying reserve contracts.
    await verifyContract(reserveAccountingAddress, reserveAccountingConstructorArguments);
    await verifyContract(solvencyEngineAddress, solvencyEngineConstructorArguments);
    await verifyContract(balanceSheetAddress, balanceSheetConstructorArguments);
    await verifyContract(psmAddress, psmConstructorArguments);
};

deployReserve()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
