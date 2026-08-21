// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AerodromeAdapter, IAerodromeRouter} from "../../src/adapters/AerodromeAdapter.sol";
import {MockUSDC, MockERC20} from "../mocks/Mocks.sol";

/// @dev Minimal Aerodrome Router mock: records call shape, enforces V2-style transfer semantics.
contract MockAerodrome {
    struct LastSwap {
        uint256 amountIn;
        uint256 amountOutMin;
        IAerodromeRouter.Route[] routes;
        address to;
        uint256 deadline;
    }
    struct LastLp {
        address tokenA;
        address tokenB;
        uint256 desiredA;
        uint256 desiredB;
        uint256 minA;
        uint256 minB;
        bool stable;
        address to;
    }

    LastSwap private _lastSwap;
    LastLp private _lastLp;

    function lastSwap() external view returns (
        uint256 amountIn, uint256 amountOutMin,
        IAerodromeRouter.Route[] memory routes, address to, uint256 deadline
    ) {
        return (_lastSwap.amountIn, _lastSwap.amountOutMin, _lastSwap.routes, _lastSwap.to, _lastSwap.deadline);
    }

    function lastLp() external view returns (
        address tokenA, address tokenB,
        uint256 desiredA, uint256 desiredB,
        uint256 minA, uint256 minB,
        bool stable, address to
    ) {
        return (_lastLp.tokenA, _lastLp.tokenB, _lastLp.desiredA, _lastLp.desiredB, _lastLp.minA, _lastLp.minB, _lastLp.stable, _lastLp.to);
    }
    MockUSDC public usdc;
    MockERC20 public nut;

    constructor(address usdc_, address nut_) { usdc = MockUSDC(usdc_); nut = MockERC20(nut_); }

    function swapExactTokensForTokens(
        uint256 amountIn, uint256 amountOutMin,
        IAerodromeRouter.Route[] calldata routes, address to, uint256 deadline
    ) external returns (uint256[] memory amounts) {
        usdc.transferFrom(msg.sender, address(this), amountIn);
        nut.mint(to, amountIn * 2);
        delete _lastSwap;
        for (uint256 i = 0; i < routes.length; i++) _lastSwap.routes.push(routes[i]);
        _lastSwap.amountIn = amountIn;
        _lastSwap.amountOutMin = amountOutMin;
        _lastSwap.to = to;
        _lastSwap.deadline = deadline;
        amounts = new uint256[](routes.length + 1);
    }

    function addLiquidity(
        address tokenA, address tokenB,
        uint256 amountADesired, uint256 amountBDesired,
        uint256 amountAMin, uint256 amountBMin,
        bool stable, address to, uint256
    ) external returns (uint256, uint256, uint256) {
        uint256 a = (amountADesired * 95) / 100;
        uint256 b = (amountBDesired * 95) / 100;
        require(a >= amountAMin && b >= amountBMin, "MIN");
        MockERC20(tokenA).transferFrom(msg.sender, address(this), a);
        MockERC20(tokenB).transferFrom(msg.sender, address(this), b);
        _lastLp = LastLp(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin, stable, to);
        return (a, b, a * b / 1e12);
    }
}

contract AerodromeAdapterTest is Test {
    MockUSDC usdc;
    MockERC20 nut;
    MockAerodrome aero;
    AerodromeAdapter adapter;
    address factory = makeAddr("factory");

    function setUp() public {
        usdc = new MockUSDC();
        nut = new MockERC20("NUT", "NUT");
        aero = new MockAerodrome(address(usdc), address(nut));
        adapter = new AerodromeAdapter(address(aero), factory);

        usdc.mint(address(this), 100e6);
        usdc.approve(address(adapter), type(uint256).max);
        nut.approve(address(adapter), type(uint256).max);
    }

    function test_Swap_TranslatesRouteAndResetsAllowance() public {
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(nut);

        uint256[] memory amounts = adapter.swapExactTokensForTokens(
            10e6, 15e6, path, address(this), block.timestamp + 60
        );

        (, , IAerodromeRouter.Route[] memory routes, , ) = aero.lastSwap();
        assertEq(routes.length, 1);
        assertEq(routes[0].from, address(usdc));
        assertEq(routes[0].to, address(nut));
        assertFalse(routes[0].stable);
        assertEq(routes[0].factory, factory);

        assertEq(usdc.allowance(address(adapter), address(aero)), 0);
        assertEq(nut.balanceOf(address(this)), 20e6);
        assertEq(amounts.length, 2);
    }

    function test_Swap_RejectsMultihop() public {
        address[] memory path = new address[](3);
        vm.expectRevert("SINGLE_HOP_ONLY");
        adapter.swapExactTokensForTokens(10e6, 1, path, address(this), block.timestamp + 60);
    }

    function test_AddLiquidity_VolatileAndAllowanceReset() public {
        nut.mint(address(this), 100e18);
        (uint256 a, uint256 b, uint256 liq) = adapter.addLiquidity(
            address(usdc), address(nut), 10e6, 30e18, 9e6, 25e18, address(this), block.timestamp + 60
        );

        (, , , , , , bool stable, address lpTo) = aero.lastLp();
        assertFalse(stable, "wNUT/NUT must be volatile");
        assertEq(lpTo, address(this));

        assertEq(usdc.allowance(address(adapter), address(aero)), 0);
        assertEq(nut.allowance(address(adapter), address(aero)), 0);

        assertEq(a, 9.5e6);
        assertEq(b, 28.5e18);
        assertGt(liq, 0);
    }

    function test_Ctor_RejectsZeroAddress() public {
        vm.expectRevert(bytes("ZERO"));
        new AerodromeAdapter(address(0), factory);
    }
}
