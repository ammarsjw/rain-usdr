// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IExternalExposure } from "../interfaces/IExternalExposure.sol";
import { IReserveAccounting } from "../interfaces/IReserveAccounting.sol";
import { ISolvencyEngine } from "../interfaces/ISolvencyEngine.sol";
import { IVaultEngine } from "../interfaces/IVaultEngine.sol";
import { RAY, WAD } from "../shared/Constants.sol";
import { NotAuthorized, UnrecognizedParameter } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title SolvencyEngine.
 * @author Rain Team.
 * @notice The guardian. Computes the protocol's worst-case loss under stress and verifies that
 *         the stable reserve exceeds it. If that rule would ever be broken, the protocol refuses
 *         the action that would break it. This single rule is what makes USDR provably solvent.
 * @dev Custom to USDR. The stress scenario marks volatile assets down 50% and assumes only 35%
 *      of normal liquidation market depth. Exposure reported by the prediction market layer is
 *      consumed as a number through a dedicated interface owned by the other team.
 */
contract SolvencyEngine is ISolvencyEngine {
    /* ========================== STATE VARIABLES ========================== */

    /// @notice Authorized accounts. `wards[account] == 1` grants authorization.
    mapping(address account => uint256 authorization) public wards;

    /// @notice The Vault Engine (core ledger).
    IVaultEngine public immutable vaultEngine;

    /// @notice The reserve accounting contract.
    IReserveAccounting public immutable reserveAccounting;

    /// @notice The prediction market layer's exposure reporter. May be unset at launch.
    IExternalExposure public externalExposure;

    /// @notice Volatile collateral types included in the stress calculation.
    bytes32[] public volatileIlks;

    /// @notice Stress markdown applied to volatile asset prices [wad]. 50% = 0.5 * WAD.
    uint256 public stressMarkdown;

    /// @notice Assumed liquidation market depth under stress [wad]. 35% = 0.35 * WAD.
    uint256 public stressDepth;

    /* ========================== MODIFIERS ========================== */

    /// @dev Restricts a function to authorized accounts.
    modifier auth() {
        if (wards[msg.sender] != 1) {
            _revert(NotAuthorized.selector);
        }
        _;
    }

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the engine with its launch stress assumptions.
     * @param vaultEngine_ Address of the Vault Engine.
     * @param reserveAccounting_ Address of the reserve accounting contract.
     */
    constructor(IVaultEngine vaultEngine_, IReserveAccounting reserveAccounting_) {
        wards[msg.sender] = 1;
        vaultEngine = vaultEngine_;
        reserveAccounting = reserveAccounting_;
        stressMarkdown = WAD / 2;
        stressDepth = (WAD * 35) / 100;

        emit Rely({ account: msg.sender });
    }

    /* ========================== ADMINISTRATION ========================== */

    /**
     * @inheritdoc ISolvencyEngine
     */
    function rely(address account) external auth {
        wards[account] = 1;

        emit Rely({ account: account });
    }

    /**
     * @inheritdoc ISolvencyEngine
     */
    function deny(address account) external auth {
        wards[account] = 0;

        emit Deny({ account: account });
    }

    /**
     * @inheritdoc ISolvencyEngine
     */
    function file(bytes32 what, uint256 data) external auth {
        if (what == "stressMarkdown") {
            stressMarkdown = data;
        } else if (what == "stressDepth") {
            stressDepth = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, data: data });
    }

    /**
     * @inheritdoc ISolvencyEngine
     */
    function file(bytes32 what, address data) external auth {
        if (what == "externalExposure") {
            externalExposure = IExternalExposure(data);
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, data: uint256(uint160(data)) });
    }

    /**
     * @inheritdoc ISolvencyEngine
     */
    function addVolatileIlk(bytes32 ilkId) external auth {
        volatileIlks.push(ilkId);

        emit AddVolatileIlk({ ilkId: ilkId });
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc ISolvencyEngine
     */
    function worstCaseLoss() public view returns (uint256 loss) {
        // Adding the shortfall risk from volatile collateral, priced at stressed values:
        // debt outstanding minus the stressed recoverable value of the collateral backing it.
        uint256 volatileIlksLength = volatileIlks.length;

        for (uint256 i; i < volatileIlksLength; ++i) {
            bytes32 ilkId = volatileIlks[i];
            (uint256 Art, uint256 rate, uint256 spot, , ) = vaultEngine.ilks(ilkId);

            // Total debt against this collateral [wad].
            uint256 ilkDebt = (Art * rate) / RAY;

            // Stressed recoverable value: the debt's collateral backing, marked down by the
            // stress markdown and the stress liquidation depth.
            uint256 recoverable = (((ilkDebt * stressMarkdown) / WAD) * stressDepth) / WAD;

            if (ilkDebt > recoverable) {
                loss += ilkDebt - recoverable;
            }

            // Silencing the unused variable warning; `spot` is intentionally not used because
            // the stress scenario prices from debt outstanding, not current collateral value.
            spot;
        }

        // Adding any exposure reported by the prediction market layer.
        if (address(externalExposure) != address(0)) {
            loss += externalExposure.reportedExposure();
        }
    }

    /**
     * @inheritdoc ISolvencyEngine
     */
    function checkInvariant() external returns (uint256 loss, uint256 reserve) {
        loss = worstCaseLoss();
        reserve = reserveAccounting.totalReserve();

        // The master rule: worst-case loss must never exceed the stable reserve.
        require(loss <= reserve, "SolvencyEngine/solvency-breach");

        // Keeping the reserve split accurate.
        reserveAccounting.updateCommittedEscrow(loss);

        emit InvariantChecked({ reserve: reserve, worstCaseLoss: loss, passed: true });
    }
}
