require("@nomicfoundation/hardhat-toolbox");
require("@nomicfoundation/hardhat-foundry");
require("hardhat-contract-sizer");
require("hardhat-storage-layout");
require("dotenv").config();

const URL_PRODUCTION = process.env.URL_PRODUCTION || "";
const URL_STAGING = process.env.URL_STAGING || "";
const PRIVATE_KEY_PRODUCTION = process.env.PRIVATE_KEY_PRODUCTION || "";
const PRIVATE_KEY_STAGING = process.env.PRIVATE_KEY_STAGING || "";
const ETHERSCAN_API_KEY = process.env.ETHERSCAN_API_KEY || "";

/**
 * @type {import("hardhat/config").HardhatUserConfig}
 */
module.exports = {
    solidity: {
        version: "0.8.30",
        settings: {
            optimizer: {
                enabled: true,
                runs: 1000000
            },
            evmVersion: "cancun",
            viaIR: true
        }
    },
    networks: {
        hardhat: {
            allowUnlimitedContractSize: false
        },
        production: {
            url: URL_PRODUCTION,
            accounts: PRIVATE_KEY_PRODUCTION ? [PRIVATE_KEY_PRODUCTION] : []
        },
        staging: {
            url: URL_STAGING,
            accounts: PRIVATE_KEY_STAGING ? [PRIVATE_KEY_STAGING] : []
        }
    },
    etherscan: {
        apiKey: ETHERSCAN_API_KEY
    },
    contractSizer: {
        alphaSort: true,
        runOnCompile: false,
        strict: false
    },
    paths: {
        sources: "contracts",
        tests: "tests",
        cache: "cache",
        artifacts: "artifacts"
    }
};
