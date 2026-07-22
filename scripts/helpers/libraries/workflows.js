const { CONFIG_STATE } = require("../shared/states");
const { LOG_TYPE } = require("../shared/types");
const { getFeeData } = require("../utils/fee");

const { deployContractAction } = require("./actions");
const { estimateContractDeploymentGas } = require("./auxiliary");

const deployContract = async (contractName, constructorArguments) => {
    // Getting gas limit.
    const gasLimit = await estimateContractDeploymentGas(contractName, constructorArguments);

    // Getting fee data.
    const feeDataLogType = LOG_TYPE.QUIET;
    const feeData = await getFeeData({ feeDataLogType: feeDataLogType });

    // Calling deploy contract action.
    const contractAddress = await deployContractAction(contractName, constructorArguments, {
        type: CONFIG_STATE.txType,
        gasLimit: gasLimit,
        ...feeData
    });

    return contractAddress;
};

module.exports = {
    deployContract
};
