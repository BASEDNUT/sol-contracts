// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @dev Generic Uniswap-V2-style router seams (Aerodrome-compatible adapter expected).
 *      Venue finalization pending wNUT/NUT pool creation decision.
 */
interface ISwapRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IAddLiquidityRouter {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}
