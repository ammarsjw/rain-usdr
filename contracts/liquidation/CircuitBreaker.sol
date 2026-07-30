// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

import { ICircuitBreaker } from "../interfaces/ICircuitBreaker.sol";
import { IOracleSecurityModule } from "../interfaces/IOracleSecurityModule.sol";
import { _WAD, _WARD_ROLE } from "../shared/Constants.sol";
import { UnrecognizedParameter } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title CircuitBreaker
 * @author Rain Team
 * @notice A defense against price manipulation during liquidation. Watches how far the delayed price has moved from
 *         its recent trend. If the move is too large too fast, it throttles liquidations, slowing them but never
 *         freezing them, so a manipulated price cannot trigger a wave of unfair liquidations. It never touches
 *         ordinary vault operations.
 * @dev Activates when the delayed price deviates more than the threshold (25%) from the one-hour trend. Deactivates
 *      after the deviation stays below the threshold for the required number of consecutive calm blocks (3).
 */
contract CircuitBreaker is ICircuitBreaker, AccessControl {
    /* ========================== STATE VARIABLES ========================== */

    /// @inheritdoc ICircuitBreaker
    uint256 public constant TREND_WINDOW = 3600;

    /// @inheritdoc ICircuitBreaker
    IOracleSecurityModule public immutable PIP;

    /// @inheritdoc ICircuitBreaker
    bytes32 public immutable ILK_ID;

    /// @inheritdoc ICircuitBreaker
    uint256 public threshold;

    /// @inheritdoc ICircuitBreaker
    uint256 public calmBlocks;

    /// @inheritdoc ICircuitBreaker
    uint256 public trendPrice;

    /// @inheritdoc ICircuitBreaker
    uint256 public trendTimestamp;

    /// @inheritdoc ICircuitBreaker
    uint256 public calmCount;

    /// @inheritdoc ICircuitBreaker
    uint256 public lastCheckedBlock;

    /// @inheritdoc ICircuitBreaker
    bool public active;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the breaker with its launch settings (25% threshold, 3 calm blocks).
     * @param pip_ Address of the Oracle Security Module to watch.
     * @param ilkId_ Identifier of the collateral type to watch.
     */
    constructor(IOracleSecurityModule pip_, bytes32 ilkId_) {
        _setRoleAdmin(_WARD_ROLE, _WARD_ROLE);
        _grantRole(_WARD_ROLE, msg.sender);

        PIP = pip_;
        ILK_ID = ilkId_;

        threshold = _WAD / 4;
        calmBlocks = 3;
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc ICircuitBreaker
     */
    function file(bytes32 what, uint256 data) external onlyRole(_WARD_ROLE) {
        if (what == "threshold") {
            threshold = data;
        } else if (what == "calmBlocks") {
            calmBlocks = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, data: data });
    }

    /**
     * @inheritdoc ICircuitBreaker
     */
    function check() external {
        (bytes32 val, bool has) = PIP.peek(ILK_ID);

        if (!has) {
            return;
        }

        uint256 currentPrice = uint256(val);

        // Refreshing the trend anchor once the window has fully elapsed.
        if (trendTimestamp == 0 || block.timestamp - trendTimestamp >= TREND_WINDOW) {
            trendPrice = currentPrice;
            trendTimestamp = block.timestamp;
        }

        // Comparing the current delayed price to the one-hour trend.
        uint256 deviation = _deviation(currentPrice, trendPrice);

        if (deviation > threshold) {
            // The move is too large too fast: activate and reset the calm counter.
            if (!active) {
                active = true;

                emit Activated({ deviation: deviation });
            }

            calmCount = 0;
        } else if (active && block.number != lastCheckedBlock) {
            // Counting consecutive calm blocks toward deactivation.
            ++calmCount;

            if (calmCount >= calmBlocks) {
                active = false;
                calmCount = 0;

                emit Deactivated();
            }
        }

        lastCheckedBlock = block.number;

        emit Checked({ deviation: deviation, active: active });
    }

    /* ========================== INTERNAL FUNCTIONS ========================== */

    /**
     * @dev Returns the relative deviation between two prices [wad].
     * @param current The current price [wad].
     * @param trend The trend anchor price [wad].
     * @return The relative deviation [wad].
     */
    function _deviation(uint256 current, uint256 trend) internal pure returns (uint256) {
        if (trend == 0) {
            return 0;
        }

        uint256 diff = current > trend ? current - trend : trend - current;

        return (diff * _WAD) / trend;
    }
}
