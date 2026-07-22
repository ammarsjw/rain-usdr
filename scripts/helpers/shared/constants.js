// BigInt zero.
const BIGINT_ZERO = 0n;

// BigInt one hundred.
const BIGINT_HUNDRED = 100n;

// keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
const TYPE_HASH = "0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f";

// keccak256("Authority")
const AUTHORITY_ROLE = "0x8b16b0b80f67879a61157c5541d94886825d45098bee58e37e2d2e87b2fe367b";

// keccak256("Owner")
const OWNER_ROLE = "0x929f3fd6848015f83b9210c89f7744e3941acae1195c8bf9f5798c090dc8f497";

module.exports = {
    BIGINT_ZERO,
    BIGINT_HUNDRED,
    TYPE_HASH,
    AUTHORITY_ROLE,
    OWNER_ROLE
};
