// BigInt zero.
const BIGINT_ZERO = 0n;

// BigInt one hundred.
const BIGINT_HUNDRED = 100n;

// keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
const TYPE_HASH = "0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f";

// keccak256("COMMITTER_ROLE")
const COMMITTER_ROLE = "0x0b60b5d7f7e737e4561eecda7c6a01e19e626c495c26e6f45e5b255f76a20106";

// keccak256("READER_ROLE")
const READER_ROLE = "0xc757f485a2bb9eadbad5c86f7618c2a7a2ecb41b29f8610fb0e8bea3ed5ab6cf";

// keccak256("RECORDER_ROLE")
const RECORDER_ROLE = "0xf996da754c790e95d5c7ca3330cfcad529487fe9d1d8edb7afc65076fdf9adb4";

// keccak256("WARD_ROLE")
const WARD_ROLE = "0xbafcd51963b0d7b3a3da265619edae46625d8c081f4c6ac796f4531050ac941f";

module.exports = {
    BIGINT_ZERO,
    BIGINT_HUNDRED,
    TYPE_HASH,
    COMMITTER_ROLE,
    READER_ROLE,
    RECORDER_ROLE,
    WARD_ROLE
};
