// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { ICircuitBreaker } from "../interfaces/ICircuitBreaker.sol";
import { IOracleSecurityModule } from "../interfaces/IOracleSecurityModule.sol";
import { Auth } from "../shared/Auth.sol";
import { WAD, WARD_ROLE } from "../shared/Constants.sol";
import { UnrecognizedParameter } from "../shared/Errors.sol";
import { _revert } from "../shared/Globals.sol";

/**
 * @title CircuitBreaker.
 * @author Rain Team.
 * @notice A defense against price manipulation during liquidation. Watches how far the delayed
 *         price has moved from its recent trend. If the move is too large too fast, it throttles
 *         liquidations — slowing them, never freezing them — so a manipulated price cannot
 *         trigger a wave of unfair liquidations. It never touches ordinary vault operations.
 * @dev Custom to USDR. Activates when the delayed price deviates more than the threshold (25%)
 *      from the one-hour trend; deactivates after the deviation stays below the threshold for
 *      the required number of consecutive calm blocks (3).
 */
contract CircuitBreaker is ICircuitBreaker, Auth {
    /* ========================== STATE VARIABLES ========================== */

    /// @notice The Oracle Security Module being watched.
    IOracleSecurityModule public immutable pip;

    /// @notice Deviation threshold that activates the breaker [wad]. 25% = 0.25 * WAD.
    uint256 public threshold;

    /// @notice Consecutive calm blocks required to deactivate the breaker.
    uint256 public calmBlocks;

    /// @notice Whether the breaker is currently active.
    bool public active;

    /// @notice The one-hour trend anchor price [wad].
    uint256 public trendPrice;

    /// @notice Timestamp when the trend anchor was recorded.
    uint256 public trendTimestamp;

    /// @notice Number of consecutive calm blocks observed while active.
    uint256 public calmCount;

    /// @notice Last block in which the breaker was checked.
    uint256 public lastCheckedBlock;

    /// @notice Trend window in seconds (one hour).
    uint256 public constant TREND_WINDOW = 3600;

    /* ========================== CONSTRUCTOR ========================== */

    /**
     * @notice Initializes the breaker with its launch settings (25% threshold, 3 calm blocks).
     * @param pip_ Address of the Oracle Security Module to watch.
     */
    constructor(IOracleSecurityModule pip_) {
        pip = pip_;
        threshold = WAD / 4;
        calmBlocks = 3;

        _initAuth();
    }

    /* ========================== ADMINISTRATION ========================== */

    /**
     * @inheritdoc ICircuitBreaker
     */
    function file(bytes32 what, uint256 data) external onlyRole(WARD_ROLE) {
        if (what == "threshold") {
            threshold = data;
        } else if (what == "calmBlocks") {
            calmBlocks = data;
        } else {
            _revert(UnrecognizedParameter.selector);
        }

        emit File({ what: what, data: data });
    }

    /* ========================== FUNCTIONS ========================== */

    /**
     * @inheritdoc ICircuitBreaker
     */
    function check() external {
        (bytes32 val, bool has) = pip.peek();

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

    /* ========================== INTERNAL HELPERS ========================== */

    /// @dev Returns the relative deviation between two prices [wad].
    function _deviation(uint256 current, uint256 trend) internal pure returns (uint256) {
        if (trend == 0) {
            return 0;
        }

        uint256 diff = current > trend ? current - trend : trend - current;

        return (diff * WAD) / trend;
    }
}
