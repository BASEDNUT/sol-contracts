// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeeRouter} from "../../src/router/FeeRouter.sol";
import {WNUT} from "../../src/wnut/WNUT.sol";
import {MockERC20, MockPipsBuyer, LyingPipsBuyer, MockSwapRouter, MockLpRouter, MockEAS, MockSchemaRegistry} from "../mocks/Mocks.sol";

contract FeeRouterTest is Test {
    FeeRouter public router;
    WNUT public wnut;
    MockERC20 public usdc;
    MockERC20 public nut;
    MockERC20 public pips;
    MockERC20 public lpToken;
    MockPipsBuyer public pipsBuyer;
    MockSwapRouter public swapRouter;
    MockLpRouter public lpRouter;
    MockEAS public eas;
    MockSchemaRegistry public registry;

    address public operator = makeAddr("operator");
    address public attacker = makeAddr("attacker");
    address public treasury = makeAddr("treasury");
    bytes32 constant PIPS_SCHEMA = keccak256("PIPS_SCHEMA");
    bytes32 constant LP_SCHEMA = keccak256("LP_SCHEMA");

    // mock rates: 1 USDC -> 2 PIPS, 1 USDC -> 3 NUT
    uint256 constant IN = 100e6;
    uint256 constant EXPECT_PIPS = 160e6; // 80e6 * 2
    uint256 constant EXPECT_NUT = 60e6;   // 20e6 * 3

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC");
        nut = new MockERC20("NUT", "NUT");
        pips = new MockERC20("PIPS", "PIPS");
        lpToken = new MockERC20("LP", "LP");
        wnut = new WNUT(address(nut));
        pipsBuyer = new MockPipsBuyer(address(usdc), address(pips));
        swapRouter = new MockSwapRouter(address(usdc), address(nut));
        lpRouter = new MockLpRouter();
        eas = new MockEAS();
        registry = new MockSchemaRegistry();
        registry.register(PIPS_SCHEMA);
        registry.register(LP_SCHEMA);

        router = new FeeRouter(
            address(usdc),
            address(nut),
            address(wnut),
            address(pips),
            address(pipsBuyer),
            address(swapRouter),
            address(lpRouter),
            address(eas),
            address(registry),
            address(lpToken),
            PIPS_SCHEMA,
            LP_SCHEMA,
            0,          // admin delay (tests)
            block.chainid
        );

        vm.startPrank(address(this));
        router.grantRole(router.OPERATOR_ROLE(), operator);
        router.revokeRole(router.OPERATOR_ROLE(), address(this));
        vm.stopPrank();
        usdc.mint(operator, 1_000_000e6);
    }

    function _bounds() internal view returns (uint256, uint256, uint256, uint256, uint256) {
        return (EXPECT_PIPS, EXPECT_NUT, EXPECT_NUT / 2, EXPECT_NUT / 2, block.timestamp + 300);
    }

    function _deploy(uint256 amount) internal returns (bytes32, bytes32) {
        (uint256 minPips, uint256 minNut, uint256 minW, uint256 minN, uint256 dl) = _bounds();
        vm.startPrank(operator);
        usdc.approve(address(router), amount);
        (bytes32 a, bytes32 b) = router.splitAndDeploy(amount, minPips, minNut, minW, minN, dl);
        vm.stopPrank();
        return (a, b);
    }

    // ═══════════════ HAPPY PATH ═══════════════

    function test_SplitAndDeploy_HappyPath() public {
        (bytes32 pipsUID, bytes32 lpUID) = _deploy(IN);
        assertTrue(eas.exists(pipsUID));
        assertTrue(eas.exists(lpUID));
        assertEq(router.totalUsdcProcessed(), IN);
        assertEq(router.totalUsdcToPips(), 80e6);
        assertEq(router.totalUsdcToLp(), 20e6);
        assertEq(router.totalPipsMinted(), EXPECT_PIPS);
        assertEq(router.totalLpAdded() > 0, true);
        // PIPS delivered to router (protocol custody)
        assertEq(pips.balanceOf(address(router)), EXPECT_PIPS);
    }

    // ═══════════════ H-01: SLIPPAGE BOUNDS ═══════════════

    function test_SwapSlippage_RevertsWhenRateDrops() public {
        swapRouter.setRate(2); // was 3 -> NUT out drops 1/3
        vm.prank(operator);
        usdc.approve(address(router), IN);
        (uint256 minPips, uint256 minNut, uint256 minW, uint256 minN, uint256 dl) = _bounds();
        vm.prank(operator);
        vm.expectRevert(FeeRouter.InsufficientNut.selector);
        router.splitAndDeploy(IN, minPips, minNut, minW, minN, dl);
    }

    function test_ZeroSlippageBound_Reverts() public {
        vm.prank(operator);
        usdc.approve(address(router), IN);
        vm.prank(operator);
        vm.expectRevert(FeeRouter.ZeroSlippageBound.selector);
        router.splitAndDeploy(IN, 0, EXPECT_NUT, EXPECT_NUT / 2, EXPECT_NUT / 2, block.timestamp + 300);
    }

    function test_DeadlineExpired_Reverts() public {
        vm.prank(operator);
        usdc.approve(address(router), IN);
        (, , , , uint256 dl) = _bounds();
        vm.warp(dl + 1);
        vm.prank(operator);
        vm.expectRevert(FeeRouter.DeadlineExpired.selector);
        router.splitAndDeploy(IN, EXPECT_PIPS, EXPECT_NUT, EXPECT_NUT / 2, EXPECT_NUT / 2, dl);
    }

    // ═══════════════ H-02: LYING ADAPTER ═══════════════

    function test_LyingPipsBuyer_Reverts() public {
        LyingPipsBuyer liar = new LyingPipsBuyer(address(usdc), address(pips));
        // redeploy router with liar
        FeeRouter r2 = new FeeRouter(
            address(usdc), address(nut), address(wnut), address(pips),
            address(liar), address(swapRouter), address(lpRouter),
            address(eas), address(registry), address(lpToken),
            PIPS_SCHEMA, LP_SCHEMA, 0, block.chainid
        );
        r2.grantRole(r2.OPERATOR_ROLE(), operator);
        usdc.mint(operator, IN);
        vm.startPrank(operator);
        usdc.approve(address(r2), IN);
        vm.expectRevert(FeeRouter.InsufficientPips.selector);
        r2.splitAndDeploy(IN, EXPECT_PIPS, EXPECT_NUT, EXPECT_NUT / 2, EXPECT_NUT / 2, block.timestamp + 300);
        vm.stopPrank();
    }

    // ═══════════════ H-03: PROTECTED TOKENS ═══════════════

    function test_RecoverDust_BlocksAllProtectedTokens() public {
        vm.expectRevert(FeeRouter.ProtectedToken.selector);
        router.recoverDust(address(usdc), treasury);
        vm.expectRevert(FeeRouter.ProtectedToken.selector);
        router.recoverDust(address(nut), treasury);
        vm.expectRevert(FeeRouter.ProtectedToken.selector);
        router.recoverDust(address(wnut), treasury);
        vm.expectRevert(FeeRouter.ProtectedToken.selector);
        router.recoverDust(address(pips), treasury);
        vm.expectRevert(FeeRouter.ProtectedToken.selector);
        router.recoverDust(address(lpToken), treasury);
    }

    function test_RecoverDust_WorksWithJunk() public {
        MockERC20 junk = new MockERC20("JUNK", "JUNK");
        junk.mint(address(router), 5e18);
        uint256 got = router.recoverDust(address(junk), treasury);
        assertEq(got, 5e18);
        assertEq(junk.balanceOf(treasury), 5e18);
    }

    function test_RescueUsdc_OnlyWhenPaused() public {
        usdc.mint(address(router), 50e6);
        vm.expectRevert(); // not paused
        router.rescueUsdc(treasury);
        router.pause();
        uint256 got = router.rescueUsdc(treasury);
        assertEq(got, 50e6);
        assertEq(usdc.balanceOf(treasury), 50e6);
    }

    function test_RecoverPips_PipsOnly() public {
        _deploy(IN);
        vm.expectRevert(); // attacker
        vm.prank(attacker);
        router.recoverPips(treasury);
        uint256 got = router.recoverPips(treasury);
        assertEq(got, EXPECT_PIPS);
        assertEq(pips.balanceOf(treasury), EXPECT_PIPS);
    }

    // ═══════════════ M-02: SINGLE AUTHORITY ═══════════════

    function test_AdminTransferIsTwoStepAndDelayed() public {
        router.beginDefaultAdminTransfer(operator);
        uint48 delay = router.defaultAdminDelay();
        vm.warp(block.timestamp + delay + 1);
        vm.prank(operator);
        router.acceptDefaultAdminTransfer();
        assertTrue(router.hasRole(router.DEFAULT_ADMIN_ROLE(), operator));
        assertFalse(router.hasRole(router.DEFAULT_ADMIN_ROLE(), address(this)));
    }
        function test_FormerAdminLosesAllPower() public {
        test_AdminTransferIsTwoStepAndDelayed();
        // former admin (this) tries admin action -> revert
        vm.expectRevert();
        router.setPipsBps(5000);
    }

    // ═══════════════ M-03: CTOR VALIDATION ═══════════════

    function test_Ctor_RevertsOnZeroAddress() public {
        vm.expectRevert(FeeRouter.BadDependency.selector);
        new FeeRouter(
            address(0), address(nut), address(wnut), address(pips),
            address(pipsBuyer), address(swapRouter), address(lpRouter),
            address(eas), address(registry), address(lpToken),
            PIPS_SCHEMA, LP_SCHEMA, 0, block.chainid
        );
    }

    function test_Ctor_RevertsOnChainMismatch() public {
        vm.expectRevert(FeeRouter.ChainMismatch.selector);
        new FeeRouter(
            address(usdc), address(nut), address(wnut), address(pips),
            address(pipsBuyer), address(swapRouter), address(lpRouter),
            address(eas), address(registry), address(lpToken),
            PIPS_SCHEMA, LP_SCHEMA, 0, block.chainid + 1
        );
    }

    function test_Ctor_RevertsOnUnknownSchema() public {
        vm.expectRevert(FeeRouter.SchemaNotFound.selector);
        new FeeRouter(
            address(usdc), address(nut), address(wnut), address(pips),
            address(pipsBuyer), address(swapRouter), address(lpRouter),
            address(eas), address(registry), address(lpToken),
            bytes32(uint256(1)), LP_SCHEMA, 0, block.chainid
        );
    }

    function test_Ctor_RevertsOnWrongWnutUnderlying() public {
        MockERC20 fakeNut = new MockERC20("FAKE", "FAKE");
        WNUT fakeWnut = new WNUT(address(fakeNut));
        vm.expectRevert(FeeRouter.BadDependency.selector);
        new FeeRouter(
            address(usdc), address(nut), address(fakeWnut), address(pips),
            address(pipsBuyer), address(swapRouter), address(lpRouter),
            address(eas), address(registry), address(lpToken),
            PIPS_SCHEMA, LP_SCHEMA, 0, block.chainid
        );
        // sanity: correct pairing works
        WNUT goodWnut = new WNUT(address(nut));
        new FeeRouter(
            address(usdc), address(nut), address(goodWnut), address(pips),
            address(pipsBuyer), address(swapRouter), address(lpRouter),
            address(eas), address(registry), address(lpToken),
            PIPS_SCHEMA, LP_SCHEMA, 0, block.chainid
        );
    }

    // ═══════════════ M-01: ALLOWANCE HYGIENE ═══════════════

    function test_AllowancesResetAfterRun() public {
        _deploy(IN);
        assertEq(usdc.allowance(address(router), address(pipsBuyer)), 0);
        assertEq(usdc.allowance(address(router), address(swapRouter)), 0);
        assertEq(nut.allowance(address(router), address(wnut)), 0);
        assertEq(nut.allowance(address(router), address(lpRouter)), 0);
        assertEq(IERC20(address(wnut)).allowance(address(router), address(lpRouter)), 0);
    }

    function test_SecondRunDoesNotSweepPreexistingBalances() public {
        _deploy(IN);
        // run 2: accounting must be exactly 2x, no pre-existing balance contamination
        (bytes32 a, bytes32 b) = _deploy(IN);
        assertTrue(eas.exists(a));
        assertTrue(eas.exists(b));
        assertEq(router.totalPipsMinted(), EXPECT_PIPS * 2);
        assertEq(router.totalUsdcProcessed(), IN * 2);
    }

    // ═══════════════ RBAC ═══════════════

    function test_OnlyOperator_CanCall() public {
        usdc.mint(attacker, IN);
        vm.startPrank(attacker);
        usdc.approve(address(router), IN);
        vm.expectRevert();
        (uint256 minPips, uint256 minNut, uint256 minW, uint256 minN, uint256 dl) = _bounds();
        router.splitAndDeploy(IN, minPips, minNut, minW, minN, dl);
        vm.stopPrank();
    }

    function test_ZeroAmount_Reverts() public {
        vm.prank(operator);
        vm.expectRevert(FeeRouter.ZeroAmount.selector);
        router.splitAndDeploy(0, 1, 1, 1, 1, block.timestamp + 300);
    }

    function test_Pause_Blocks() public {
        router.pause();
        vm.startPrank(operator);
        usdc.approve(address(router), IN);
        vm.expectRevert();
        (uint256 minPips, uint256 minNut, uint256 minW, uint256 minN, uint256 dl) = _bounds();
        router.splitAndDeploy(IN, minPips, minNut, minW, minN, dl);
        vm.stopPrank();
    }

    // ═══════════════ ADMIN ═══════════════

    function test_SetPipsBps() public {
        router.setPipsBps(5000);
        assertEq(router.pipsBps(), 5000);
    }

    function test_SetPipsBps_RevertsBadValue() public {
        vm.expectRevert(FeeRouter.BadSplit.selector);
        router.setPipsBps(0);
    }

    function test_SetSchemaUIDs_RejectsUnknown() public {
        vm.expectRevert(FeeRouter.SchemaNotFound.selector);
        router.setSchemaUIDs(bytes32(uint256(99)), LP_SCHEMA);
    }

    function test_SetSchemaUIDs_AcceptsKnown() public {
        bytes32 newPips = keccak256("NEW_PIPS");
        registry.register(newPips);
        router.setSchemaUIDs(newPips, LP_SCHEMA);
        assertEq(router.pipsSchemaUID(), newPips);
    }

    // ═══════════════ ATTESTATIONS ═══════════════

    function test_TwoAttestationsPerRun() public {
        _deploy(IN);
        assertEq(eas.attestCount(), 2);
    }
}
