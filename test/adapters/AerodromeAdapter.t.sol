// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AerodromeAdapter, IAerodromeRouter} from "../../src/adapters/AerodromeAdapter.sol";
import {MockUSDC, MockERC20} from "../mocks/Mocks.sol";

/// @dev Minimal Aerodrome PoolFactory mock: configurable pool registry.
contract MockPoolFactory {
    mapping(bytes32 => address) private _pools;

    function setPool(address a, address b, bool stable, address pool) external {
        _pools[keccak256(abi.encode(a, b, stable))] = pool;
    }

    function getPool(address a, address b, bool stable) external view returns (address) {
        return _pools[keccak256(abi.encode(a, b, stable))];
    }
}

/// @dev Aerodrome Router mock with the CANONICAL argument order:
///      addLiquidity(tokenA, tokenB, stable, desiredA, desiredB, minA, minB, to, deadline).
///      The mock deliberately mirrors Aerodrome's deployed ABI, not the adapter's
///      expectations — if the adapter declares a wrong ABI, the selector mismatches
///      and the call reverts here (H-01 regression).
contract MockAerodrome {
    struct LastLp {
        address tokenA;
        address tokenB;
        bool stable;
        uint256 desiredA;
        uint256 desiredB;
        uint256 minA;
        uint256 minB;
        address to;
    }

    address public immutable defaultFactory;
    LastLp private _lastLp;

    MockUSDC public usdc;
    MockERC20 public nut;

    constructor(address usdc_, address nut_, address factory_) {
        usdc = MockUSDC(usdc_);
        nut = MockERC20(nut_);
        defaultFactory = factory_;
    }

    function lastLp()
        external
        view
        returns (
            address tokenA,
            address tokenB,
            bool stable,
            uint256 desiredA,
            uint256 desiredB,
            uint256 minA,
            uint256 minB,
            address to
        )
    {
        return (
            _lastLp.tokenA,
            _lastLp.tokenB,
            _lastLp.stable,
            _lastLp.desiredA,
            _lastLp.desiredB,
            _lastLp.minA,
            _lastLp.minB,
            _lastLp.to
        );
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        IAerodromeRouter.Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        require(routes.length == 1, "MOCK: single route");
        MockERC20(routes[0].from).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(routes[0].to).mint(to, amountIn * 2);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn * 2;
        amountOutMin;
        deadline;
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        // Consumes only 95% of desired — real AMM ratio behavior leaves residuals.
        amountA = (amountADesired * 95) / 100;
        amountB = (amountBDesired * 95) / 100;
        require(amountA >= amountAMin && amountB >= amountBMin, "MIN");
        MockERC20(tokenA).transferFrom(msg.sender, address(this), amountA);
        MockERC20(tokenB).transferFrom(msg.sender, address(this), amountB);
        _lastLp = LastLp(tokenA, tokenB, stable, amountADesired, amountBDesired, amountAMin, amountBMin, to);
        liquidity = (amountA * amountB) / 1e12;
    }
}

contract AerodromeAdapterTest is Test {
    MockUSDC usdc;
    MockERC20 nut;
    MockERC20 lpToken;
    MockAerodrome aero;
    MockPoolFactory factory;
    AerodromeAdapter adapter;

    function setUp() public {
        usdc = new MockUSDC();
        nut = new MockERC20("NUT", "NUT");
        lpToken = new MockERC20("Mock LP", "MLP");
        factory = new MockPoolFactory();
        aero = new MockAerodrome(address(usdc), address(nut), address(factory));

        // Canonical volatile pool for USDC/NUT lives at lpToken.
        factory.setPool(address(usdc), address(nut), false, address(lpToken));

        adapter = new AerodromeAdapter(address(aero), address(factory), address(lpToken), address(usdc), address(nut));

        usdc.mint(address(this), 1_000e6);
        nut.mint(address(this), 1_000e18);
        usdc.approve(address(adapter), type(uint256).max);
        nut.approve(address(adapter), type(uint256).max);
    }

    // ═══════════════ ABI LOCK (H-01 regression — forever) ═══════════════

    /// @dev Locks addLiquidity to Aerodrome's canonical signature. If anyone
    ///      reorders arguments (e.g. moves `stable`), the selector changes and
    ///      this test fails. Canonical: (address,address,bool,uint256,uint256,uint256,uint256,address,uint256).
    function test_AbiLock_AddLiquidityCanonicalSelector() public pure {
        bytes4 expected =
            bytes4(keccak256("addLiquidity(address,address,bool,uint256,uint256,uint256,uint256,address,uint256)"));
        assertEq(IAerodromeRouter.addLiquidity.selector, expected);
    }

    /// @dev Locks swapExactTokensForTokens to Aerodrome's canonical signature
    ///      with Route struct as tuple (address,address,bool,address).
    function test_AbiLock_SwapCanonicalSelector() public pure {
        bytes4 expected = bytes4(
            keccak256("swapExactTokensForTokens(uint256,uint256,(address,address,bool,address)[],address,uint256)")
        );
        assertEq(IAerodromeRouter.swapExactTokensForTokens.selector, expected);
    }

    // ═══════════════ CONSTRUCTOR BINDING (M-02) ═══════════════

    function test_Ctor_RejectsFactoryMismatch() public {
        MockPoolFactory wrongFactory = new MockPoolFactory();
        wrongFactory.setPool(address(usdc), address(nut), false, address(lpToken));
        MockAerodrome wrongAero = new MockAerodrome(address(usdc), address(nut), address(wrongFactory));
        vm.expectRevert(AerodromeAdapter.FactoryMismatch.selector);
        new AerodromeAdapter(address(wrongAero), address(factory), address(lpToken), address(usdc), address(nut));
    }

    function test_Ctor_RejectsNonCanonicalPool() public {
        MockERC20 impostor = new MockERC20("impostor", "IMP");
        // Factory says the real pool is the impostor, constructor binds lpToken.
        factory.setPool(address(usdc), address(nut), false, address(impostor));
        vm.expectRevert(AerodromeAdapter.NotCanonicalPool.selector);
        new AerodromeAdapter(address(aero), address(factory), address(lpToken), address(usdc), address(nut));
    }

    function test_Ctor_RejectsZeroAddress() public {
        vm.expectRevert(AerodromeAdapter.BadPair.selector);
        new AerodromeAdapter(address(0), address(factory), address(lpToken), address(usdc), address(nut));
    }

    // ═══════════════ SWAP ═══════════════

    function test_Swap_TranslatesRouteAndResetsAllowance() public {
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(nut);

        uint256 nutBefore = nut.balanceOf(address(this));
        uint256[] memory amounts =
            adapter.swapExactTokensForTokens(10e6, 15e6, path, address(this), block.timestamp + 60);

        // Route shape is not directly observable post-hoc; output proves execution.
        // setUp pre-mints NUT — assert via DELTA.
        assertEq(nut.balanceOf(address(this)) - nutBefore, 20e6);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.allowance(address(adapter), address(aero)), 0);
        assertEq(amounts.length, 2);
        assertEq(amounts[1], 20e6);
    }

    function test_Swap_RejectsMultihop() public {
        address[] memory path = new address[](3);
        vm.expectRevert(bytes("SINGLE_HOP_ONLY"));
        adapter.swapExactTokensForTokens(10e6, 1, path, address(this), block.timestamp + 60);
    }

    /// @dev M-01 regression: tokens donated to the adapter BEFORE a call must
    ///      never be refunded to the caller of a later legitimate call.
    function test_Swap_DoesNotRefundDonatedTokens() public {
        // Attacker/benefactor donates 100 USDC directly to the adapter.
        usdc.transfer(address(adapter), 100e6);

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(nut);

        // Legit caller swaps 10 USDC through the adapter.
        uint256 nutBefore = nut.balanceOf(address(this));
        adapter.swapExactTokensForTokens(10e6, 1, path, address(this), block.timestamp + 60);

        // Donation is untouched: adapter still holds the 100 USDC.
        assertEq(usdc.balanceOf(address(adapter)), 100e6, "donation must not be swept");
        // Caller received the swap output, nothing else.
        assertEq(nut.balanceOf(address(this)) - nutBefore, 20e6);
    }

    // ═══════════════ ADD LIQUIDITY ═══════════════

    function test_AddLiquidity_CanonicalOrderAndAllowanceReset() public {
        (uint256 a, uint256 b, uint256 liq) = adapter.addLiquidity(
            address(usdc), address(nut), 10e6, 30e18, 9e6, 25e18, address(this), block.timestamp + 60
        );

        // Mock (canonical ABI) received the call and recorded arguments.
        (address tA, address tB, bool stable, uint256 dA, uint256 dB,,, address lpTo) = aero.lastLp();
        assertEq(tA, address(usdc));
        assertEq(tB, address(nut));
        assertFalse(stable, "wNUT/NUT must be volatile");
        assertEq(dA, 10e6);
        assertEq(dB, 30e18);
        assertEq(lpTo, address(this));

        // Allowances reset.
        assertEq(usdc.allowance(address(adapter), address(aero)), 0);
        assertEq(nut.allowance(address(adapter), address(aero)), 0);

        // Mock consumes 95% of desired; residual refunded to caller (this call's delta only).
        assertEq(a, 9.5e6);
        assertEq(b, 28.5e18);
        assertGt(liq, 0);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(nut.balanceOf(address(adapter)), 0);
    }

    /// @dev M-01 regression: pre-donated tokens are never refunded by addLiquidity.
    function test_AddLiquidity_DoesNotRefundDonatedTokens() public {
        // Donate 50 NUT directly to the adapter.
        nut.transfer(address(adapter), 50e18);

        adapter.addLiquidity(address(usdc), address(nut), 10e6, 30e18, 1, 1, address(this), block.timestamp + 60);

        // Donation intact: 50e18 + nothing stranded. Mock consumed 95% of the
        // pulled 30e18, refunded 1.5e18 to the caller — the donation never moved.
        assertEq(nut.balanceOf(address(adapter)), 50e18, "donation must not be swept");
        assertEq(usdc.balanceOf(address(adapter)), 0);
    }

    /// @dev Pair binding: addLiquidity rejects any pair other than the bound pair.
    function test_AddLiquidity_RejectsUnboundPair() public {
        MockERC20 junk = new MockERC20("junk", "JNK");
        junk.mint(address(this), 100e18);
        junk.approve(address(adapter), type(uint256).max);
        vm.expectRevert(AerodromeAdapter.PairNotBound.selector);
        adapter.addLiquidity(address(junk), address(nut), 10e18, 10e18, 1, 1, address(this), block.timestamp + 60);
    }
}
