// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {WNUT} from "../wnut/WNUT.sol";
import {IPipsBuyer} from "../interfaces/IPipsBuyer.sol";
import {ISwapRouter, IAddLiquidityRouter} from "../interfaces/ISwapRouter.sol";
import {IEAS, ISchemaRegistry, AttestationRequest, AttestationData} from "../interfaces/EAS.sol";

/**
 * @title FeeRouter — NUT Credit Protocol fee deployment engine
 * @notice Splits incoming USDC:
 *         80% -> PIPS mint leg (via IPipsBuyer adapter, balance-delta verified)
 *         20% -> NUT LP leg  (USDC->NUT swap, wrap half -> wNUT, add wNUT/NUT liquidity)
 *         Every run emits two EAS attestations (Base predeploy 0x4200...0021).
 *
 * Security model:
 *         - Single authority: DEFAULT_ADMIN_ROLE (timelocked via AccessControlDefaultAdminRules).
 *           No Ownable. Admin transfer is 2-step + delayed.
 *         - OPERATOR_ROLE: may call splitAndDeploy with explicit slippage bounds.
 *         - LP position is PROTOCOL-OWNED and NOT withdrawable by admin. LP tokens cannot
 *           be swept by any function. PIPS accumulated may be swept by admin (treasury custody).
 *         - USDC rescue only while paused (blacklist/emergency).
 */
contract FeeRouter is AccessControlDefaultAdminRules, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // ── Immutable config ──
    IERC20 public immutable usdc;
    IERC20 public immutable nut;
    WNUT public immutable wnut;
    IERC20 public immutable pips;             // PIPS token for balance-delta verification
    IPipsBuyer public immutable pipsBuyer;    // adapter seam
    ISwapRouter public immutable swapRouter;  // USDC -> NUT
    IAddLiquidityRouter public immutable lpRouter; // wNUT/NUT pool
    IEAS public immutable eas;
    ISchemaRegistry public immutable schemaRegistry; // schema existence validation
    IERC20 public immutable lpToken; // wNUT/NUT pool LP token — protocol-owned, never sweepable

    // ── Mutable config (admin-settable) ──
    uint256 public pipsBps;      // 8000 = 80%
    bytes32 public pipsSchemaUID;
    bytes32 public lpSchemaUID;

    // ── Accounting ──
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
    event PipsBpsUpdated(uint256 oldBps, uint256 newBps);
    event SchemaUIDsUpdated(bytes32 pipsSchema, bytes32 lpSchema);
    event PipsRecovered(address indexed to, uint256 amount);
    event DustRecovered(address indexed token, address indexed to, uint256 amount);
    event UsdcRescued(address indexed to, uint256 amount);

    // ── Errors ──
    error ZeroAmount();
    error BadSplit();
    error DeadlineExpired();
    error ZeroSlippageBound();
    error InsufficientPips();
    error InsufficientNut();
    error ProtectedToken();
    error ChainMismatch();
    error BadDependency();
    error SchemaNotFound();
    error NothingToRecover();
    error NothingToRescue();

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
        uint256 expectedChainId_
    )
        AccessControlDefaultAdminRules(adminDelay_, msg.sender)
    {
        if (
            usdc_ == address(0) || nut_ == address(0) || wnut_ == address(0)
            || pips_ == address(0) || pipsBuyer_ == address(0) || swapRouter_ == address(0)
            || lpRouter_ == address(0) || eas_ == address(0) || schemaRegistry_ == address(0)
            || lpToken_ == address(0) || lpToken_.code.length == 0
            || usdc_.code.length == 0 || nut_.code.length == 0 || wnut_.code.length == 0
            || pips_.code.length == 0 || pipsBuyer_.code.length == 0 || swapRouter_.code.length == 0
            || lpRouter_.code.length == 0 || eas_.code.length == 0 || schemaRegistry_.code.length == 0
        ) revert BadDependency();

        if (block.chainid != expectedChainId_) revert ChainMismatch();
        if (WNUT(wnut_).underlyingNUT() != nut_) revert BadDependency();
        if (!_schemaExists(schemaRegistry_, pipsSchemaUID_)) revert SchemaNotFound();
        if (!_schemaExists(schemaRegistry_, lpSchemaUID_)) revert SchemaNotFound();

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
        pipsSchemaUID = pipsSchemaUID_;
        lpSchemaUID = lpSchemaUID_;

        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    // ═══════════════ CORE ENTRY ═══════════════

    /**
     * @notice Split USDC and deploy both legs. Operator-only.
     * @dev Caller must approve this contract for `usdcAmount` beforehand.
     *      All slippage bounds are caller-supplied and enforced on-chain.
     * @param usdcAmount  total USDC to process
     * @param minPipsOut  minimum PIPS received by router (balance-delta verified)
     * @param minNutOut   minimum NUT out of the USDC->NUT swap
     * @param minLpWnut   minimum wNUT side accepted by addLiquidity
     * @param minLpNut    minimum NUT side accepted by addLiquidity
     * @param deadline    latest timestamp the swap+LP may execute
     */
    function splitAndDeploy(
        uint256 usdcAmount,
        uint256 minPipsOut,
        uint256 minNutOut,
        uint256 minLpWnut,
        uint256 minLpNut,
        uint256 deadline
    )
        external
        nonReentrant
        whenNotPaused
        onlyRole(OPERATOR_ROLE)
        returns (bytes32 pipsUID, bytes32 lpUID)
    {
        if (usdcAmount == 0) revert ZeroAmount();
        if (minPipsOut == 0 || minNutOut == 0 || minLpWnut == 0 || minLpNut == 0) {
            revert ZeroSlippageBound();
        }
        if (block.timestamp > deadline) revert DeadlineExpired();

        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        uint256 toPips = (usdcAmount * pipsBps) / 10_000;
        uint256 toLp = usdcAmount - toPips;
        if (toPips == 0 || toLp == 0) revert BadSplit();

        // ── Leg 1: PIPS mint (80%) — balance-delta verified ──
        uint256 pipsBefore = pips.balanceOf(address(this));
        usdc.forceApprove(address(pipsBuyer), toPips);
        pipsBuyer.buyPips(toPips);
        usdc.forceApprove(address(pipsBuyer), 0);
        uint256 pipsMinted = pips.balanceOf(address(this)) - pipsBefore;
        if (pipsMinted < minPipsOut) revert InsufficientPips();

        // ── Leg 2: NUT LP (20%) ──
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(nut);
        usdc.forceApprove(address(swapRouter), toLp);
        uint256[] memory amounts = swapRouter.swapExactTokensForTokens(
            toLp, minNutOut, path, address(this), deadline
        );
        usdc.forceApprove(address(swapRouter), 0);
        uint256 nutBought = amounts[amounts.length - 1];
        if (nutBought < minNutOut) revert InsufficientNut();

        // Wrap exactly half -> wNUT (never sweeps pre-existing balances)
        uint256 nutForWrap = nutBought / 2;
        uint256 nutDirect = nutBought - nutForWrap;
        nut.forceApprove(address(wnut), nutForWrap);
        wnut.depositFor(address(this), nutForWrap);
        nut.forceApprove(address(wnut), 0);

        // LP exactly the amounts derived from this run
        IERC20(address(wnut)).forceApprove(address(lpRouter), nutForWrap);
        nut.forceApprove(address(lpRouter), nutDirect);
        (, , uint256 liquidity) = lpRouter.addLiquidity(
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

        // ── Accounting (before external attest calls) ──
        totalUsdcProcessed += usdcAmount;
        totalUsdcToPips += toPips;
        totalUsdcToLp += toLp;
        totalPipsMinted += pipsMinted;
        totalLpAdded += liquidity;

        // ── Attestations ──
        pipsUID = _attestPips(msg.sender, usdcAmount, toPips, pipsMinted);
        lpUID = _attestLp(msg.sender, usdcAmount, toLp, nutBought, liquidity);

        emit FeesSplitAndDeployed(
            msg.sender, usdcAmount, toPips, toLp, pipsMinted,
            nutBought, liquidity, pipsUID, lpUID, block.timestamp
        );
    }

    // ═══════════════ INTERNAL ═══════════════

    function _schemaExists(address registry, bytes32 uid) internal view returns (bool) {
        try ISchemaRegistry(registry).getSchema(uid) returns (
            bytes32, address, bool, string memory, address, uint64
        ) {
            return true;
        } catch {
            return false;
        }
    }

    function _attestPips(
        address caller, uint256 usdcTotal, uint256 usdcToPips, uint256 pipsMinted
    ) internal returns (bytes32) {
        bytes memory data = abi.encode(
            "PIPS_MINT", caller, usdcTotal, usdcToPips, pipsMinted, block.timestamp
        );
        return eas.attest(AttestationRequest({
            schema: pipsSchemaUID,
            data: AttestationData({
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
            data: AttestationData({
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

    function setSchemaUIDs(bytes32 pipsSchema_, bytes32 lpSchema_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!_schemaExists(address(schemaRegistry), pipsSchema_)) revert SchemaNotFound();
        if (!_schemaExists(address(schemaRegistry), lpSchema_)) revert SchemaNotFound();
        pipsSchemaUID = pipsSchema_;
        lpSchemaUID = lpSchema_;
        emit SchemaUIDsUpdated(pipsSchema_, lpSchema_);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }

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

    /// @notice Emergency USDC rescue. Admin + PAUSED only.
    /// @dev Covers USDC blacklist/freeze scenarios where normal flow is impossible.
    function rescueUsdc(address to) external onlyRole(DEFAULT_ADMIN_ROLE) whenPaused returns (uint256) {
        uint256 bal = usdc.balanceOf(address(this));
        if (bal == 0) revert NothingToRescue();
        usdc.safeTransfer(to, bal);
        emit UsdcRescued(to, bal);
        return bal;
    }
}
