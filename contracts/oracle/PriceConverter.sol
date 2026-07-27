// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IOracleSecurityModule } from "../interfaces/IOracleSecurityModule.sol";
import { IPriceConverter } from "../interfaces/IPriceConverter.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { Auth } from "../extensions/Auth.sol";
import { RAY, WARD_ROLE } from "../shared/Constants.sol";
import { NotLive, UnrecognizedParameter } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title PriceConverter.
 * @author Rain Team.
 * @notice The link between the oracle and the Vault Engine. Takes the delayed price and divides
 *         it by the required collateralization ratio to produce the price factor — the maximum
 *         USDR mintable per unit of collateral. For RAIN at $1 with a 400% ratio, the factor
 *         is $0.25.
 * @dev Based on MakerDAO's Spot.
 */
contract PriceConverter is IPriceConverter, Auth {
    /* ========================== TYPES ========================== */

    /**
     * @notice Oracle configuration for a collateral type.
     * @param pip The collateral's Oracle Security Module.
     * @param mat The required collateralization ratio [ray]. 400% = 4 * RAY.
     */
    struct IlkOracle {
        IOracleSecurityModule pip;
        uint256 mat;
    }

    /* ========================== STATE VARIABLES ========================== */

    /// @notice Oracle configuration per collateral type.
    mapping(bytes32 ilkId => IlkOracle oracle) public ilks;

    /// @notice The Vault Engine (core ledger).
    IVaultEngine public immutable vaultEngine;

    /// @notice The target dollar value of USDR [ray]. Fixed at 1.0 (par).
    uint256 public par;

    /// @notice Liveness flag. `1` while live, `0` after shutdown.
    uint256 public live;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the converter with the Vault Engine and a par value of 1.0.
     * @param vaultEngine_ Address of the Vault Engine.
     */
    constructor(IVaultEngine vaultEngine_) {
        vaultEngine = vaultEngine_;
        par = RAY;
        live = 1;
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IPriceConverter
     */
    function file(bytes32 ilkId, bytes32 what, address pip_) external onlyRole(WARD_ROLE) {
        if (live != 1) {
            _revert(NotLive.selector);
        }

        if (what == "pip") {
            ilks[ilkId].pip = IOracleSecurityModule(pip_);
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ ilkId: ilkId, what: what, pip: pip_ });
    }

    /**
     * @inheritdoc IPriceConverter
     */
    function file(bytes32 what, uint256 data) external onlyRole(WARD_ROLE) {
        if (live != 1) {
            _revert(NotLive.selector);
        }

        if (what == "par") {
            par = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, data: data });
    }

    /**
     * @inheritdoc IPriceConverter
     */
    function file(bytes32 ilkId, bytes32 what, uint256 data) external onlyRole(WARD_ROLE) {
        if (live != 1) {
            _revert(NotLive.selector);
        }

        if (what == "mat") {
            ilks[ilkId].mat = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ ilkId: ilkId, what: what, data: data });
    }

    /**
     * @inheritdoc IPriceConverter
     */
    function cage() external onlyRole(WARD_ROLE) {
        live = 0;

        emit Cage();
    }

    /**
     * @inheritdoc IPriceConverter
     */
    function poke(bytes32 ilkId) external {
        (bytes32 val, bool has) = ilks[ilkId].pip.peek();

        // If the price is invalid, do nothing (the price factor stays untouched).
        uint256 spot = has ? ((((uint256(val) * (10 ** 9)) * RAY) / par) * RAY) / ilks[ilkId].mat : 0;

        vaultEngine.file(ilkId, "spot", spot);

        emit Poke({ ilkId: ilkId, val: val, spot: spot });
    }
}
