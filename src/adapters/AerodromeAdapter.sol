// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISwapRouter, IAddLiquidityRouter} from "../interfaces/ISwapRouter.sol";

/// @dev Aerodrome Router shapes (subset used here).
interface IAerodromeRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        bool stable,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}

/**
 * @title AerodromeAdapter — production venue adapter
 * @notice Implements ISwapRouter + IAddLiquidityRouter against Aerodrome's Router.
 *
 *         Flow per action: pull exact desired amounts from the caller, approve
 *         Aerodrome for exactly those amounts, execute, reset allowances, and
 *         refund any unconsumed residual to the caller. Nothing is ever left
 *         stranded in this adapter.
 *
 *         Swaps execute as single-hop volatile routes; LP is added as a volatile
 *         (stable=false) pool. Return values are passed through for convenience
 *         only — FeeRouter performs its own balance-delta accounting and never
 *         trusts them.
 */
contract AerodromeAdapter is ISwapRouter, IAddLiquidityRouter {
    using SafeERC20 for IERC20;

    IAerodromeRouter public immutable aerodrome;
    address public immutable aeroFactory;

    constructor(address aerodrome_, address aeroFactory_) {
        require(aerodrome_ != address(0) && aeroFactory_ != address(0), "ZERO");
        require(aerodrome_.code.length > 0, "NO_CODE");
        aerodrome = IAerodromeRouter(aerodrome_);
        aeroFactory = aeroFactory_;
    }

    /// @inheritdoc ISwapRouter
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        require(path.length == 2, "SINGLE_HOP_ONLY");

        IERC20 input = IERC20(path[0]);
        input.safeTransferFrom(msg.sender, address(this), amountIn);

        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
        routes[0] = IAerodromeRouter.Route({
            from: path[0],
            to: path[1],
            stable: false,
            factory: aeroFactory
        });

        input.forceApprove(address(aerodrome), amountIn);
        amounts = aerodrome.swapExactTokensForTokens(amountIn, amountOutMin, routes, to, deadline);
        input.forceApprove(address(aerodrome), 0);

        // Defensive: refund any unconsumed input (exact-in should consume all).
        uint256 leftover = input.balanceOf(address(this));
        if (leftover > 0) input.safeTransfer(msg.sender, leftover);
    }

    /// @inheritdoc IAddLiquidityRouter
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        IERC20 a = IERC20(tokenA);
        IERC20 b = IERC20(tokenB);

        a.safeTransferFrom(msg.sender, address(this), amountADesired);
        b.safeTransferFrom(msg.sender, address(this), amountBDesired);

        a.forceApprove(address(aerodrome), amountADesired);
        b.forceApprove(address(aerodrome), amountBDesired);

        (amountA, amountB, liquidity) = aerodrome.addLiquidity(
            tokenA, tokenB, amountADesired, amountBDesired,
            amountAMin, amountBMin, false, to, deadline // volatile pool
        );

        a.forceApprove(address(aerodrome), 0);
        b.forceApprove(address(aerodrome), 0);

        // Refund unconsumed residuals to the caller — never strand in the adapter.
        uint256 leftA = a.balanceOf(address(this));
        if (leftA > 0) a.safeTransfer(msg.sender, leftA);
        uint256 leftB = b.balanceOf(address(this));
        if (leftB > 0) b.safeTransfer(msg.sender, leftB);
    }
}
