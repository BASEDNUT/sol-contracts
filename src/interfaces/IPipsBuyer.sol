// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @dev Adapter seam for the PIPS minting leg.
 *
 * RESEARCH STATUS (2026-08-19):
 *   PIPS (0x3f23...8ad9) is NOT on the classic Virtuals Fun bonding curve.
 *   Token has NO buy()/sell(). Curve logic lives in Factory 0x488Db0978b34C6Fd901760b9024B565C1117c7c8
 *   (impl 0xc81844668fc9ec385b477848171a014a5aba1b6a — source UNVERIFIED on Basescan/Blockscout).
 *   ABI errors indicate the newer ACF (Agent Capital Formation) auction model.
 *   Exact buy calldata: PENDING verification (decompile or official ACF ABIs).
 *
 * Until verified, FeeRouter calls this adapter interface. Swap the adapter
 * implementation when exact ACF entry points are confirmed — FeeRouter stays stable.
 */
interface IPipsBuyer {
    /**
     * @notice Convert USDC into freshly minted PIPS from the Virtuals curve/auction.
     * @dev Adapter must pull exactly `usdcAmount` from caller (already approved).
     *      Implementation handles USDC -> VIRTUAL -> PIPS internally.
     * @return pipsMinted amount of PIPS received.
     */
    function buyPips(uint256 usdcAmount) external returns (uint256 pipsMinted);
}
