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
    LyingLpRouter,
    MockResolver
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
    uint256 constant MAX_WINDOW = 3_000_000e6;

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
            address(usdc),
            address(nut),
            address(wnut),
            address(pips),
            address(pipsBuyer),
            address(swapRouter),
            address(lpRouter),
            address(eas),
            address(registry),
            address(pair),
            pipsUID_,
            lpUID_,
            adminDelay,
            block.chainid,
            MAX_RUN,
            HORIZON,
            MAX_WINDOW
        );
    }

    function _run() internal returns (bytes32, bytes32) {
        return router.splitAndDeploy(AMOUNT, 150e18, 55e18, 29e18, 29e18, 8e26, block.timestamp + 1800);
    }

    /// @dev M-02: dedicated router with window cap = 3 runs exactly.
    function _deployTightWindow() internal returns (FeeRouter) {
        return new FeeRouter(
            address(usdc),
            address(nut),
            address(wnut),
            address(pips),
            address(pipsBuyer),
            address(swapRouter),
            address(lpRouter),
            address(eas),
            address(registry),
            address(pair),
            pipsUID_,
            lpUID_,
            0,
            block.chainid,
            AMOUNT,
            HORIZON,
            3 * AMOUNT
        );
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
            address(usdc),
            address(nut),
            address(wnut),
            address(pips),
            address(liar),
            address(swapRouter),
            address(lpRouter),
            address(eas),
            address(registry),
            address(pair),
            pipsUID_,
            lpUID_,
            0,
            block.chainid,
            MAX_RUN,
            HORIZON,
            MAX_WINDOW
        );
        usdc.approve(address(bad), type(uint256).max);
        vm.expectRevert(FeeRouter.InsufficientPips.selector);
        bad.splitAndDeploy(AMOUNT, 150e18, 55e18, 29e18, 29e18, 8e26, block.timestamp + 1800);
    }

    function test_StingyPipsBuyer_AccountingMeasuresActualSpend() public {
        StingyPipsBuyer stingy = new StingyPipsBuyer(address(usdc), address(pips));
        FeeRouter fr = new FeeRouter(
            address(usdc),
            address(nut),
            address(wnut),
            address(pips),
            address(stingy),
            address(swapRouter),
            address(lpRouter),
            address(eas),
            address(registry),
            address(pair),
            pipsUID_,
            lpUID_,
            0,
            block.chainid,
            MAX_RUN,
            HORIZON,
            MAX_WINDOW
        );
        usdc.approve(address(fr), type(uint256).max);
        fr.splitAndDeploy(AMOUNT, 150e18, 55e18, 29e18, 29e18, 8e26, block.timestamp + 1800);

        assertEq(fr.totalUsdcToPips(), 40e6, "must measure actual USDC consumed");
        assertEq(fr.totalUsdcToLp(), 20e6);
        assertEq(fr.totalUsdcProcessed(), 100e6);
        (uint256 u,,) = fr.residuals();
        assertEq(u, 40e6);
    }

    function test_LyingSwapRouter_Reverts() public {
        LyingSwapRouter liar = new LyingSwapRouter(address(usdc), address(nut));
        FeeRouter bad = new FeeRouter(
            address(usdc),
            address(nut),
            address(wnut),
            address(pips),
            address(pipsBuyer),
            address(liar),
            address(lpRouter),
            address(eas),
            address(registry),
            address(pair),
            pipsUID_,
            lpUID_,
            0,
            block.chainid,
            MAX_RUN,
            HORIZON,
            MAX_WINDOW
        );
        usdc.approve(address(bad), type(uint256).max);
        vm.expectRevert(FeeRouter.InsufficientNut.selector);
        bad.splitAndDeploy(AMOUNT, 150e18, 55e18, 29e18, 29e18, 8e26, block.timestamp + 1800);
    }

    function test_LyingLpRouter_Reverts() public {
        LyingLpRouter liar = new LyingLpRouter();
        FeeRouter bad = new FeeRouter(
            address(usdc),
            address(nut),
            address(wnut),
            address(pips),
            address(pipsBuyer),
            address(swapRouter),
            address(liar),
            address(eas),
            address(registry),
            address(pair),
            pipsUID_,
            lpUID_,
            0,
            block.chainid,
            MAX_RUN,
            HORIZON,
            MAX_WINDOW
        );
        usdc.approve(address(bad), type(uint256).max);
        vm.expectRevert(FeeRouter.InsufficientLiquidity.selector);
        bad.splitAndDeploy(AMOUNT, 150e18, 55e18, 29e18, 29e18, 8e26, block.timestamp + 1800);
    }

    function test_SparingLpRouter_ResidualsCarriedAndAccounted() public {
        SparingLpRouter sparing = new SparingLpRouter(pair);
        FeeRouter fr = new FeeRouter(
            address(usdc),
            address(nut),
            address(wnut),
            address(pips),
            address(pipsBuyer),
            address(swapRouter),
            address(sparing),
            address(eas),
            address(registry),
            address(pair),
            pipsUID_,
            lpUID_,
            0,
            block.chainid,
            MAX_RUN,
            HORIZON,
            MAX_WINDOW
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

    /// @dev M-04: operator lifecycle — admin handoff must strip OPERATOR_ROLE too.
    function test_FormerAdminLosesOperatorRole() public {
        FeeRouter delayed = _deploy(3 days);
        // Deployer is admin + operator.
        assertTrue(delayed.hasRole(delayed.OPERATOR_ROLE(), address(this)));
        assertTrue(delayed.hasRole(delayed.DEFAULT_ADMIN_ROLE(), address(this)));

        delayed.beginDefaultAdminTransfer(treasury);
        vm.warp(block.timestamp + 3 days + 2 seconds);
        vm.prank(treasury);
        delayed.acceptDefaultAdminTransfer();

        // New admin has admin only — must grant operators explicitly.
        assertTrue(delayed.hasRole(delayed.DEFAULT_ADMIN_ROLE(), treasury));
        assertFalse(delayed.hasRole(delayed.OPERATOR_ROLE(), treasury));
        // Former admin lost EVERYTHING — admin and operator.
        assertFalse(delayed.hasRole(delayed.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(delayed.hasRole(delayed.OPERATOR_ROLE(), address(this)));

        // Former admin can no longer execute.
        usdc.approve(address(delayed), type(uint256).max);
        vm.expectRevert();
        delayed.splitAndDeploy(AMOUNT, 150e18, 55e18, 29e18, 29e18, 8e26, block.timestamp + 1800);

        // New admin can grant a fresh operator. NOTE: cache the role hash first —
        // evaluating delayed.OPERATOR_ROLE() inside the prank would consume it.
        bytes32 opRole = delayed.OPERATOR_ROLE();
        vm.prank(treasury);
        delayed.grantRole(opRole, attacker);
        assertTrue(delayed.hasRole(opRole, attacker));
    }

    /// @dev M-04 edge: revoking operator works independently of admin.
    function test_AdminCanRevokeOperator() public {
        router.grantRole(router.OPERATOR_ROLE(), attacker);
        assertTrue(router.hasRole(router.OPERATOR_ROLE(), attacker));
        router.revokeRole(router.OPERATOR_ROLE(), attacker);
        assertFalse(router.hasRole(router.OPERATOR_ROLE(), attacker));
    }

    // ═══════════════ SCHEMA SEMANTICS (L-01) ═══════════════

    /// @dev Resolver-bearing schema must not satisfy the protocol invariant.
    function test_Ctor_RejectsResolverBearingSchema() public {
        MockResolver resolver = new MockResolver();
        bytes32 resolverUID = registry.register(PIPS_DEF, ISchemaResolver(address(resolver)), false);
        vm.expectRevert(FeeRouter.SchemaNotFound.selector);
        new FeeRouter(
            address(usdc),
            address(nut),
            address(wnut),
            address(pips),
            address(pipsBuyer),
            address(swapRouter),
            address(lpRouter),
            address(eas),
            address(registry),
            address(pair),
            resolverUID,
            lpUID_,
            0,
            block.chainid,
            MAX_RUN,
            HORIZON,
            MAX_WINDOW
        );
    }

    /// @dev Revocable schema must not satisfy the protocol invariant.
    function test_Ctor_RejectsRevocableSchema() public {
        bytes32 revocableUID = registry.register(PIPS_DEF, ISchemaResolver(address(0)), true);
        vm.expectRevert(FeeRouter.SchemaNotFound.selector);
        new FeeRouter(
            address(usdc),
            address(nut),
            address(wnut),
            address(pips),
            address(pipsBuyer),
            address(swapRouter),
            address(lpRouter),
            address(eas),
            address(registry),
            address(pair),
            revocableUID,
            lpUID_,
            0,
            block.chainid,
            MAX_RUN,
            HORIZON,
            MAX_WINDOW
        );
    }

    /// @dev setSchemaUIDs must also reject resolver/revocable schemas.
    function test_SetSchemaUIDs_RejectsResolverBearing() public {
        MockResolver resolver = new MockResolver();
        bytes32 resolverUID = registry.register(PIPS_DEF, ISchemaResolver(address(resolver)), false);
        vm.expectRevert(FeeRouter.SchemaNotFound.selector);
        router.setSchemaUIDs(resolverUID, lpUID_);
    }

    /// @dev setSchemaUIDs must also reject revocable schemas.
    function test_SetSchemaUIDs_RejectsRevocable() public {
        bytes32 revocableUID = registry.register(PIPS_DEF, ISchemaResolver(address(0)), true);
        vm.expectRevert(FeeRouter.SchemaNotFound.selector);
        router.setSchemaUIDs(revocableUID, lpUID_);
    }

    // ═══════════════ RESIDUAL REDEPLOY (M-03) ═══════════════

    function test_DeployResiduals_RevertsWhenNothingToDeploy() public {
        vm.expectRevert(FeeRouter.NothingToDeploy.selector);
        router.deployResiduals(1, 1, 1, block.timestamp + 60);
    }

    function test_DeployResiduals_RedeploysStrandedBalances() public {
        // Strand residuals in the router: wNUT (wrapped here, delivered to router)
        // + raw NUT minted directly to the router.
        nut.mint(address(this), 30e18);
        nut.approve(address(wnut), 30e18);
        wnut.depositFor(address(router), 30e18);
        nut.mint(address(router), 30e18);

        uint256 liq = router.deployResiduals(29e18, 29e18, 800e24, block.timestamp + 1800);

        // MockLpRouter consumes everything: liquidity = 30e18 * 30e18 / 1e12.
        assertEq(liq, 900e24);
        assertEq(router.totalLpAdded(), 900e24);
        assertEq(pair.balanceOf(address(router)), 900e24);
        (, uint256 w, uint256 n) = router.residuals();
        assertEq(w, 0);
        assertEq(n, 0);
    }

    function test_DeployResiduals_OnlyOperator() public {
        nut.mint(address(this), 30e18);
        nut.approve(address(wnut), 30e18);
        wnut.depositFor(address(router), 30e18);
        nut.mint(address(router), 30e18);
        vm.prank(attacker);
        vm.expectRevert();
        router.deployResiduals(1, 1, 1, block.timestamp + 60);
    }

    function test_DeployResiduals_BlocksWhenPaused() public {
        nut.mint(address(this), 30e18);
        nut.approve(address(wnut), 30e18);
        wnut.depositFor(address(router), 30e18);
        nut.mint(address(router), 30e18);
        router.pause();
        vm.expectRevert();
        router.deployResiduals(1, 1, 1, block.timestamp + 60);
    }

    function test_DeployResiduals_RespectsDeadlineBounds() public {
        nut.mint(address(this), 30e18);
        nut.approve(address(wnut), 30e18);
        wnut.depositFor(address(router), 30e18);
        nut.mint(address(router), 30e18);
        vm.expectRevert(FeeRouter.DeadlineTooFar.selector);
        router.deployResiduals(1, 1, 1, block.timestamp + HORIZON + 1);
    }

    // ═══════════════ CONSTRUCTOR GUARDS ═══════════════

    function test_Ctor_RevertsOnZeroAddress() public {
        vm.expectRevert(FeeRouter.BadDependency.selector);
        new FeeRouter(
            address(0),
            address(nut),
            address(wnut),
            address(pips),
            address(pipsBuyer),
            address(swapRouter),
            address(lpRouter),
            address(eas),
            address(registry),
            address(pair),
            pipsUID_,
            lpUID_,
            0,
            block.chainid,
            MAX_RUN,
            HORIZON,
            MAX_WINDOW
        );
    }

    function test_Ctor_RevertsOnChainMismatch() public {
        vm.expectRevert(FeeRouter.ChainMismatch.selector);
        new FeeRouter(
            address(usdc),
            address(nut),
            address(wnut),
            address(pips),
            address(pipsBuyer),
            address(swapRouter),
            address(lpRouter),
            address(eas),
            address(registry),
            address(pair),
            pipsUID_,
            lpUID_,
            0,
            block.chainid + 1,
            MAX_RUN,
            HORIZON,
            MAX_WINDOW
        );
    }

    function test_Ctor_RevertsOnUnknownSchemaUID() public {
        vm.expectRevert(FeeRouter.SchemaNotFound.selector);
        new FeeRouter(
            address(usdc),
            address(nut),
            address(wnut),
            address(pips),
            address(pipsBuyer),
            address(swapRouter),
            address(lpRouter),
            address(eas),
            address(registry),
            address(pair),
            bytes32(uint256(123)),
            lpUID_,
            0,
            block.chainid,
            MAX_RUN,
            HORIZON,
            MAX_WINDOW
        );
    }

    function test_Ctor_RevertsOnWrongSchemaDefinition() public {
        bytes32 wrongUID = registry.register("uint256 amount", ISchemaResolver(address(0)), false);
        vm.expectRevert(FeeRouter.SchemaNotFound.selector);
        new FeeRouter(
            address(usdc),
            address(nut),
            address(wnut),
            address(pips),
            address(pipsBuyer),
            address(swapRouter),
            address(lpRouter),
            address(eas),
            address(registry),
            address(pair),
            wrongUID,
            lpUID_,
            0,
            block.chainid,
            MAX_RUN,
            HORIZON,
            MAX_WINDOW
        );
    }

    function test_Ctor_RevertsOnRegistryMismatch() public {
        MockSchemaRegistry other = new MockSchemaRegistry();
        vm.expectRevert();
        new FeeRouter(
            address(usdc),
            address(nut),
            address(wnut),
            address(pips),
            address(pipsBuyer),
            address(swapRouter),
            address(lpRouter),
            address(eas),
            address(registry),
            address(other),
            pipsUID_,
            lpUID_,
            0,
            block.chainid,
            MAX_RUN,
            HORIZON,
            MAX_WINDOW
        );
    }

    function test_Ctor_RevertsOnWrongWnutUnderlying() public {
        MockERC20 fakeNut = new MockERC20("fake", "FK");
        WNUT fakeWnut = new WNUT(address(fakeNut));
        vm.expectRevert(FeeRouter.BadDependency.selector);
        new FeeRouter(
            address(usdc),
            address(nut),
            address(fakeWnut),
            address(pips),
            address(pipsBuyer),
            address(swapRouter),
            address(lpRouter),
            address(eas),
            address(registry),
            address(pair),
            pipsUID_,
            lpUID_,
            0,
            block.chainid,
            MAX_RUN,
            HORIZON,
            MAX_WINDOW
        );
    }

    function test_Ctor_RevertsOnBadLpTokenPair() public {
        MockPair wrongPair = new MockPair(address(nut), address(usdc));
        vm.expectRevert(FeeRouter.BadLpToken.selector);
        new FeeRouter(
            address(usdc),
            address(nut),
            address(wnut),
            address(pips),
            address(pipsBuyer),
            address(swapRouter),
            address(lpRouter),
            address(eas),
            address(registry),
            address(wrongPair),
            pipsUID_,
            lpUID_,
            0,
            block.chainid,
            MAX_RUN,
            HORIZON,
            MAX_WINDOW
        );
    }

    function test_Ctor_RevertsOnBadCaps() public {
        vm.expectRevert(FeeRouter.BadCap.selector);
        new FeeRouter(
            address(usdc),
            address(nut),
            address(wnut),
            address(pips),
            address(pipsBuyer),
            address(swapRouter),
            address(lpRouter),
            address(eas),
            address(registry),
            address(pair),
            pipsUID_,
            lpUID_,
            0,
            block.chainid,
            0,
            HORIZON,
            MAX_WINDOW
        );
    }

    // ═══════════════ RECOVERY / RESCUE ═══════════════

    function test_RecoverDust_BlocksAllProtectedTokens() public {
        _run();
        address[5] memory protected = [address(usdc), address(nut), address(wnut), address(pips), address(pair)];
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
        (,, uint256 n) = router.residuals();
        assertEq(n, 1_000e18);
        (uint256 u,,) = router.residuals();
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
        router.setCaps(50e6, 60, 500e6);
        assertEq(router.maxUsdcPerRun(), 50e6);
        assertEq(router.maxDeadlineHorizon(), 60);
        assertEq(router.maxUsdcPerWindow(), 500e6);
    }

    /// @dev M-02: window cap may never fall below per-run cap.
    function test_SetCaps_RevertsOnWindowBelowRun() public {
        vm.expectRevert(FeeRouter.BadWindow.selector);
        router.setCaps(50e6, 60, 49e6);
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

    // ═══════════════ AUDIT ROUND 4 ═══════════════

    /// @dev M-01: default-admin renunciation must be impossible — this
    ///      contract has no shutdown mode; renounce would brick governance
    ///      while leaving OPERATOR_ROLE holders in place.
    function test_RenounceDefaultAdmin_Forbidden() public {
        // Cache getter BEFORE expectRevert — a staticcall between expectRevert
        // and the target call consumes the revert expectation.
        bytes32 adminRole = router.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(FeeRouter.AdminRenunciationForbidden.selector);
        router.renounceRole(adminRole, address(this));
    }

    /// @dev M-01: operator may still renounce its own operator role.
    function test_RenounceOperatorRole_Allowed() public {
        router.renounceRole(router.OPERATOR_ROLE(), address(this));
        assertFalse(router.hasRole(router.OPERATOR_ROLE(), address(this)));
    }

    /// @dev M-02: rolling 24h window caps aggregate operator throughput.
    function test_WindowCap_BlocksAggregate() public {
        FeeRouter fr = _deployTightWindow();
        // Window cap 3x AMOUNT: three runs pass, fourth reverts.
        _runOn(fr);
        _runOn(fr);
        _runOn(fr);
        // Direct call: _runOn's approve() would consume the expectRevert.
        vm.expectRevert(FeeRouter.WindowCapExceeded.selector);
        fr.splitAndDeploy(AMOUNT, 150e18, 55e18, 29e18, 29e18, 8e26, block.timestamp + 1800);
    }

    /// @dev M-02: window resets after WINDOW_DURATION.
    function test_WindowCap_ResetsAfterWindow() public {
        FeeRouter fr = _deployTightWindow();
        _runOn(fr);
        _runOn(fr);
        _runOn(fr);
        vm.warp(block.timestamp + fr.WINDOW_DURATION() + 1);
        _runOn(fr); // fresh window — succeeds
        assertEq(fr.totalUsdcProcessed(), 4 * AMOUNT);
    }

    /// @dev M-02: fresh window does NOT inherit old spend.
    function test_WindowCap_FreshWindowStartsClean() public {
        FeeRouter fr = _deployTightWindow();
        _runOn(fr);
        _runOn(fr);
        _runOn(fr);
        vm.warp(block.timestamp + fr.WINDOW_DURATION() + 1);
        _runOn(fr);
        _runOn(fr);
        _runOn(fr);
        vm.expectRevert(FeeRouter.WindowCapExceeded.selector);
        fr.splitAndDeploy(AMOUNT, 150e18, 55e18, 29e18, 29e18, 8e26, block.timestamp + 1800);
    }

    /// @dev M-02: constructor rejects window < per-run cap.
    function test_Ctor_RevertsOnWindowBelowRun() public {
        vm.expectRevert(FeeRouter.BadWindow.selector);
        new FeeRouter(
            address(usdc),
            address(nut),
            address(wnut),
            address(pips),
            address(pipsBuyer),
            address(swapRouter),
            address(lpRouter),
            address(eas),
            address(registry),
            address(pair),
            pipsUID_,
            lpUID_,
            0,
            block.chainid,
            MAX_RUN,
            HORIZON,
            MAX_RUN - 1
        );
    }

    /// @dev L-02: ResidualsDeployed must report ACTUAL consumed deltas,
    ///      not requested amounts (SparingLpRouter consumes 90%).
    function test_DeployResiduals_EmitsActualDeltas() public {
        SparingLpRouter sparing = new SparingLpRouter(pair);
        FeeRouter fr = new FeeRouter(
            address(usdc),
            address(nut),
            address(wnut),
            address(pips),
            address(pipsBuyer),
            address(swapRouter),
            address(sparing),
            address(eas),
            address(registry),
            address(pair),
            pipsUID_,
            lpUID_,
            0,
            block.chainid,
            MAX_RUN,
            HORIZON,
            MAX_WINDOW
        );
        nut.mint(address(this), 30e18);
        nut.approve(address(wnut), 30e18);
        wnut.depositFor(address(fr), 30e18);
        nut.mint(address(fr), 30e18);

        vm.expectEmit(true, true, true, true, address(fr));
        emit FeeRouter.ResidualsDeployed(27e18, 27e18, 7.29e26, block.timestamp);
        fr.deployResiduals(26e18, 26e18, 700e24, block.timestamp + 1800);
    }

    /// @dev L-03: recovery destinations may never be address(0).
    function test_Recovery_RevertsOnZeroRecipient() public {
        vm.expectRevert(FeeRouter.ZeroRecipient.selector);
        router.recoverPips(address(0));
        vm.expectRevert(FeeRouter.ZeroRecipient.selector);
        router.recoverDust(address(pips), address(0));
        router.pause();
        vm.expectRevert(FeeRouter.ZeroRecipient.selector);
        router.rescueUsdc(address(0));
    }
}
