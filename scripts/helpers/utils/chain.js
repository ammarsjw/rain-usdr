const hardhat = require("hardhat");

const fetchLatestTransaction = async (toAddress, blocksToScan = 100) => {
    const currentBlock = await hardhat.ethers.provider.getBlockNumber();

    // Getting `from` signer.
    const [from] = await hardhat.ethers.getSigners();

    // Getting `from` address.
    const fromAddress = from.address;

    // Scan recent blocks.
    for (let i = 0; i < blocksToScan; i++) {
        const blockNumber = currentBlock - i;

        if (blockNumber < 0) break;

        const block = await hardhat.ethers.provider.getBlockWithTransactions(blockNumber);

        // Check all transactions in the block.
        for (const transaction of block.transactions) {
            if (transaction.from === fromAddress && transaction.to === toAddress) {
                // Return the latest transaction found.
                return transaction;
            }
        }
    }

    return null;
};

module.exports = {
    fetchLatestTransaction
};
