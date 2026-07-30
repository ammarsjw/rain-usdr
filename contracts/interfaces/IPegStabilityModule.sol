// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { ICollateralAdapter } from "./ICollateralAdapter.sol";
import { IReserveAccounting } from "./IReserveAccounting.sol";
import { IUSDR } from "./IUSDR.sol";
import { IVaultEngine } from "./IVaultEngine.sol";

/**
 * @title IPegStabilityModule
 * @author Rain Team
 * @notice Interface for the module that swaps stablecoins for USDR at 1:1, serving every stablecoin from a single
 *         deployed instance.
 */
interface IPegStabilityModule {
    /* ========================== TYPES ========================== */

    /**
     * @notice Configuration of a registered stablecoin ilk.
     * @param token The stablecoin (USDT or USDC).
     * @param to18ConversionFactor Decimal conversion factor between the stablecoin and 18 decimals.
     * @param tin Mint fee [wad]. Zero at launch.
     * @param tout Redeem fee [wad]. Zero at launch.
     */
    struct Ilk {
        IERC20Metadata token;
        uint256 to18ConversionFactor;
        uint256 tin;
        uint256 tout;
    }

    /* ========================== EVENTS ========================== */

    /**
     * @dev Emitted when a stablecoin ilk is registered.
     * @param ilkId Identifier of the stablecoin's collateral type.
     * @param token Address of the stablecoin.
     */
    event Init(bytes32 indexed ilkId, address indexed token);

    /**
     * @dev Emitted when a fee parameter is updated.
     * @param ilkId Identifier of the stablecoin's collateral type.
     * @param what Name of the parameter.
     * @param data New value [wad].
     */
    event File(bytes32 indexed ilkId, bytes32 indexed what, uint256 data);

    /**
     * @dev Emitted when a user converts stablecoins into USDR.
     * @param ilkId Identifier of the stablecoin's collateral type.
     * @param user Account that receives the USDR.
     * @param stableAmt Stablecoin amount, in the token's native decimals.
     * @param usdrAmt USDR amount received.
     */
    event SellStable(bytes32 indexed ilkId, address indexed user, uint256 stableAmt, uint256 usdrAmt);

    /**
     * @dev Emitted when a user redeems USDR for stablecoins.
     * @param ilkId Identifier of the stablecoin's collateral type.
     * @param user Account that receives the stablecoins.
     * @param stableAmt Stablecoin amount, in the token's native decimals.
     * @param usdrAmt USDR amount spent.
     */
    event BuyStable(bytes32 indexed ilkId, address indexed user, uint256 stableAmt, uint256 usdrAmt);

    /* ========================== FUNCTIONS ========================== */

    /**
     * @notice Returns the USDR token.
     */
    function USDR() external view returns (IUSDR);

    /**
     * @notice Returns the Vault Engine this module reports to.
     */
    function VAULT_ENGINE() external view returns (IVaultEngine);

    /**
     * @notice Returns the reserve accounting contract that reports free slack.
     */
    function RESERVE_ACCOUNTING() external view returns (IReserveAccounting);

    /**
     * @notice Returns the token adapter, a single instance that bridges both stablecoins and USDR.
     */
    function COLLATERAL_ADAPTER() external view returns (ICollateralAdapter);

    /**
     * @notice Returns the configuration of a stablecoin ilk.
     * @param ilkId Identifier of the stablecoin's collateral type.
     * @return token The stablecoin.
     * @return to18ConversionFactor Decimal conversion factor between the stablecoin and 18 decimals.
     * @return tin Mint fee [wad].
     * @return tout Redeem fee [wad].
     */
    function ilks(
        bytes32 ilkId
    ) external view returns (IERC20Metadata token, uint256 to18ConversionFactor, uint256 tin, uint256 tout);

    /**
     * @notice Registers a stablecoin ilk. This is how new stablecoins are added to the module.
     * @dev The ilk must already be registered with the Collateral Adapter, and must not be the USDR ilk. The token
     *      and its decimals are read from the adapter.
     * @param ilkId Identifier of the stablecoin's collateral type.
     */
    function init(bytes32 ilkId) external;

    /**
     * @notice Adjusts a stablecoin's mint fee ("tin") or redeem fee ("tout"). Both zero at launch.
     * @param ilkId Identifier of the stablecoin's collateral type.
     * @param what Name of the parameter.
     * @param data New value [wad].
     */
    function file(bytes32 ilkId, bytes32 what, uint256 data) external;

    /**
     * @notice Converts stablecoins into USDR at a 1:1 rate.
     * @dev The mint must not push the stablecoin's total past its debt ceiling.
     * @param ilkId Identifier of the stablecoin's collateral type.
     * @param user Account that receives the USDR.
     * @param stableAmt Stablecoin amount, in the token's native decimals.
     */
    function sellStable(bytes32 ilkId, address user, uint256 stableAmt) external;

    /**
     * @notice Converts USDR back into stablecoins at 1:1 when reserves allow.
     * @dev Best-effort by design. Reverts if the amount exceeds the current free slack.
     * @param ilkId Identifier of the stablecoin's collateral type.
     * @param user Account that receives the stablecoins.
     * @param stableAmt Stablecoin amount, in the token's native decimals.
     */
    function buyStable(bytes32 ilkId, address user, uint256 stableAmt) external;
}
