// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FeeRouter} from "../../src/router/FeeRouter.sol";
import {WNUT} from "../../src/wnut/WNUT.sol";
import {ISchemaResolver} from "@eas/contracts/resolver/ISchemaResolver.sol";

import {
    MockUSDC,
    MockERC20,
    MockPair,
    MockSchemaRegistry,
    MockEAS,
    MockPipsBuyer,
    LyingPipsBuyer,
    StingyPipsBuyer,
    MockSwapRouter,
    LyingSwapRouter,
    MockLpRouter,
    SparingLpRouter,
    LyingLpRouter
} from "../mocks/Mocks.sol";

contract FeeRouterTest is Test {
    string constant PIPS_DEF =
        "string action,address caller,uint256 usdcTotal,uint256 usdcToPips,uint256 pipsMinted,uint256 timestamp";
    string constant LP_DEF =
        "string action,address caller,uint256 usdcTotal,uint256 usdcToLp,uint256 nutBought,uint256 liquidity,uint256 timestamp";

    MockUSDC usdc;
    MockERC20 nut;
    WNUT wnut;
    MockERC20 pips;
    MockPipsBuyer pipsBuyer;
    MockSwapRouter swapRouter;
    MockLpRouter lpRouter;
    MockSchemaRegistry registry;
    MockEAS eas;
    MockPair pair;
    FeeRouter router;

    address treasury = makeAddr("treasury");
    address attacker = makeAddr("attacker");

    bytes32 pipsUID_;
    bytes32 lpUID_;

    uint256 constant AMOUNT = 100e6;
    uint256 constant MAX_RUN = 1_000_000e6;
    uint256 constant HORIZON = 3600;

    function setUp() public {
        usdc = new MockUSDC();
        nut = new MockERC20("NUT", "NUT");
        wnut = new WNUT(address(nut));
        pips = new MockERC20("PIPS", "PIPS");
        registry = new MockSchemaRegistry();
        eas = new MockEAS(address(registry));
        pipsBuyer = new MockPipsBuyer(address(usdc), address(pips));
        swapRouter = new MockSwapRouter(address(usdc), address(nut));
        pair = new MockPair(address(wnut), address(nut));
        lpRouter = new MockLpRouter(pair);

        pipsUID_ = registry.register(PIPS_DEF, ISchemaResolver(address(0)), false);
        lpUID_ = registry.register(LP_DEF, ISchemaResolver(address(0)), false);

        router = _deploy(0);

        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(router), type(uint256).max);
    }

    function _deploy(uint48 adminDelay) internal returns (FeeRouter) {
        return new FeeRouter(
            address(usdc), address(nut), address(wnut), address(pips),
            address(pipsBuyer), address(swapRouter), address(lpRouter),
            address(eas), address(registry), address(pair),
            pipsUID_, lpUID_, adminDelay, block.chainid, MAX_RUN, HORIZON
        );
    }

    function _run() internal returns (bytes32, bytes32) {
        return router.splitAndDeploy(AMOUNT, 150e18, 55e18, 29e18, 29e18, 8e26, block.timestamp + 1800);
    }

    function _runOn(FeeRouter fr) internal returns (bytes32, bytes32) {
        usdc.approve(address(fr), type(uint256).max);
        return fr.splitAndDeploy(AMOUNT, 150e18, 55e18, 29e18, 29e18, 8e26, block.timestamp + 1800);
    }

    // ═══════════════ HAPPY PATH ═══════════════

    function test_SplitAndDeploy_HappyPath() public {
        (bytes32 p, bytes32 l) = _run();
        assertGt(uint256(p), 0);
        assertGt(uint256(l), 0);

        assertEq(router.totalUsdcProcessed(), 100e6);
        assertEq(router.totalUsdcToPips(), 80e6);
        assertEq(router.totalUsdcToLp(), 20e6);

        assertEq(router.totalPipsMinted(), 160e18);
        assertEq(router.totalLpAdded(), 9e26);
        assertEq(pips.balanceOf(address(router)), 160e18);
        assertEq(pair.balanceOf(address(router)), 9e26);

        (uint256 u, uint256 w, uint256 n) = router.residuals();
        assertEq(u, 0);
        assertEq(w, 0);
        assertEq(n, 0);
    }

    function test_TwoAttestationsPerRun() public {
        (bytes32 p, bytes32 l) = _run();
        assertEq(eas.attestCount(), 2);
        assertTrue(eas.exists(p));
        assertTrue(eas.exists(l));
        assertNotEq(p, l);
    }

    // ═══════════════ SLIPPAGE / BOUNDS ═══════════════

    function test_SwapSlippage_RevertsWhenRateDrops() public {
        swapRouter.setRate(1e12);
        vm.expectRevert(FeeRouter.InsufficientNut.selector);
        _run();
    }

    function test_ZeroSlippageBound_Reverts() public {
        vm.expectRevert(FeeRouter.ZeroSlippageBound.selector);
        router.splitAndDeploy(AMOUNT, 0, 55e18, 29e18, 29e18, 8e26, block.timestamp + 1800);
    }

    function test_DeadlineExpired_Reverts() public {
        vm.expectRevert(FeeRouter.DeadlineExpired.selector);
        router.splitAndDeploy(AMOUNT, 150e18, 55e18, 29e18, 29e18, 8e26, block.timestamp - 1);
    }

    function test_DeadlineTooFar_Reverts() public {
        vm.expectRevert(FeeRouter.DeadlineTooFar.selector);
        router.splitAndDeploy(AMOUNT, 150e18, 55e18, 29e18, 29e18, 8e26, block.timestamp + HORIZON + 1);
    }

    function test_AmountAboveCap_Reverts() public {
        vm.expectRevert(FeeRouter.AmountTooLarge.selector);
        router.splitAndDeploy(MAX_RUN + 1, 150e18, 55e18, 29e18, 29e18, 8e26, block.timestamp + 60);
    }

    function test_ZeroAmount_Reverts() public {
        vm.expectRevert(FeeRouter.ZeroAmount.selector);
        router.splitAndDeploy(0, 150e18, 55e18, 29e18, 29e18, 8e26, block.timestamp + 60);
    }

    // ═══════════════ ADVERSARIAL ADAPTERS ═══════════════

    function test_LyingPipsBuyer_Reverts() public {
        LyingPipsBuyer liar = new LyingPipsBuyer(address(usdc), address(pips));
        FeeRouter bad = new FeeRouter(
            address(usdc), address(nut), address(wnut), address(pips),
            address(liar), address(swapRouter), address(lpRouter),
            address(eas), address(registry), address(pair),
            pipsUID_, lpUID_, 0, block.chainid, MAX_RUN, HORIZON
        );
        usdc.approve(address(bad), type(uint256).max);
        vm.expectRevert(FeeRouter.InsufficientPips.selector);
        bad.splitAndDeploy(AMOUNT, 150e18, 55e18, 29e18, 29e18, 8e26, block.timestamp + 1800);
    }

    function test_StingyPipsBuyer_AccountingMeasuresActualSpend() public {
        StingyPipsBuyer stingy = new StingyPipsBuyer(address(usdc), address(pips));
        FeeRouter fr = new FeeRouter(
            address(usdc), address(nut), address(wnut), address(pips),
            address(stingy), address(swapRouter), address(lpRouter),
            address(eas), address(registry), address(pair),
            pipsUID_, lpUID_, 0, block.chainid, MAX_RUN, HORIZON
        );
        usdc.approve(address(fr), type(uint256).max);
        fr.splitAndDeploy(AMOUNT, 150e18, 55e18, 29e18, 29e18, 8e26, block.timestamp + 1800);

        assertEq(fr.totalUsdcToPips(), 40e6, "must measure actual USDC consumed");
        assertEq(fr.totalUsdcToLp(), 20e6);
        assertEq(fr.totalUsdcProcessed(), 100e6);
        (uint256 u, , ) = fr.residuals();
        assertEq(u, 40e6);
    }

    function test_LyingSwapRouter_Reverts() public {
        LyingSwapRouter liar = new LyingSwapRouter(address(usdc), address(nut));
        FeeRouter bad = new FeeRouter(
            address(usdc), address(nut), address(wnut), address(pips),
            address(pipsBuyer), address(liar), address(lpRouter),
            address(eas), address(registry), address(pair),
            pipsUID_, lpUID_, 0, block.chainid, MAX_RUN, HORIZON
        );
        usdc.approve(address(bad), type(uint256).max);
        vm.expectRevert(FeeRouter.InsufficientNut.selector);
        bad.splitAndDeploy(AMOUNT, 150e18, 55e18, 29e18, 29e18, 8e26, block.timestamp + 1800);
    }

    function test_LyingLpRouter_Reverts() public {
        LyingLpRouter liar = new LyingLpRouter();
        FeeRouter bad = new FeeRouter(
            address(usdc), address(nut), address(wnut), address(pips),
            address(pipsBuyer), address(swapRouter), address(liar),
            address(eas), address(registry), address(pair),
            pipsUID_, lpUID_, 0, block.chainid, MAX_RUN, HORIZON
        );
        usdc.approve(address(bad), type(uint256).max);
        vm.expectRevert(FeeRouter.InsufficientLiquidity.selector);
        bad.splitAndDeploy(AMOUNT, 150e18, 55e18, 29e18, 29e18, 8e26, block.timestamp + 1800);
    }

    function test_SparingLpRouter_ResidualsCarriedAndAccounted() public {
        SparingLpRouter sparing = new SparingLpRouter(pair);
        FeeRouter fr = new FeeRouter(
            address(usdc), address(nut), address(wnut), address(pips),
            address(pipsBuyer), address(swapRouter), address(sparing),
            address(eas), address(registry), address(pair),
            pipsUID_, lpUID_, 0, block.chainid, MAX_RUN, HORIZON
        );
        usdc.approve(address(fr), type(uint256).max);

        vm.expectEmit(true, true, true, true, address(fr));
        emit FeeRouter.ResidualsCarried(0, 3e18, 3e18);
        fr.splitAndDeploy(AMOUNT, 150e18, 55e18, 26e18, 26e18, 7e26, block.timestamp + 1800);

        assertEq(fr.totalLpAdded(), 7.29e26);
        (uint256 u, uint256 w, uint256 n) = fr.residuals();
        assertEq(u, 0);
        assertEq(w, 3e18);
        assertEq(n, 3e18);
    }

    // ═══════════════ ACCESS CONTROL ═══════════════

    function test_OnlyOperator_CanCall() public {
        vm.prank(attacker);
        vm.expectRevert();
        router.splitAndDeploy(AMOUNT, 150e18, 55e18, 29e18, 29e18, 8e26, block.timestamp + 1800);
    }

    function test_Pause_Blocks() public {
        router.pause();
        vm.expectRevert();
        _run();
    }

    function test_AdminTransferIsTwoStepAndDelayed() public {
        FeeRouter delayed = _deploy(3 days);
        delayed.beginDefaultAdminTransfer(treasury);
        vm.prank(treasury);
        vm.expectRevert();
        delayed.acceptDefaultAdminTransfer();
        vm.warp(block.timestamp + 3 days + 2 seconds);
        vm.prank(treasury);
        delayed.acceptDefaultAdminTransfer();
        assertTrue(delayed.hasRole(delayed.DEFAULT_ADMIN_ROLE(), treasury));
        assertFalse(delayed.hasRole(delayed.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function test_FormerAdminLosesAllPower() public {
        FeeRouter delayed = _deploy(3 days);
        delayed.beginDefaultAdminTransfer(treasury);
        vm.warp(block.timestamp + 3 days + 2 seconds);
        vm.prank(treasury);
        delayed.acceptDefaultAdminTransfer();
        vm.expectRevert();
        delayed.pause();
    }

    // ═══════════════ CONSTRUCTOR GUARDS ═══════════════

    function test_Ctor_RevertsOnZeroAddress() public {
        vm.expectRevert(FeeRouter.BadDependency.selector);
        new FeeRouter(
            address(0), address(nut), address(wnut), address(pips),
            address(pipsBuyer), address(swapRouter), address(lpRouter),
            address(eas), address(registry), address(pair),
            pipsUID_, lpUID_, 0, block.chainid, MAX_RUN, HORIZON
        );
    }

    function test_Ctor_RevertsOnChainMismatch() public {
        vm.expectRevert(FeeRouter.ChainMismatch.selector);
        new FeeRouter(
            address(usdc), address(nut), address(wnut), address(pips),
            address(pipsBuyer), address(swapRouter), address(lpRouter),
            address(eas), address(registry), address(pair),
            pipsUID_, lpUID_, 0, block.chainid + 1, MAX_RUN, HORIZON
        );
    }

    function test_Ctor_RevertsOnUnknownSchemaUID() public {
        vm.expectRevert(FeeRouter.SchemaNotFound.selector);
        new FeeRouter(
            address(usdc), address(nut), address(wnut), address(pips),
            address(pipsBuyer), address(swapRouter), address(lpRouter),
            address(eas), address(registry), address(pair),
            bytes32(uint256(123)), lpUID_, 0, block.chainid, MAX_RUN, HORIZON
        );
    }

    function test_Ctor_RevertsOnWrongSchemaDefinition() public {
        bytes32 wrongUID = registry.register("uint256 amount", ISchemaResolver(address(0)), false);
        vm.expectRevert(FeeRouter.SchemaNotFound.selector);
        new FeeRouter(
            address(usdc), address(nut), address(wnut), address(pips),
            address(pipsBuyer), address(swapRouter), address(lpRouter),
            address(eas), address(registry), address(pair),
            wrongUID, lpUID_, 0, block.chainid, MAX_RUN, HORIZON
        );
    }

    function test_Ctor_RevertsOnRegistryMismatch() public {
        MockSchemaRegistry other = new MockSchemaRegistry();
        vm.expectRevert();
        new FeeRouter(
            address(usdc), address(nut), address(wnut), address(pips),
            address(pipsBuyer), address(swapRouter), address(lpRouter),
            address(eas), address(registry), address(other),
            pipsUID_, lpUID_, 0, block.chainid, MAX_RUN, HORIZON
        );
    }

    function test_Ctor_RevertsOnWrongWnutUnderlying() public {
        MockERC20 fakeNut = new MockERC20("fake", "FK");
        WNUT fakeWnut = new WNUT(address(fakeNut));
        vm.expectRevert(FeeRouter.BadDependency.selector);
        new FeeRouter(
            address(usdc), address(nut), address(fakeWnut), address(pips),
            address(pipsBuyer), address(swapRouter), address(lpRouter),
            address(eas), address(registry), address(pair),
            pipsUID_, lpUID_, 0, block.chainid, MAX_RUN, HORIZON
        );
    }

    function test_Ctor_RevertsOnBadLpTokenPair() public {
        MockPair wrongPair = new MockPair(address(nut), address(usdc));
        vm.expectRevert(FeeRouter.BadLpToken.selector);
        new FeeRouter(
            address(usdc), address(nut), address(wnut), address(pips),
            address(pipsBuyer), address(swapRouter), address(lpRouter),
            address(eas), address(registry), address(wrongPair),
            pipsUID_, lpUID_, 0, block.chainid, MAX_RUN, HORIZON
        );
    }

    function test_Ctor_RevertsOnBadCaps() public {
        vm.expectRevert(FeeRouter.BadCap.selector);
        new FeeRouter(
            address(usdc), address(nut), address(wnut), address(pips),
            address(pipsBuyer), address(swapRouter), address(lpRouter),
            address(eas), address(registry), address(pair),
            pipsUID_, lpUID_, 0, block.chainid, 0, HORIZON
        );
    }

    // ═══════════════ RECOVERY / RESCUE ═══════════════

    function test_RecoverDust_BlocksAllProtectedTokens() public {
        _run();
        address[5] memory protected = [
            address(usdc), address(nut), address(wnut), address(pips), address(pair)
        ];
        for (uint256 i = 0; i < 5; i++) {
            vm.expectRevert(FeeRouter.ProtectedToken.selector);
            router.recoverDust(protected[i], treasury);
        }
    }

    function test_RecoverDust_WorksWithJunk() public {
        MockERC20 junk = new MockERC20("junk", "JNK");
        junk.mint(address(router), 42e18);
        uint256 got = router.recoverDust(address(junk), treasury);
        assertEq(got, 42e18);
        assertEq(junk.balanceOf(treasury), 42e18);
    }

    function test_RecoverPips_PipsOnly() public {
        _run();
        uint256 got = router.recoverPips(treasury);
        assertEq(got, 160e18);
        assertEq(pips.balanceOf(treasury), 160e18);
        assertEq(pips.balanceOf(address(router)), 0);
    }

    function test_RescueUsdc_OnlyWhenPaused() public {
        vm.expectRevert();
        router.rescueUsdc(treasury);

        router.pause();
        usdc.mint(address(router), 7e6);
        uint256 got = router.rescueUsdc(treasury);
        assertEq(got, 7e6);
    }

    // ═══════════════ HYGIENE ═══════════════

    function test_AllowancesResetAfterRun() public {
        _run();
        assertEq(usdc.allowance(address(router), address(pipsBuyer)), 0);
        assertEq(usdc.allowance(address(router), address(swapRouter)), 0);
        assertEq(nut.allowance(address(router), address(wnut)), 0);
        assertEq(nut.allowance(address(router), address(lpRouter)), 0);
        assertEq(wnut.allowance(address(router), address(lpRouter)), 0);
    }

    function test_SecondRunDoesNotSweepPreexistingBalances() public {
        _run();
        pips.mint(address(router), 1_000e18);
        nut.mint(address(router), 1_000e18);
        usdc.mint(address(router), 500e6);

        _run();

        assertEq(router.totalPipsMinted(), 2 * 160e18);
        assertEq(router.totalLpAdded(), 2 * 9e26);
        assertEq(router.totalUsdcProcessed(), 2 * 100e6);

        assertEq(pips.balanceOf(address(router)), 1_000e18 + 320e18);
        (, , uint256 n) = router.residuals();
        assertEq(n, 1_000e18);
        (uint256 u, , ) = router.residuals();
        assertEq(u, 500e6);
    }

    // ═══════════════ ADMIN SETTERS ═══════════════

    function test_SetPipsBps() public {
        router.setPipsBps(5000);
        assertEq(router.pipsBps(), 5000);
        vm.expectRevert(FeeRouter.BadSplit.selector);
        router.setPipsBps(10_000);
    }

    function test_SetCaps() public {
        router.setCaps(50e6, 60);
        assertEq(router.maxUsdcPerRun(), 50e6);
        assertEq(router.maxDeadlineHorizon(), 60);
    }

    function test_SetSchemaUIDs_RejectsUnknown() public {
        vm.expectRevert(FeeRouter.SchemaNotFound.selector);
        router.setSchemaUIDs(bytes32(uint256(999)), lpUID_);
    }

    function test_SetSchemaUIDs_RejectsWrongDefinition() public {
        bytes32 wrongUID = registry.register("uint256 x", ISchemaResolver(address(0)), false);
        vm.expectRevert(FeeRouter.SchemaNotFound.selector);
        router.setSchemaUIDs(wrongUID, lpUID_);
    }

    function test_SetSchemaUIDs_AcceptsKnown() public {
        router.setSchemaUIDs(pipsUID_, lpUID_);
        assertEq(router.pipsSchemaUID(), pipsUID_);
    }
}
