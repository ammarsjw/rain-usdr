const hardhat = require("hardhat");

const { BIGINT_HUNDRED } = require("../shared/constants");
const { CONFIG_STATE } = require("../shared/states");
const { LOG_TYPE, TX_TYPE } = require("../shared/types");

const { logNewline } = require("./tools");

const fetchAdjustedFeeData = async ({ gasPriceIncrementFactorOverride, feeDataLogType }) => {
    const seperatorQuiet = feeDataLogType !== LOG_TYPE.VERBOSE;
    const primaryQuiet = feeDataLogType === LOG_TYPE.QUIET || feeDataLogType === LOG_TYPE.PRIMARY_QUIET;
    const secondaryQuiet = feeDataLogType === LOG_TYPE.QUIET || feeDataLogType === LOG_TYPE.SECONDARY_QUIET;

    if (!seperatorQuiet) {
        logNewline();
    }

    let feeData;

    if (!secondaryQuiet) {
        // Forwarding without silencing logs.
        feeData = await fetchAdjustedFeeDataWithLogs(gasPriceIncrementFactorOverride);
    } else {
        // Saving console method.
        const log = console.log;

        // Overriding console method with no-op.
        console.log = () => {};

        try {
            // Forwarding with silenced logs.
            feeData = await fetchAdjustedFeeDataWithLogs(gasPriceIncrementFactorOverride);
        } finally {
            // Restoring console method.
            console.log = log;
        }
    }

    if (!primaryQuiet) {
        // Getting and logging gas price.
        const [firstValue] = Object.values(feeData);
        const logFirstValue = Number(hardhat.ethers.formatUnits(firstValue, "gwei"));
        console.log("Gas price:", logFirstValue, "gwei");
    }

    return feeData;
};

const fetchAdjustedFeeDataWithLogs = async (gasPriceIncrementFactorOverride) => {
    // Getting fee data.
    const feeData = await fetchFeeData();

    // Getting gas price increment factor.
    const gasPriceIncrementFactor = gasPriceIncrementFactorOverride || CONFIG_STATE.gasPriceIncrementFactor;

    // Getting gas price increment percentage.
    const gasPriceIncrementPercentage = hardhat.ethers.toBigInt(Math.round(gasPriceIncrementFactor * 100));

    // logging gas price increment factor.
    console.log("Gas price increment factor:", gasPriceIncrementFactor + "x");

    // Getting incremented gas price.
    const [firstKey] = Object.keys(feeData);
    feeData[firstKey] = (feeData[firstKey] * gasPriceIncrementPercentage) / BIGINT_HUNDRED;

    return feeData;
};

const fetchFeeData = async () => {
    // Getting gas price, max fee per gas and max priority fee per gas.
    const { gasPrice, maxFeePerGas, maxPriorityFeePerGas } = await hardhat.ethers.provider.getFeeData();

    const feeData = {};

    // Reading tx type from shared state.
    if (CONFIG_STATE.txType === TX_TYPE.TYPE0) {
        feeData.gasPrice = gasPrice;
    } else {
        feeData.maxFeePerGas = maxFeePerGas;
        feeData.maxPriorityFeePerGas = maxPriorityFeePerGas;
    }

    return feeData;
};

const fetchGasPrice = async () => {
    // Getting fee data.
    const feeData = await hardhat.ethers.provider.getFeeData();

    // Reading tx type from shared state.
    const gasPrice = CONFIG_STATE.txType === TX_TYPE.TYPE0 ? feeData.gasPrice : feeData.maxFeePerGas;

    return gasPrice;
};

const getFeeData = async ({ gasPriceIncrementFactorOverride, feeDataLogType }) => {
    // Getting and saving fee data to shared state.
    const feeData = await fetchAdjustedFeeData({
        gasPriceIncrementFactorOverride: gasPriceIncrementFactorOverride,
        feeDataLogType: feeDataLogType
    });
    CONFIG_STATE.feeData = feeData;

    return feeData;
};

module.exports = {
    fetchAdjustedFeeData,
    fetchFeeData,
    fetchGasPrice,
    getFeeData
};
