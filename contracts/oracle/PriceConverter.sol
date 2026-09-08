// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

import { IOracleSecurityModule } from "../interfaces/IOracleSecurityModule.sol";
import { IPriceConverter } from "../interfaces/IPriceConverter.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { _RAY, _WAD, _WARD_ROLE } from "../shared/Constants.sol";
import { InvalidAddress, InvalidAmount, NotLive, UnrecognizedParameter } from "../shared/Errors.sol";
import { Cage } from "../shared/Events.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title PriceConverter
 * @author Rain Team
 * @notice The link between the oracle and the Vault Engine. Takes the delayed price and divides it by the required
 *         collateralization ratio to produce the price factor, the maximum USDR mintable per unit of collateral. For
 *         RAIN at $1 with a 400% ratio, the factor is $0.25. Supported stablecoins skip the oracle entirely. They are
 *         marked fixed and always convert at $1, so USDR mints 1:1 against them.
 * @dev Every ilk is configured as exactly one of two kinds. A fixed ilk has no oracle lookup and its price is pinned
 *      to $1, with the trust decision living in listing governance. An oracle-backed ilk reads its price from the
 *      single system-wide OSM, set once via `file("oracleSecurityModule")`. The OSM itself never learns about fixed
 *      ilks. Being registered on the OSM is what needs a price lookup means, and this contract is the single place
 *      that routes between the two kinds via the per-ilk `fixed` flag. `poke` reverts for unconfigured ilks rather
 *      than writing a zero spot, and an oracle-backed ilk the OSM does not serve fails closed to a zero spot.
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
    IOracleSecurityModule public oracleSecurityModule;

    /// @inheritdoc IPriceConverter
    mapping(bytes32 ilkId => IlkOracle oracle) public ilks;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the converter with the Vault Engine.
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
    function file(bytes32 what, address data) external onlyRole(_WARD_ROLE) {
        if (live != 1) {
            _revert(NotLive.selector);
        }

        if (what == "oracleSecurityModule") {
            // The single system-wide OSM every oracle-backed ilk reads from.
            oracleSecurityModule = IOracleSecurityModule(data);
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, addr: data });
    }

    /**
     * @inheritdoc IPriceConverter
     */
    function file(bytes32 what, uint256 data) external onlyRole(_WARD_ROLE) {
        if (live != 1) {
            _revert(NotLive.selector);
        }

        if (what == "par") {
            // `par == 0` would make poke revert on division for every ilk, freezing all spots at their last values
            // since a stale spot keeps authorizing mints. And because file requires live == 1, a zeroed par could
            // never be repaired after cage. Guarding here matches the contract's own standard elsewhere
            // (MatBelowOne).
            if (data == 0) {
                _revert(InvalidAmount.selector);
            }

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
            // A collateralization ratio below 100% would authorize minting more than a dollar of USDR per dollar of
            // collateral at origination. No legitimate configuration wants that.
            if (data < _RAY) {
                _revert(MatBelowOne.selector);
            }

            ilks[ilkId].mat = data;
        } else if (what == "fixed") {
            // Marking an ilk fixed (1) pins it to $1 with no oracle lookup; clearing the flag (0) makes it
            // oracle-backed via the single system-wide OSM. Clearing is fail-closed: if the OSM does not serve the
            // ilk, poke writes a ZERO spot (freezing mints) rather than freezing the last value.
            if (data > 1) {
                _revert(InvalidAmount.selector);
            }

            ilks[ilkId].fixedPrice = data == 1;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ ilkId: ilkId, what: what, data: data });
    }

    /**
     * @inheritdoc IPriceConverter
     */
    function poke(bytes32 ilkId) external {
        IlkOracle storage ilk = ilks[ilkId];

        // The ilk must have been configured: a configured ilk always carries `mat >= RAY` (enforced at file time), so
        // a zero mat means governance never listed it and poke must revert rather than write a junk spot (it would
        // also divide by zero below).
        if (ilk.mat == 0) {
            _revert(IlkNotConfigured.selector);
        }

        bytes32 val;
        bool has;

        if (ilk.fixedPrice) {
            // Supported stablecoin: the price is pinned to $1, no oracle lookup.
            val = bytes32(_WAD);
            has = true;
        } else {
            // Oracle-backed collateral: the single system-wide OSM must have been assigned.
            if (address(oracleSecurityModule) == address(0)) {
                _revert(InvalidAddress.selector);
            }

            (val, has) = oracleSecurityModule.peek(ilkId);
        }

        // If the price is invalid, the price factor is set to ZERO, freezing new minting against this collateral until
        // a valid price returns (a zero spot makes every mint/withdraw fail the safety check).
        uint256 spot = has ? ((((uint256(val) * (10 ** 9)) * _RAY) / par) * _RAY) / ilk.mat : 0;

        VAULT_ENGINE.file(ilkId, "spot", spot);

        emit Poke({ ilkId: ilkId, val: val, spot: spot });
    }

    /**
     * @inheritdoc IPriceConverter
     */
    function cage() external onlyRole(_WARD_ROLE) {
        live = 0;

        emit Cage();
    }
}
