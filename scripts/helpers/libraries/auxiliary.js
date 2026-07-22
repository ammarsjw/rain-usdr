const hardhat = require("hardhat");

const { logNewline } = require("../utils/tools");

const estimateContractDeploymentGas = async (contractName, constructorArguments, contractOptions) => {
    hardhat.ethers.getContractFactory(contractName, contractOptions);
    // Getting contract artifact.
    const contractArtifact = await hardhat.artifacts.readArtifact(contractName);

    // Getting contract interface and bytecode.
    const contractInterface = new hardhat.ethers.Interface(contractArtifact.abi);
    const bytecode = contractArtifact.bytecode;

    // Getting encoded constructor arguments.
    const encodedArgs = contractInterface.encodeDeploy(constructorArguments);

    // Getting contract deployment data.
    const deploymentData = bytecode + encodedArgs.slice(2);

    // Getting gas limit.
    const gasLimit = await hardhat.ethers.provider.estimateGas({ data: deploymentData, ...contractOptions });

    return gasLimit;
};

const verifyContract = async (contractAddress, constructorArguments, contractPath) => {
    // Separating logs.
    logNewline();

    // Logging contract verification variables.
    console.log("Verifying contract at:", contractAddress);
    console.log("with arguments:", constructorArguments.length > 0 ? constructorArguments : ["(none)"]);
    if (contractPath) console.log("at path:", contractPath);

    // Separating logs.
    logNewline();

    // Verifying contract.
    try {
        await hardhat.run("verify:verify", {
            address: contractAddress,
            constructorArguments: constructorArguments,
            contract: contractPath
        });
    } catch (error) {
        if (error.message.includes("Already Verified")) {
            console.log("Contract verified successfully");
        } else {
            console.warn("Contract verification failed:", error.message);
        }
    }
};

module.exports = {
    estimateContractDeploymentGas,
    verifyContract
};
