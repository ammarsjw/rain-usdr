const hardhat = require("hardhat");

const { CONFIG_STATE } = require("../shared/states");

const { wait } = require("./tools");

const waitBlocks = async (blocks) => {
    // Getting target block.
    const targetBlock = (await hardhat.ethers.provider.getBlockNumber()) + blocks;

    // Reading block time from shared state.
    const blockTime = CONFIG_STATE.blockTime;

    // Calculating wait time.
    const waitTime = blockTime * blocks;

    // Waiting.
    const quiet = true;
    await wait(`${waitTime} seconds`, quiet);

    // Checking if target block is reached.
    while (true) {
        // Getting current block.
        const currentBlock = await hardhat.ethers.provider.getBlockNumber();

        // Exiting if target has been reached.
        if (currentBlock >= targetBlock) {
            break;
        }

        // Waiting.
        const quiet = true;
        await wait("100 milliseconds", quiet);
    }
};

const waitNextBlock = async () => {
    // Forwarding call to `waitBlocks` with argument `1`.
    await waitBlocks(1);
};

module.exports = {
    waitBlocks,
    waitNextBlock
};
