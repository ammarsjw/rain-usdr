// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

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
 * @notice The link between the oracle and the Vault Engine. Takes the delayed price and divides it by the required
 *         collateralization ratio to produce the price factor, the maximum USDR mintable per unit of collateral. For
 *         RAIN at $1 with a 400% ratio, the factor is $0.25. Supported stablecoins skip the oracle entirely. They are
 *         marked fixed and always convert at $1, so USDR mints 1:1 against them.
 * @dev Every ilk is configured as exactly one of two kinds. A fixed ilk has no oracle and its price is pinned to $1,
 *      with the trust decision living in listing governance. An oracle-backed ilk reads its price from the OSM. The
 *      OSM itself never learns about fixed ilks. Being registered on the OSM is what needs a price lookup means, and
 *      this contract is the single place that routes between the two kinds. `file("pip")` and `file("fixed")` clear
 *      each other so an ilk can never be both, and `poke` reverts for unconfigured ilks rather than writing a zero
 *      spot.
 */
contract PriceConverter is IPriceConverter, AccessControl {
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
        if (address(vaultEngine_) == address(0)) {
            _revert(InvalidAddress.selector);
        }

        _setRoleAdmin(_WARD_ROLE, _WARD_ROLE);

        _grantRole(_WARD_ROLE, msg.sender);

        VAULT_ENGINE = vaultEngine_;
        par = _RAY;
        live = 1;
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IPriceConverter
     */
    function file(bytes32 ilkId, bytes32 what, address pip) external onlyRole(_WARD_ROLE) {
        if (live != 1) {
            _revert(NotLive.selector);
        }

        if (what == "pip") {
            // Assigning an oracle makes the ilk oracle-backed. The kinds are mutually exclusive.
            ilks[ilkId].pip = IOracleSecurityModule(pip);
            ilks[ilkId].fixedPrice = false;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ ilkId: ilkId, what: what, pip: pip });
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
            // A collateralization ratio below 100% would authorize minting more than a dollar of USDR per dollar
            // of collateral at origination. No legitimate configuration wants that.
            if (data < _RAY) {
                _revert(MatBelowOne.selector);
            }

            ilks[ilkId].mat = data;
        } else if (what == "fixed") {
            if (data == 1) {
                // Marking an ilk fixed pins it to $1 and detaches any oracle.
                ilks[ilkId].fixedPrice = true;
                ilks[ilkId].pip = IOracleSecurityModule(address(0));
            } else {
                // Clearing the fixed flag on an ilk with no oracle would silently brick its price updates and
                // freeze spot at its last value (the dangerous direction: a stale price keeps authorizing mints).
                // The flag is only clearable by assigning an oracle via file("pip"), which clears it atomically.
                _revert(WouldOrphanIlk.selector);
            }
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

        // If the price is invalid, the price factor is set to ZERO, freezing new minting against this collateral
        // until a valid price returns (a zero spot makes every mint/withdraw fail the safety check).
        uint256 spot = has ? ((((uint256(val) * (10 ** 9)) * _RAY) / par) * _RAY) / ilk.mat : 0;

        VAULT_ENGINE.file(ilkId, "spot", spot);

        emit Poke({ ilkId: ilkId, val: val, spot: spot });
    }
}
