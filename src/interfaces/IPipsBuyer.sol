// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @dev Adapter interface for PIPS purchases.
 *      Implementations handle USDC -> PIPS conversion internally.
 */
interface IPipsBuyer {
    /**
     * @notice Convert USDC into PIPS.
     * @dev Adapter must pull exactly `usdcAmount` from caller (already approved).
     * @return pipsMinted amount of PIPS received.
     */
    function buyPips(uint256 usdcAmount) external returns (uint256 pipsMinted);
}
