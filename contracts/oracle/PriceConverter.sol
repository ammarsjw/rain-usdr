// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { Auth } from "../extensions/Auth.sol";
import { IOracleSecurityModule } from "../interfaces/IOracleSecurityModule.sol";
import { IPriceConverter } from "../interfaces/IPriceConverter.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { _RAY, _WAD, _WARD_ROLE } from "../shared/Constants.sol";
import { InvalidAddress, NotLive, UnrecognizedParameter } from "../shared/Errors.sol";
import { Cage } from "../shared/Events.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title PriceConverter
 * @author Rain Team
 * @notice The link between the oracle and the Vault Engine. Takes the delayed price and divides
 *         it by the required collateralization ratio to produce the price factor — the maximum
 *         USDR mintable per unit of collateral. For RAIN at $1 with a 400% ratio, the factor
 *         is $0.25. Supported stablecoins skip the oracle entirely: they are marked fixed and
 *         always convert at $1, so USDR mints 1:1 against them.
 * @dev Based on MakerDAO's Spot. Every ilk is configured as exactly one of two kinds — fixed
 *      (no oracle, price pinned to $1; the trust decision lives in listing governance) or
 *      oracle-backed (price read from the OSM). The OSM itself never learns about fixed ilks:
 *      being registered on the OSM is what "needs a price lookup" means, and this contract is
 *      the single place that routes between the two kinds. `file("pip")` and `file("fixed")` clear each other so an
 *      ilk can never be both, and `poke` reverts for unconfigured ilks rather than writing a zero spot.
 */
contract PriceConverter is IPriceConverter, Auth {
    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc IPriceConverter
    IVaultEngine public immutable VAULT_ENGINE;

    /// @inheritdoc IPriceConverter
    uint256 public par;

    /// @inheritdoc IPriceConverter
    uint256 public live;

    /// @inheritdoc IPriceConverter
    mapping(bytes32 ilkId => IlkOracle oracle) public ilks;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the converter with the Vault Engine and a par value of 1.0.
     * @param vaultEngine_ Address of the Vault Engine.
     */
    constructor(IVaultEngine vaultEngine_) {
        VAULT_ENGINE = vaultEngine_;
        par = _RAY;
        live = 1;
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IPriceConverter
     */
    function file(bytes32 ilkId, bytes32 what, address pip_) external onlyRole(_WARD_ROLE) {
        if (live != 1) {
            _revert(NotLive.selector);
        }

        if (what == "pip") {
            // Assigning an oracle makes the ilk oracle-backed; the kinds are mutually exclusive.
            ilks[ilkId].pip = IOracleSecurityModule(pip_);
            ilks[ilkId].fixedPrice = false;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ ilkId: ilkId, what: what, pip: pip_ });
    }

    /**
     * @inheritdoc IPriceConverter
     */
    function file(bytes32 what, uint256 data) external onlyRole(_WARD_ROLE) {
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
    function file(bytes32 ilkId, bytes32 what, uint256 data) external onlyRole(_WARD_ROLE) {
        if (live != 1) {
            _revert(NotLive.selector);
        }

        if (what == "mat") {
            ilks[ilkId].mat = data;
        } else if (what == "fixed") {
            // Marking an ilk fixed pins it to $1 and detaches any oracle; clearing it leaves
            // the ilk unconfigured until an oracle is assigned.
            ilks[ilkId].fixedPrice = data == 1;
            ilks[ilkId].pip = IOracleSecurityModule(address(0));
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ ilkId: ilkId, what: what, data: data });
    }

    /**
     * @inheritdoc IPriceConverter
     */
    function cage() external onlyRole(_WARD_ROLE) {
        live = 0;

        emit Cage();
    }

    /**
     * @inheritdoc IPriceConverter
     */
    function poke(bytes32 ilkId) external {
        IlkOracle storage ilk = ilks[ilkId];

        bytes32 val;
        bool has;

        if (ilk.fixedPrice) {
            // Supported stablecoin: the price is pinned to $1, no oracle lookup.
            val = bytes32(_WAD);
            has = true;
        } else {
            // Oracle-backed collateral: the ilk must have an oracle assigned.
            if (address(ilk.pip) == address(0)) {
                _revert(InvalidAddress.selector);
            }

            (val, has) = ilk.pip.peek(ilkId);
        }

        // If the price is invalid, do nothing (the price factor stays untouched).
        uint256 spot = has ? ((((uint256(val) * (10 ** 9)) * _RAY) / par) * _RAY) / ilk.mat : 0;

        VAULT_ENGINE.file(ilkId, "spot", spot);

        emit Poke({ ilkId: ilkId, val: val, spot: spot });
    }
}
