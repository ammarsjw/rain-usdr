const LOG_TYPE = Object.freeze({
    /**
     * All logging disabled.
     * @type {string}
     * @description Suppresses all log output from both primary function logic and secondary function calls.
     * @example fun(data, LOG_TYPE.QUIET)
     */
    QUIET: "0",

    /**
     * Primary logging disabled, secondary logging enabled.
     * @type {string}
     * @description Suppresses log output from primary function logic while preserving secondary function logs.
     * @example fun(data, LOG_TYPE.PRIMARY_QUIET)
     */
    PRIMARY_QUIET: "1",

    /**
     * Secondary logging disabled, primary logging enabled.
     * @type {string}
     * @description Suppresses log output from secondary function calls while preserving primary function logs.
     * @example fun(data, LOG_TYPE.SECONDARY_QUIET)
     */
    SECONDARY_QUIET: "2",

    /**
     * All logging enabled.
     * @type {string}
     * @description Enables verbose log output from both primary function logic and secondary function calls.
     * @example fun(data, LOG_TYPE.VERBOSE)
     */
    VERBOSE: "3"
});

const TX_TYPE = Object.freeze({
    /**
     * Legacy transaction type (pre-EIP-1559).
     * @type {string}
     * @description Type 0 transactions use the traditional gasPrice mechanism.
     * @see {@link https://ethereum.org/en/developers/docs/transactions/|Ethereum Transaction Documentation}
     */
    TYPE0: "0",

    /**
     * EIP-1559 transaction type.
     * @type {string}
     * @description Type 2 transactions support dynamic fee structure with maxFeePerGas and maxPriorityFeePerGas.
     * @see {@link https://eips.ethereum.org/EIPS/eip-1559|EIP-1559 Specification}
     */
    TYPE2: "2"
});

module.exports = {
    LOG_TYPE,
    TX_TYPE
};
