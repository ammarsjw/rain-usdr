// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { IExternalExposure } from "../../contracts/interfaces/IExternalExposure.sol";

/**
 * @title MockExternalExposure
 * @author Rain Team
 * @notice Settable exposure reporter for tests. Can report any value or revert on demand.
 */
contract MockExternalExposure is IExternalExposure {
    uint256 public exposure;
    bool public shouldRevert;

    function setExposure(uint256 exposure_) external {
        exposure = exposure_;
    }

    function setShouldRevert(bool shouldRevert_) external {
        shouldRevert = shouldRevert_;
    }

    function reportedExposure() external view returns (uint256) {
        require(!shouldRevert, "MockExternalExposure: revert");

        return exposure;
    }
}
