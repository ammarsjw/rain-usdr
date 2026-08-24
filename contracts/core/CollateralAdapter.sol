// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ICollateralAdapter } from "../interfaces/ICollateralAdapter.sol";
import { IUSDR } from "../interfaces/IUSDR.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { _RAY, _USDR_ILK, _WARD_ROLE } from "../shared/Constants.sol";
import { IlkAlreadyInitialized, InvalidAddress, InvalidAmount, NotLive } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title CollateralAdapter
 * @author Rain Team
 * @notice The doorway for tokens entering and leaving the system. Bridges real tokens (RAIN, USDT, USDC, and USDR
 *         itself) and the internal ledger. A single deployed instance serves every token: ilks are registered
 *         dynamically, each carrying its own token and custody or mint and burn behaviour.
 * @dev A single ilk-keyed module handles every token. Collateral ilks convert token decimals (USDT and USDC use 6,
 *      RAIN uses 18) to the internal 18 decimal representation and update the ledger through `slip`. The USDR ilk,
 *      registered under {_USDR_ILK}, moves internal balances (45 decimals) through `move` and mints or burns the
 *      ERC-20. Merging is safe because only `_WARD_ROLE` may register ilks and USDR mint authority is granted to this
 *      single contract on the token itself, so the collateral code path can never reach `mint`.
 */
contract CollateralAdapter is ICollateralAdapter, AccessControl {
    using SafeERC20 for IERC20Metadata;

    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc ICollateralAdapter
    IVaultEngine public immutable VAULT_ENGINE;

    /// @inheritdoc ICollateralAdapter
    mapping(bytes32 ilkId => Ilk ilk) public ilks;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the adapter with the core ledger and authorizes the deployer.
     * @param vaultEngine_ Address of the Vault Engine.
     */
    constructor(IVaultEngine vaultEngine_) {
        if (address(vaultEngine_) == address(0)) {
            _revert(InvalidAddress.selector);
        }

        _setRoleAdmin(_WARD_ROLE, _WARD_ROLE);

        _grantRole(_WARD_ROLE, msg.sender);

        VAULT_ENGINE = vaultEngine_;
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc ICollateralAdapter
     */
    function init(bytes32 ilkId, IERC20Metadata token) external onlyRole(_WARD_ROLE) {
        if (address(token) == address(0)) {
            _revert(InvalidAddress.selector);
        }

        if (address(ilks[ilkId].token) != address(0)) {
            _revert(IlkAlreadyInitialized.selector);
        }

        uint8 dec = token.decimals();

        // Tokens with more than 18 decimals cannot be represented internally: the `10 ** (18 - dec)` conversion would
        // underflow. Reject them at registration.
        if (dec > 18) {
            _revert(InvalidDecimals.selector);
        }

        ilks[ilkId] = Ilk({ token: token, dec: dec, isUsdr: ilkId == _USDR_ILK, live: 1 });

        emit Init({ ilkId: ilkId, token: address(token) });
    }

    /**
     * @inheritdoc ICollateralAdapter
     */
    function cage(bytes32 ilkId) external onlyRole(_WARD_ROLE) {
        // Caging an unregistered ilk is rejected: silently succeeding would let a typoed governance call report
        // success while the intended ilk stays live.
        if (address(ilks[ilkId].token) == address(0)) {
            _revert(InvalidAddress.selector);
        }

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

        // Zero-amount operations are rejected rather than emitting no-op events that pollute indexers.
        if (amount == 0) {
            _revert(InvalidAmount.selector);
        }

        if (ilk.isUsdr) {
            // Returning USDR into the system keeps working after shutdown.
            VAULT_ENGINE.move(address(this), user, _RAY * amount);
            IUSDR(address(ilk.token)).burn(msg.sender, amount);
        } else {
            // Deposits are blocked after shutdown. Withdrawals continue to work.
            if (ilk.live != 1) {
                _revert(NotLive.selector);
            }

            // Measuring the balance delta actually received rather than trusting the nominal amount: a fee-on-transfer
            // or rebasing token would otherwise credit more than the adapter holds, silently under-collateralizing the
            // shared adapter and socializing the shortfall across every holder of the ilk. Only the delta is credited,
            // and any shortfall surfaces here as a hard revert.
            uint256 balanceBefore = ilk.token.balanceOf(address(this));

            ilk.token.safeTransferFrom(msg.sender, address(this), amount);

            uint256 received = ilk.token.balanceOf(address(this)) - balanceBefore;

            if (received != amount) {
                _revert(FeeOnTransferToken.selector);
            }

            // Converting token decimals to the internal 18 decimal representation.
            uint256 wad = received * (10 ** (18 - ilk.dec));

            // The value must fit the signed range before casting.
            if (wad > uint256(type(int256).max)) {
                _revert(InvalidAmount.selector);
            }

            VAULT_ENGINE.slip(ilkId, user, int256(wad));
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

        // Zero-amount operations are rejected rather than emitting no-op events that pollute indexers.
        if (amount == 0) {
            _revert(InvalidAmount.selector);
        }

        if (ilk.isUsdr) {
            // Minting is blocked after shutdown. Returning USDR continues to work.
            if (ilk.live != 1) {
                _revert(NotLive.selector);
            }

            VAULT_ENGINE.move(msg.sender, address(this), _RAY * amount);
            IUSDR(address(ilk.token)).mint(user, amount);
        } else {
            // Converting token decimals to the internal 18 decimal representation.
            // NOTE: exit takes the amount in TOKEN decimals, so for 6-decimal ilks any internal balance below 1e12
            // (one token unit scaled to 18 decimals) is unreachable by exit. Such sub-unit ledger dust can only arise
            // from internal transfers (flux), never from join/frob flows, and is bounded by one token unit per holder;
            // it stays on the ledger rather than being silently rounded away.
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
