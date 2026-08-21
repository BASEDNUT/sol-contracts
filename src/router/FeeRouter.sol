// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IEAS} from "@eas/contracts/IEAS.sol";
import {ISchemaRegistry, SchemaRecord} from "@eas/contracts/ISchemaRegistry.sol";
import {AttestationRequest, AttestationRequestData} from "@eas/contracts/IEAS.sol";

import {WNUT} from "../wnut/WNUT.sol";
import {IPipsBuyer} from "../interfaces/IPipsBuyer.sol";
import {ISwapRouter, IAddLiquidityRouter} from "../interfaces/ISwapRouter.sol";

interface IERC20Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/**
 * @title FeeRouter — NUT Credit Protocol fee deployment engine
 * @notice Splits incoming USDC:
 *         80% -> PIPS mint leg (via IPipsBuyer adapter, balance-delta verified)
 *         20% -> NUT LP leg  (USDC->NUT swap, wrap half -> wNUT, add wNUT/NUT liquidity)
 *         Every run emits two EAS attestations.
 *
 * Security model:
 *         - Single authority: DEFAULT_ADMIN_ROLE with delayed 2-step transfer
 *           (AccessControlDefaultAdminRules). This is NOT an execution timelock:
 *           admin parameter changes and recovery execute immediately.
 *         - OPERATOR_ROLE: calls splitAndDeploy with explicit bounds; bound by
 *           contract-level caps (maxUsdcPerRun, maxDeadlineHorizon).
 *         - LP position is protocol-owned and NOT withdrawable by admin. LP token
 *           is denylisted from recovery and pair-validated at construction.
 *         - All economic quantities are measured by balance deltas, never by
 *           external call return values.
 *         - Venue integration via adapter contracts (see src/adapters/).
 */
contract FeeRouter is AccessControlDefaultAdminRules, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // ── Canonical schema definitions (attestation payload ABI) ──
    string public constant PIPS_SCHEMA_DEF =
        "string action,address caller,uint256 usdcTotal,uint256 usdcToPips,uint256 pipsMinted,uint256 timestamp";
    string public constant LP_SCHEMA_DEF =
        "string action,address caller,uint256 usdcTotal,uint256 usdcToLp,uint256 nutBought,uint256 liquidity,uint256 timestamp";

    // ── Immutable config ──
    IERC20 public immutable usdc;
    IERC20 public immutable nut;
    WNUT public immutable wnut;
    IERC20 public immutable pips;
    IPipsBuyer public immutable pipsBuyer;      // adapter seam
    ISwapRouter public immutable swapRouter;    // USDC -> NUT adapter
    IAddLiquidityRouter public immutable lpRouter; // wNUT/NUT LP adapter
    IEAS public immutable eas;
    ISchemaRegistry public immutable schemaRegistry;
    IERC20 public immutable lpToken; // wNUT/NUT pool LP — protocol-owned, never sweepable

    // ── Mutable config (admin-settable) ──
    uint256 public pipsBps;          // 8000 = 80%
    uint256 public maxUsdcPerRun;    // operator execution cap
    uint256 public maxDeadlineHorizon; // seconds; deadline - now must not exceed
    bytes32 public pipsSchemaUID;
    bytes32 public lpSchemaUID;

    // ── Accounting (balance-delta measured) ──
    uint256 public totalUsdcProcessed;
    uint256 public totalUsdcToPips;
    uint256 public totalUsdcToLp;
    uint256 public totalPipsMinted;
    uint256 public totalLpAdded;

    // ── Events ──
    event FeesSplitAndDeployed(
        address indexed caller,
        uint256 usdcIn,
        uint256 usdcToPips,
        uint256 usdcToLp,
        uint256 pipsMinted,
        uint256 nutBought,
        uint256 liquidityAdded,
        bytes32 pipsAttestationUID,
        bytes32 lpAttestationUID,
        uint256 timestamp
    );
    event ResidualsCarried(uint256 usdc, uint256 wnut, uint256 nut);
    event ResidualsDeployed(uint256 wnut, uint256 nut, uint256 liquidity, uint256 timestamp);
    event PipsBpsUpdated(uint256 oldBps, uint256 newBps);
    event SchemaUIDsUpdated(bytes32 pipsSchema, bytes32 lpSchema);
    event CapsUpdated(uint256 maxUsdcPerRun, uint256 maxDeadlineHorizon);
    event PipsRecovered(address indexed to, uint256 amount);
    event DustRecovered(address indexed token, address indexed to, uint256 amount);
    event UsdcRescued(address indexed to, uint256 amount);

    // ── Errors ──
    error ZeroAmount();
    error BadSplit();
    error DeadlineExpired();
    error DeadlineTooFar();
    error ZeroSlippageBound();
    error InsufficientPips();
    error InsufficientNut();
    error InsufficientLiquidity();
    error AmountTooLarge();
    error ProtectedToken();
    error ChainMismatch();
    error BadDependency();
    error RegistryMismatch();
    error BadLpToken();
    error SchemaNotFound();
    error NothingToRecover();
    error NothingToRescue();
    error BadCap();
    error NothingToDeploy();

    constructor(
        address usdc_,
        address nut_,
        address wnut_,
        address pips_,
        address pipsBuyer_,
        address swapRouter_,
        address lpRouter_,
        address eas_,
        address schemaRegistry_,
        address lpToken_,
        bytes32 pipsSchemaUID_,
        bytes32 lpSchemaUID_,
        uint48 adminDelay_,
        uint256 expectedChainId_,
        uint256 maxUsdcPerRun_,
        uint256 maxDeadlineHorizon_
    )
        AccessControlDefaultAdminRules(adminDelay_, msg.sender)
    {
        if (
            usdc_ == address(0) || nut_ == address(0) || wnut_ == address(0)
            || pips_ == address(0) || pipsBuyer_ == address(0) || swapRouter_ == address(0)
            || lpRouter_ == address(0) || eas_ == address(0) || schemaRegistry_ == address(0)
            || lpToken_ == address(0) || usdc_.code.length == 0 || nut_.code.length == 0
            || wnut_.code.length == 0 || pips_.code.length == 0 || pipsBuyer_.code.length == 0
            || swapRouter_.code.length == 0 || lpRouter_.code.length == 0 || eas_.code.length == 0
            || schemaRegistry_.code.length == 0 || lpToken_.code.length == 0
        ) revert BadDependency();

        if (block.chainid != expectedChainId_) revert ChainMismatch();
        if (WNUT(wnut_).underlyingNUT() != nut_) revert BadDependency();
        if (IEAS(eas_).getSchemaRegistry() != ISchemaRegistry(schemaRegistry_)) revert RegistryMismatch();

        // LP token must be the canonical wNUT/NUT pair
        address t0 = IERC20Pair(lpToken_).token0();
        address t1 = IERC20Pair(lpToken_).token1();
        if (!((t0 == wnut_ && t1 == nut_) || (t0 == nut_ && t1 == wnut_))) revert BadLpToken();

        // Schemas must exist in the bound registry AND match canonical definitions
        if (!_schemaMatches(ISchemaRegistry(schemaRegistry_), pipsSchemaUID_, PIPS_SCHEMA_DEF)) {
            revert SchemaNotFound();
        }
        if (!_schemaMatches(ISchemaRegistry(schemaRegistry_), lpSchemaUID_, LP_SCHEMA_DEF)) {
            revert SchemaNotFound();
        }

        if (maxUsdcPerRun_ == 0 || maxDeadlineHorizon_ == 0) revert BadCap();

        usdc = IERC20(usdc_);
        nut = IERC20(nut_);
        wnut = WNUT(wnut_);
        pips = IERC20(pips_);
        pipsBuyer = IPipsBuyer(pipsBuyer_);
        swapRouter = ISwapRouter(swapRouter_);
        lpRouter = IAddLiquidityRouter(lpRouter_);
        eas = IEAS(eas_);
        schemaRegistry = ISchemaRegistry(schemaRegistry_);
        lpToken = IERC20(lpToken_);

        pipsBps = 8000;
        maxUsdcPerRun = maxUsdcPerRun_;
        maxDeadlineHorizon = maxDeadlineHorizon_;
        pipsSchemaUID = pipsSchemaUID_;
        lpSchemaUID = lpSchemaUID_;

        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    // ═══════════════ CORE ENTRY ═══════════════

    /**
     * @notice Split USDC and deploy both legs. Operator-only, cap-bounded.
     * @dev All outputs measured by balance deltas. Return values of external
     *      adapters are never trusted for accounting.
     * @param usdcAmount       total USDC to process (<= maxUsdcPerRun)
     * @param minPipsOut       minimum PIPS balance delta
     * @param minNutOut        minimum NUT balance delta from swap
     * @param minLpWnut        minimum wNUT side accepted by addLiquidity
     * @param minLpNut         minimum NUT side accepted by addLiquidity
     * @param minLiquidityOut  minimum LP token balance delta
     * @param deadline         execution deadline (<= now + maxDeadlineHorizon)
     */
    function splitAndDeploy(
        uint256 usdcAmount,
        uint256 minPipsOut,
        uint256 minNutOut,
        uint256 minLpWnut,
        uint256 minLpNut,
        uint256 minLiquidityOut,
        uint256 deadline
    )
        external
        nonReentrant
        whenNotPaused
        onlyRole(OPERATOR_ROLE)
        returns (bytes32 pipsUID, bytes32 lpUID)
    {
        if (usdcAmount == 0) revert ZeroAmount();
        if (usdcAmount > maxUsdcPerRun) revert AmountTooLarge();
        if (minPipsOut == 0 || minNutOut == 0 || minLpWnut == 0 || minLpNut == 0 || minLiquidityOut == 0) {
            revert ZeroSlippageBound();
        }
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (deadline - block.timestamp > maxDeadlineHorizon) revert DeadlineTooFar();

        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        uint256 toPips = (usdcAmount * pipsBps) / 10_000;
        uint256 toLp = usdcAmount - toPips;
        if (toPips == 0 || toLp == 0) revert BadSplit();

        // ── Leg 1: PIPS mint (80%) — balance-delta verified ──
        uint256 usdcBeforePips = usdc.balanceOf(address(this));
        uint256 pipsBefore = pips.balanceOf(address(this));
        usdc.forceApprove(address(pipsBuyer), toPips);
        pipsBuyer.buyPips(toPips);
        usdc.forceApprove(address(pipsBuyer), 0);
        uint256 usdcSpentOnPips = usdcBeforePips - usdc.balanceOf(address(this));
        uint256 pipsMinted = pips.balanceOf(address(this)) - pipsBefore;
        if (pipsMinted < minPipsOut) revert InsufficientPips();

        // ── Leg 2: NUT LP (20%) ──
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(nut);
        uint256 nutBefore = nut.balanceOf(address(this));
        uint256 usdcBeforeSwap = usdc.balanceOf(address(this));
        usdc.forceApprove(address(swapRouter), toLp);
        swapRouter.swapExactTokensForTokens(toLp, minNutOut, path, address(this), deadline);
        usdc.forceApprove(address(swapRouter), 0);
        uint256 usdcSpentOnSwap = usdcBeforeSwap - usdc.balanceOf(address(this));
        uint256 nutBought = nut.balanceOf(address(this)) - nutBefore;
        if (nutBought < minNutOut) revert InsufficientNut();

        // Wrap exactly half of this run's NUT (never sweeps pre-existing balances)
        uint256 nutForWrap = nutBought / 2;
        uint256 nutDirect = nutBought - nutForWrap;
        nut.forceApprove(address(wnut), nutForWrap);
        wnut.depositFor(address(this), nutForWrap);
        nut.forceApprove(address(wnut), 0);

        // LP exactly this run's amounts — liquidity measured by LP balance delta
        uint256 lpBefore = lpToken.balanceOf(address(this));
        IERC20(address(wnut)).forceApprove(address(lpRouter), nutForWrap);
        nut.forceApprove(address(lpRouter), nutDirect);
        lpRouter.addLiquidity(
            address(wnut),
            address(nut),
            nutForWrap,
            nutDirect,
            minLpWnut,
            minLpNut,
            address(this),
            deadline
        );
        IERC20(address(wnut)).forceApprove(address(lpRouter), 0);
        nut.forceApprove(address(lpRouter), 0);
        uint256 liquidity = lpToken.balanceOf(address(this)) - lpBefore;
        if (liquidity < minLiquidityOut) revert InsufficientLiquidity();

        // ── Accounting: actuals only, before external attest calls ──
        totalUsdcProcessed += usdcAmount;
        totalUsdcToPips += usdcSpentOnPips;
        totalUsdcToLp += usdcSpentOnSwap;
        totalPipsMinted += pipsMinted;
        totalLpAdded += liquidity;

        // ── Residual accounting (M-03: stranded assets made explicit) ──
        emit ResidualsCarried(
            usdc.balanceOf(address(this)),
            wnut.balanceOf(address(this)),
            nut.balanceOf(address(this))
        );

        // ── Attestations ──
        pipsUID = _attestPips(msg.sender, usdcAmount, usdcSpentOnPips, pipsMinted);
        lpUID = _attestLp(msg.sender, usdcAmount, usdcSpentOnSwap, nutBought, liquidity);

        emit FeesSplitAndDeployed(
            msg.sender, usdcAmount, usdcSpentOnPips, usdcSpentOnSwap,
            pipsMinted, nutBought, liquidity, pipsUID, lpUID, block.timestamp
        );
    }

    // ═══════════════ VIEWS ═══════════════

    /// @notice Current residual core-asset balances held by the router.
    function residuals() external view returns (uint256 usdcBal, uint256 wnutBal, uint256 nutBal) {
        return (usdc.balanceOf(address(this)), wnut.balanceOf(address(this)), nut.balanceOf(address(this)));
    }

    /**
     * @notice Redeploy accumulated NUT/wNUT residuals into the LP. Operator-only.
     *         Gives stranded residuals a bounded redeployment path instead of
     *         permanently trapped value. LP tokens stay protocol-owned; USDC
     *         residuals remain admin-gated (rescueUsdc).
     * @dev    Uses the FULL current residual balances — residuals are by
     *         definition already router-owned accounting; there is no caller
     *         contribution to sweep. Any post-LP remainder simply carries again.
     */
    function deployResiduals(
        uint256 minLpWnut,
        uint256 minLpNut,
        uint256 minLiquidityOut,
        uint256 deadline
    )
        external
        nonReentrant
        whenNotPaused
        onlyRole(OPERATOR_ROLE)
        returns (uint256 liquidity)
    {
        uint256 wnutBal = wnut.balanceOf(address(this));
        uint256 nutBal = nut.balanceOf(address(this));
        if (wnutBal == 0 || nutBal == 0) revert NothingToDeploy();
        if (minLpWnut == 0 || minLpNut == 0 || minLiquidityOut == 0) revert ZeroSlippageBound();
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (deadline - block.timestamp > maxDeadlineHorizon) revert DeadlineTooFar();

        uint256 lpBefore = lpToken.balanceOf(address(this));
        IERC20(address(wnut)).forceApprove(address(lpRouter), wnutBal);
        nut.forceApprove(address(lpRouter), nutBal);
        lpRouter.addLiquidity(
            address(wnut), address(nut), wnutBal, nutBal,
            minLpWnut, minLpNut, address(this), deadline
        );
        IERC20(address(wnut)).forceApprove(address(lpRouter), 0);
        nut.forceApprove(address(lpRouter), 0);

        liquidity = lpToken.balanceOf(address(this)) - lpBefore;
        if (liquidity < minLiquidityOut) revert InsufficientLiquidity();

        totalLpAdded += liquidity;
        emit ResidualsDeployed(wnutBal, nutBal, liquidity, block.timestamp);
    }

    // ═══════════════ INTERNAL ═══════════════

    function _schemaMatches(
        ISchemaRegistry registry,
        bytes32 uid,
        string memory expectedDef
    ) internal view returns (bool) {
        if (uid == bytes32(0)) return false;
        SchemaRecord memory record = registry.getSchema(uid);
        // Full semantics binding: exact definition, no resolver hook, immutable.
        // A resolver-bearing or revocable schema can change attestation
        // execution/liveness and must not satisfy a protocol accounting invariant.
        return record.uid == uid
            && keccak256(bytes(record.schema)) == keccak256(bytes(expectedDef))
            && address(record.resolver) == address(0)
            && !record.revocable;
    }

    function _attestPips(
        address caller, uint256 usdcTotal, uint256 usdcToPips, uint256 pipsMinted
    ) internal returns (bytes32) {
        bytes memory data = abi.encode(
            "PIPS_MINT", caller, usdcTotal, usdcToPips, pipsMinted, block.timestamp
        );
        return eas.attest(AttestationRequest({
            schema: pipsSchemaUID,
            data: AttestationRequestData({
                recipient: caller,
                expirationTime: 0,
                revocable: false,
                refUID: bytes32(0),
                data: data,
                value: 0
            })
        }));
    }

    function _attestLp(
        address caller, uint256 usdcTotal, uint256 usdcToLp, uint256 nutBought, uint256 liquidity
    ) internal returns (bytes32) {
        bytes memory data = abi.encode(
            "NUT_LP", caller, usdcTotal, usdcToLp, nutBought, liquidity, block.timestamp
        );
        return eas.attest(AttestationRequest({
            schema: lpSchemaUID,
            data: AttestationRequestData({
                recipient: caller,
                expirationTime: 0,
                revocable: false,
                refUID: bytes32(0),
                data: data,
                value: 0
            })
        }));
    }

    // ═══════════════ ADMIN ═══════════════

    function setPipsBps(uint256 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps == 0 || newBps >= 10_000) revert BadSplit();
        emit PipsBpsUpdated(pipsBps, newBps);
        pipsBps = newBps;
    }

    function setCaps(uint256 maxUsdc_, uint256 horizon_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (maxUsdc_ == 0 || horizon_ == 0) revert BadCap();
        maxUsdcPerRun = maxUsdc_;
        maxDeadlineHorizon = horizon_;
        emit CapsUpdated(maxUsdc_, horizon_);
    }

    function setSchemaUIDs(bytes32 pipsSchema_, bytes32 lpSchema_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!_schemaMatches(schemaRegistry, pipsSchema_, PIPS_SCHEMA_DEF)) revert SchemaNotFound();
        if (!_schemaMatches(schemaRegistry, lpSchema_, LP_SCHEMA_DEF)) revert SchemaNotFound();
        pipsSchemaUID = pipsSchema_;
        lpSchemaUID = lpSchema_;
        emit SchemaUIDsUpdated(pipsSchema_, lpSchema_);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }

    /// @dev Operator lifecycle: when the default admin changes, the outgoing
    ///      admin loses OPERATOR_ROLE. Admin and operator are separate
    ///      lifecycle-controlled identities; authority handoff removes ALL
    ///      authority. New admins grant operators explicitly.
    function _acceptDefaultAdminTransfer() internal virtual override {
        address oldAdmin = defaultAdmin();
        super._acceptDefaultAdminTransfer();
        address newAdmin = defaultAdmin();
        if (oldAdmin != newAdmin && hasRole(OPERATOR_ROLE, oldAdmin)) {
            _revokeRole(OPERATOR_ROLE, oldAdmin);
        }
    }

    /// @notice Sweep accumulated PIPS to treasury custody. PIPS token only.
    function recoverPips(address to) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256) {
        uint256 bal = pips.balanceOf(address(this));
        if (bal == 0) revert NothingToRecover();
        pips.safeTransfer(to, bal);
        emit PipsRecovered(to, bal);
        return bal;
    }

    /// @notice Recover non-core junk tokens. Never USDC/NUT/wNUT/PIPS/LP.
    function recoverDust(address token, address to)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256)
    {
        if (
            token == address(usdc) || token == address(nut)
            || token == address(wnut) || token == address(pips)
            || token == address(lpToken)
        ) revert ProtectedToken();
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) revert NothingToRecover();
        IERC20(token).safeTransfer(to, bal);
        emit DustRecovered(token, to, bal);
        return bal;
    }

    /// @notice Emergency USDC rescue. Admin + PAUSED only (blacklist/freeze scenarios).
    function rescueUsdc(address to) external onlyRole(DEFAULT_ADMIN_ROLE) whenPaused returns (uint256) {
        uint256 bal = usdc.balanceOf(address(this));
        if (bal == 0) revert NothingToRescue();
        usdc.safeTransfer(to, bal);
        emit UsdcRescued(to, bal);
        return bal;
    }
}
