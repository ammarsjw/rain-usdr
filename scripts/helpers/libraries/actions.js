/**
 * @type {import("hardhat/types").HardhatRuntimeEnvironment}
 */
const hardhat = require("hardhat");

const deployContractAction = async (contractName, constructorArguments, contractOptions) => {
    // Deploying contract.
    const contract = await hardhat.ethers.deployContract(contractName, constructorArguments, contractOptions);
    await contract.waitForDeployment();

    // Getting contract deployment variables.
    const contractAddress = contract.target;
    const deploymentTransactionHash = contract.deploymentTransaction().hash;
    const deploymentTransaction = await hardhat.ethers.provider.getTransactionReceipt(deploymentTransactionHash);
    const deploymentBlockNumber = deploymentTransaction.blockNumber;

    // Logging contract deployment variables.
    console.log(contractName, "deployed to:", contractAddress);
    console.log("at block number:", deploymentBlockNumber);

    return contractAddress;
};

module.exports = {
    deployContractAction
};
