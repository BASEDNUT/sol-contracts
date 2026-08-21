// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISwapRouter, IAddLiquidityRouter} from "../interfaces/ISwapRouter.sol";

/// @dev Canonical Aerodrome Router interface (subset). addLiquidity argument
///      order matches Aerodrome exactly: (tokenA, tokenB, stable, desiredA,
///      desiredB, minA, minB, to, deadline).
interface IAerodromeRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function defaultFactory() external view returns (address);

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
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}

/// @dev Aerodrome PoolFactory canonical pool lookup.
interface IPoolFactory {
    function getPool(address tokenA, address tokenB, bool stable) external view returns (address pool);
}

/**
 * @title AerodromeAdapter — production venue adapter
 * @notice Implements ISwapRouter + IAddLiquidityRouter against Aerodrome's Router.
 *
 *         Binding guarantees (enforced at construction):
 *         - aeroFactory MUST equal the router's own defaultFactory(), so swap
 *           routes and liquidity provisioning always target the same factory.
 *         - lpToken MUST equal PoolFactory.getPool(tokenA, tokenB, false) — the
 *           canonical volatile pool for the bound pair. addLiquidity rejects
 *           any token pair other than the bound pair.
 *
 *         Flow per action: snapshot balances, pull exact desired amounts from
 *         the caller, approve Aerodrome for exactly those amounts, execute,
 *         reset allowances, and refund only the balance delta contributed by
 *         THIS call. Tokens already sitting in the adapter (e.g. accidental
 *         direct transfers) are never swept into a refund.
 *
 *         Swaps execute as single-hop volatile routes. LP is added as volatile
 *         (stable=false). Return values are passed through for convenience
 *         only — FeeRouter performs its own balance-delta accounting and never
 *         trusts them.
 */
contract AerodromeAdapter is ISwapRouter, IAddLiquidityRouter {
    using SafeERC20 for IERC20;

    IAerodromeRouter public immutable aerodrome;
    address public immutable aeroFactory;
    address public immutable boundPool;   // canonical volatile pool for the bound pair
    address public immutable boundTokenA;
    address public immutable boundTokenB;

    error FactoryMismatch();
    error NotCanonicalPool();
    error PairNotBound();
    error BadPair();

    constructor(
        address aerodrome_,
        address aeroFactory_,
        address lpToken_,
        address tokenA_,
        address tokenB_
    ) {
        if (
            aerodrome_ == address(0) || aeroFactory_ == address(0) || lpToken_ == address(0)
                || tokenA_ == address(0) || tokenB_ == address(0) || tokenA_ == tokenB_
        ) revert BadPair();
        if (
            aerodrome_.code.length == 0 || aeroFactory_.code.length == 0
                || lpToken_.code.length == 0
        ) revert BadPair();

        // Swap routes and addLiquidity must target the same factory's pools.
        if (IAerodromeRouter(aerodrome_).defaultFactory() != aeroFactory_) revert FactoryMismatch();
        // LP token must be the canonical factory-derived volatile pool.
        if (IPoolFactory(aeroFactory_).getPool(tokenA_, tokenB_, false) != lpToken_) {
            revert NotCanonicalPool();
        }

        aerodrome = IAerodromeRouter(aerodrome_);
        aeroFactory = aeroFactory_;
        boundPool = lpToken_;
        boundTokenA = tokenA_;
        boundTokenB = tokenB_;
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
        // Refund base: only the delta contributed by THIS call is ever refunded.
        uint256 balBefore = input.balanceOf(address(this));

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

        uint256 leftover = input.balanceOf(address(this)) - balBefore;
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
        if (
            !((tokenA == boundTokenA && tokenB == boundTokenB)
                || (tokenA == boundTokenB && tokenB == boundTokenA))
        ) revert PairNotBound();

        IERC20 a = IERC20(tokenA);
        IERC20 b = IERC20(tokenB);
        // Refund base: only the delta contributed by THIS call is ever refunded.
        uint256 balABefore = a.balanceOf(address(this));
        uint256 balBBefore = b.balanceOf(address(this));

        a.safeTransferFrom(msg.sender, address(this), amountADesired);
        b.safeTransferFrom(msg.sender, address(this), amountBDesired);

        a.forceApprove(address(aerodrome), amountADesired);
        b.forceApprove(address(aerodrome), amountBDesired);

        (amountA, amountB, liquidity) = aerodrome.addLiquidity(
            tokenA, tokenB, false, amountADesired, amountBDesired, amountAMin, amountBMin, to, deadline
        );

        a.forceApprove(address(aerodrome), 0);
        b.forceApprove(address(aerodrome), 0);

        uint256 leftA = a.balanceOf(address(this)) - balABefore;
        if (leftA > 0) a.safeTransfer(msg.sender, leftA);
        uint256 leftB = b.balanceOf(address(this)) - balBBefore;
        if (leftB > 0) b.safeTransfer(msg.sender, leftB);
    }
}
