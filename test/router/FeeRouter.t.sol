// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FeeRouter} from "../../src/router/FeeRouter.sol";
import {WNUT} from "../../src/wnut/WNUT.sol";
import {MockERC20, MockPipsBuyer, MockSwapRouter, MockLpRouter, MockEAS} from "../mocks/Mocks.sol";

contract FeeRouterTest is Test {
    FeeRouter public router;
    WNUT public wnut;
    MockERC20 public usdc;
    MockERC20 public nut;
    MockERC20 public pips;
    MockPipsBuyer public pipsBuyer;
    MockSwapRouter public swapRouter;
    MockLpRouter public lpRouter;
    MockEAS public eas;

    address public operator = makeAddr("operator");
    address public attacker = makeAddr("attacker");
    bytes32 constant PIPS_SCHEMA = keccak256("PIPS_SCHEMA");
    bytes32 constant LP_SCHEMA = keccak256("LP_SCHEMA");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC");
        nut = new MockERC20("NUT", "NUT");
        pips = new MockERC20("PIPS", "PIPS");
        wnut = new WNUT(address(nut));
        pipsBuyer = new MockPipsBuyer(address(usdc), address(pips));
        swapRouter = new MockSwapRouter(address(usdc), address(nut));
        lpRouter = new MockLpRouter();
        eas = new MockEAS();

        router = new FeeRouter(
            address(usdc),
            address(nut),
            address(wnut),
            address(pipsBuyer),
            address(swapRouter),
            address(lpRouter),
            address(eas),
            PIPS_SCHEMA,
            LP_SCHEMA
        );

        router.grantRole(router.OPERATOR_ROLE(), operator);
        usdc.mint(operator, 1_000_000e6);
    }

    // ── Happy path ──
    function test_SplitAndDeploy_HappyPath() public {
        vm.startPrank(operator);
        usdc.approve(address(router), 100e6);
        (bytes32 pipsUID, bytes32 lpUID) = router.splitAndDeploy(100e6);
        vm.stopPrank();

        assertTrue(eas.exists(pipsUID));
        assertTrue(eas.exists(lpUID));
        assertEq(router.totalUsdcProcessed(), 100e6);
        assertEq(router.totalUsdcToPips(), 80e6);
        assertEq(router.totalUsdcToLp(), 20e6);
        // pips rate 2:1 -> 160 PIPS
        assertEq(router.totalPipsMinted(), 160e6); // mock raw units
        // usdc->nut rate 3:1 -> 60 NUT bought, 30 wrapped
        assertGt(router.totalLpAdded(), 0);
    }

    // ── Split math ──
    function test_Split_IsExactly8020() public view {
        assertEq(router.pipsBps(), 8000);
    }

    // ── RBAC ──
    function test_OnlyOperator_CanCall() public {
        usdc.mint(attacker, 100e6);
        vm.startPrank(attacker);
        usdc.approve(address(router), 100e6);
        vm.expectRevert();
        router.splitAndDeploy(100e6);
        vm.stopPrank();
    }

    // ── Edge cases ──
    function test_RevertOnZero() public {
        vm.prank(operator);
        vm.expectRevert(FeeRouter.ZeroAmount.selector);
        router.splitAndDeploy(0);
    }

    // ── Pause ──
    function test_Pause_Blocks() public {
        router.pause();
        vm.startPrank(operator);
        usdc.approve(address(router), 100e6);
        vm.expectRevert();
        router.splitAndDeploy(100e6);
        vm.stopPrank();
    }

    // ── Admin ──
    function test_SetPipsBps() public {
        router.setPipsBps(5000);
        assertEq(router.pipsBps(), 5000);
    }

    function test_SetPipsBps_RevertsBadValue() public {
        vm.expectRevert(FeeRouter.BadSplit.selector);
        router.setPipsBps(0);
    }

    // ── Attestation payload ──
    function test_TwoAttestationsPerRun() public {
        vm.startPrank(operator);
        usdc.approve(address(router), 100e6);
        router.splitAndDeploy(100e6);
        vm.stopPrank();
        assertEq(eas.attestCount(), 2);
    }
}
