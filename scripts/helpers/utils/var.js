const hardhat = require("hardhat");

const { TYPE_HASH } = require("../shared/constants");

const fetchDomainSeparator = async (contractName, contractVersion, contractAddress) => {
    // Fetching domain separator.
    const domainSeparator = await getDomainSeparator(contractName, contractVersion, contractAddress);

    // Logging data.
    console.log(contractName, "domain separator:", domainSeparator);
};

const getDomainSeparator = async (contractName, contractVersion, contractAddress) => {
    const name = hardhat.ethers.keccak256(hardhat.ethers.toUtf8Bytes(contractName));
    const version = hardhat.ethers.keccak256(hardhat.ethers.toUtf8Bytes(contractVersion));
    const chainId = (await hardhat.ethers.provider.getNetwork()).chainId;
    const verifyingContract = contractAddress;

    const typeHashDataTypes = ["bytes32", "bytes32", "bytes32", "uint256", "address"];
    const typeHashData = [TYPE_HASH, name, version, chainId, verifyingContract];

    const domainSeparator = hardhat.ethers.keccak256(
        hardhat.ethers.AbiCoder.defaultAbiCoder().encode(typeHashDataTypes, typeHashData)
    );

    return domainSeparator;
};

module.exports = {
    fetchDomainSeparator,
    getDomainSeparator
};
