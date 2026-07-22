// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IReserveAccounting } from "../interfaces/IReserveAccounting.sol";
import { NotAuthorized } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title ReserveAccounting.
 * @author Rain Team.
 * @notice The bookkeeper for the protocol's stable dollars. Tracks the total reserve (all USDT
 *         and USDC held), how much is committed to guaranteed obligations (the settlement
 *         escrow), and how much is free (the slack). This is where the reserve is split so
 *         that the same dollar is never promised twice.
 * @dev Custom to USDR. Only the Solvency Engine may update the committed escrow, and only the
 *      Peg Stability Modules may record reserve movements.
 */
contract ReserveAccounting is IReserveAccounting {
    /* ========================== STATE VARIABLES ========================== */

    /// @notice Authorized accounts. `wards[account] == 1` grants authorization.
    mapping(address account => uint256 authorization) public wards;

    /// @notice Contracts allowed to record reserve movements (the Peg Stability Modules).
    mapping(address account => uint256 permission) public recorders;

    /// @notice Contracts allowed to update the committed escrow (the Solvency Engine).
    mapping(address account => uint256 permission) public committers;

    /// @notice Total stable reserve (all USDT and USDC held) [wad].
    uint256 public totalReserve;

    /// @notice Amount committed to guaranteed obligations (the settlement escrow) [wad].
    uint256 public committedEscrow;

    /* ========================== MODIFIERS ========================== */

    /// @dev Restricts a function to authorized accounts.
    modifier auth() {
        if (wards[msg.sender] != 1) {
            _revert(NotAuthorized.selector);
        }
        _;
    }

    /// @dev Restricts a function to authorized recorders.
    modifier onlyRecorder() {
        if (recorders[msg.sender] != 1) {
            _revert(NotAuthorized.selector);
        }
        _;
    }

    /// @dev Restricts a function to authorized committers.
    modifier onlyCommitter() {
        if (committers[msg.sender] != 1) {
            _revert(NotAuthorized.selector);
        }
        _;
    }

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Authorizes the deployer.
     */
    constructor() {
        wards[msg.sender] = 1;

        emit Rely({ account: msg.sender });
    }

    /* ========================== ADMINISTRATION ========================== */

    /**
     * @inheritdoc IReserveAccounting
     */
    function rely(address account) external auth {
        wards[account] = 1;

        emit Rely({ account: account });
    }

    /**
     * @inheritdoc IReserveAccounting
     */
    function deny(address account) external auth {
        wards[account] = 0;

        emit Deny({ account: account });
    }

    /**
     * @inheritdoc IReserveAccounting
     */
    function addRecorder(address account) external auth {
        recorders[account] = 1;

        emit AddRecorder({ account: account });
    }

    /**
     * @inheritdoc IReserveAccounting
     */
    function removeRecorder(address account) external auth {
        recorders[account] = 0;

        emit RemoveRecorder({ account: account });
    }

    /**
     * @inheritdoc IReserveAccounting
     */
    function addCommitter(address account) external auth {
        committers[account] = 1;

        emit AddCommitter({ account: account });
    }

    /**
     * @inheritdoc IReserveAccounting
     */
    function removeCommitter(address account) external auth {
        committers[account] = 0;

        emit RemoveCommitter({ account: account });
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc IReserveAccounting
     */
    function recordIncrease(uint256 wad) external onlyRecorder {
        totalReserve += wad;

        emit RecordIncrease({ wad: wad, totalReserve: totalReserve });
    }

    /**
     * @inheritdoc IReserveAccounting
     */
    function recordDecrease(uint256 wad) external onlyRecorder {
        totalReserve -= wad;

        emit RecordDecrease({ wad: wad, totalReserve: totalReserve });
    }

    /**
     * @inheritdoc IReserveAccounting
     */
    function updateCommittedEscrow(uint256 wad) external onlyCommitter {
        // The committed amount must not exceed the total reserve — this is the solvency
        // guarantee expressed at the accounting level.
        require(wad <= totalReserve, "ReserveAccounting/escrow-exceeds-reserve");

        committedEscrow = wad;

        emit UpdateCommittedEscrow({ wad: wad, freeSlack: totalReserve - wad });
    }

    /**
     * @inheritdoc IReserveAccounting
     */
    function freeSlack() external view returns (uint256) {
        // Never negative, because `updateCommittedEscrow` forbids committing more than exists.
        return totalReserve - committedEscrow;
    }
}
