// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Auth } from "../extensions/Auth.sol";
import { ICollateralAdapter } from "../interfaces/ICollateralAdapter.sol";
import { IUSDR } from "../interfaces/IUSDR.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { _RAY, _USDR_ILK, _WARD_ROLE } from "../shared/Constants.sol";
import { InvalidAddress, InvalidAmount, NotLive } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title CollateralAdapter
 * @author Rain Team
 * @notice The doorway for tokens entering and leaving the system. Bridges real tokens (RAIN, USDT, USDC — and USDR
 *         itself) and the internal ledger. A single deployed instance serves every token: ilks are registered
 *         dynamically, each carrying its own token and custody or mint/burn behaviour.
 * @dev Merges MakerDAO's GemJoin and DaiJoin into one contract, generalized from one-instance-per-token to a single
 *      ilk-keyed module. Collateral ilks convert token decimals (USDT/USDC use 6, RAIN uses 18) to the internal 18
 *      decimal representation and update the ledger through `slip`; the USDR ilk (registered under {_USDR_ILK}) moves
 *      internal balances (45 decimals) through `move` and mints/burns the ERC-20. Merging is safe because only
 *      `_WARD_ROLE` may register ilks and USDR mint authority is granted to this single contract on the token
 *      itself — the collateral code path can never reach `mint`.
 */
contract CollateralAdapter is ICollateralAdapter, Auth {
    using SafeERC20 for IERC20Metadata;

    /* ========================== TYPES ========================== */

    /**
     * @notice Configuration and state of a registered ilk.
     * @param token The token this ilk bridges — held in custody, or minted/burned for USDR.
     * @param dec Decimals of the token.
     * @param isUsdr Whether this ilk is the USDR ilk (`move` + mint/burn) or a collateral ilk (`slip` + custody).
     * @param live Ilk liveness flag. `1` while live, `0` after shutdown.
     */
    struct Ilk {
        IERC20Metadata token;
        uint8 dec;
        bool isUsdr;
        uint256 live;
    }

    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc ICollateralAdapter
    IVaultEngine public immutable VAULT_ENGINE;

    /// @inheritdoc ICollateralAdapter
    mapping(bytes32 ilkId => Ilk ilk) public ilks;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the adapter with the core ledger.
     * @param vaultEngine_ Address of the Vault Engine.
     */
    constructor(IVaultEngine vaultEngine_) {
        VAULT_ENGINE = vaultEngine_;
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc ICollateralAdapter
     */
    function init(bytes32 ilkId, IERC20Metadata token_) external onlyRole(_WARD_ROLE) {
        if (address(token_) == address(0)) {
            _revert(InvalidAddress.selector);
        }
        require(address(ilks[ilkId].token) == address(0), "CollateralAdapter/ilk-already-init");

        ilks[ilkId] = Ilk({ token: token_, dec: token_.decimals(), isUsdr: ilkId == _USDR_ILK, live: 1 });

        emit Init({ ilkId: ilkId, token: address(token_) });
    }

    /**
     * @inheritdoc ICollateralAdapter
     */
    function cage(bytes32 ilkId) external onlyRole(_WARD_ROLE) {
        ilks[ilkId].live = 0;

        emit Cage({ ilkId: ilkId });
    }

    /**
     * @inheritdoc ICollateralAdapter
     */
    function join(bytes32 ilkId, address user, uint256 amount) external {
        Ilk storage ilk = ilks[ilkId];

        // The ilk must be registered.
        if (address(ilk.token) == address(0)) {
            _revert(InvalidAddress.selector);
        }

        if (ilk.isUsdr) {
            // Returning USDR into the system keeps working after shutdown.
            VAULT_ENGINE.move(address(this), user, _RAY * amount);
            IUSDR(address(ilk.token)).burn(msg.sender, amount);
        } else {
            // Deposits are blocked after shutdown; withdrawals continue to work.
            if (ilk.live != 1) {
                _revert(NotLive.selector);
            }

            // Converting token decimals to the internal 18 decimal representation.
            uint256 wad = amount * (10 ** (18 - ilk.dec));

            if (int256(wad) < 0) {
                _revert(InvalidAmount.selector);
            }

            VAULT_ENGINE.slip(ilkId, user, int256(wad));
            ilk.token.safeTransferFrom(msg.sender, address(this), amount);
        }

        emit Join({ ilkId: ilkId, user: user, amount: amount });
    }

    /**
     * @inheritdoc ICollateralAdapter
     */
    function exit(bytes32 ilkId, address user, uint256 amount) external {
        Ilk storage ilk = ilks[ilkId];

        // The ilk must be registered.
        if (address(ilk.token) == address(0)) {
            _revert(InvalidAddress.selector);
        }

        if (ilk.isUsdr) {
            // Minting is blocked after shutdown; returning USDR continues to work.
            if (ilk.live != 1) {
                _revert(NotLive.selector);
            }

            VAULT_ENGINE.move(msg.sender, address(this), _RAY * amount);
            IUSDR(address(ilk.token)).mint(user, amount);
        } else {
            // Converting token decimals to the internal 18 decimal representation.
            uint256 wad = amount * (10 ** (18 - ilk.dec));

            if (wad > uint256(type(int256).max)) {
                _revert(InvalidAmount.selector);
            }

            VAULT_ENGINE.slip(ilkId, msg.sender, -int256(wad));
            ilk.token.safeTransfer(user, amount);
        }

        emit Exit({ ilkId: ilkId, user: user, amount: amount });
    }
}
