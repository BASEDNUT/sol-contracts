// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {WNUT} from "../wnut/WNUT.sol";
import {IPipsBuyer} from "../interfaces/IPipsBuyer.sol";
import {ISwapRouter, IAddLiquidityRouter} from "../interfaces/ISwapRouter.sol";
import {IEAS, AttestationRequest, AttestationData} from "../interfaces/EAS.sol";

/**
 * @title FeeRouter — NUT Credit Protocol fee deployment engine
 * @notice Splits incoming USDC:
 *         80% -> PIPS mint leg (via IPipsBuyer adapter)
 *         20% -> NUT LP leg  (USDC->NUT swap, wrap half -> wNUT, add wNUT/NUT liquidity)
 *         Every action emits an EAS attestation (Base predeploy 0x4200...0021).
 *         Immutable. Operator-gated. Pausable.
 */
contract FeeRouter is
    Ownable,
    AccessControl,
    ReentrancyGuard,
    Pausable
{
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // ── Immutable config ──
    IERC20 public immutable usdc;
    IERC20 public immutable nut;
    WNUT public immutable wnut;
    IPipsBuyer public immutable pipsBuyer;      // adapter seam (swappable pre-deploy)
    ISwapRouter public immutable swapRouter;    // USDC -> NUT
    IAddLiquidityRouter public immutable lpRouter; // wNUT/NUT pool
    IEAS public immutable eas;

    // ── Mutable config (owner-settable) ──
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

    error ZeroAmount();
    error BadSplit();
    error EthTransferFailed();

    constructor(
        address usdc_,
        address nut_,
        address wnut_,
        address pipsBuyer_,
        address swapRouter_,
        address lpRouter_,
        address eas_,
        bytes32 pipsSchemaUID_,
        bytes32 lpSchemaUID_
    )
        Ownable(msg.sender)
    {
        usdc = IERC20(usdc_);
        nut = IERC20(nut_);
        wnut = WNUT(wnut_);
        pipsBuyer = IPipsBuyer(pipsBuyer_);
        swapRouter = ISwapRouter(swapRouter_);
        lpRouter = IAddLiquidityRouter(lpRouter_);
        eas = IEAS(eas_);
        pipsBps = 8000;
        pipsSchemaUID = pipsSchemaUID_;
        lpSchemaUID = lpSchemaUID_;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    // ═══════════════ CORE ENTRY ═══════════════

    /**
     * @notice Split USDC and deploy both legs. Operator-only.
     * @dev Caller must approve this contract for `usdcAmount` beforehand.
     *      Single transaction: 80% PIPS mint + 20% NUT LP + 2 EAS attestations.
     */
    function splitAndDeploy(uint256 usdcAmount)
        external
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
        nonReentrant
        returns (bytes32 pipsUID, bytes32 lpUID)
    {
        if (usdcAmount == 0) revert ZeroAmount();

        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        uint256 toPips = (usdcAmount * pipsBps) / 10_000;
        uint256 toLp = usdcAmount - toPips;
        if (toPips == 0 || toLp == 0) revert BadSplit();

        // ── Leg 1: PIPS mint (80%) ──
        usdc.safeIncreaseAllowance(address(pipsBuyer), toPips);
        uint256 pipsMinted = pipsBuyer.buyPips(toPips);

        // ── Leg 2: NUT LP (20%) ──
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(nut);
        usdc.safeIncreaseAllowance(address(swapRouter), toLp);
        uint256[] memory amounts = swapRouter.swapExactTokensForTokens(
            toLp, 1, path, address(this), block.timestamp + 300
        );
        uint256 nutBought = amounts[amounts.length - 1];

        // Wrap half -> wNUT, LP both sides
        uint256 nutForWrap = nutBought / 2;
        uint256 nutDirect = nutBought - nutForWrap;
        nut.safeIncreaseAllowance(address(wnut), nutForWrap);
        wnut.depositFor(address(this), nutForWrap);

        nut.safeIncreaseAllowance(address(lpRouter), nutDirect);
        IERC20(address(wnut)).safeIncreaseAllowance(address(lpRouter), wnut.balanceOf(address(this)));
        (, , uint256 liquidity) = lpRouter.addLiquidity(
            address(wnut),
            address(nut),
            wnut.balanceOf(address(this)),
            nutDirect,
            1,
            1,
            address(this),
            block.timestamp + 300
        );

        // ── Attestations ──
        pipsUID = _attestPips(msg.sender, usdcAmount, toPips, pipsMinted);
        lpUID = _attestLp(msg.sender, usdcAmount, toLp, nutBought, liquidity);

        // ── Accounting ──
        totalUsdcProcessed += usdcAmount;
        totalUsdcToPips += toPips;
        totalUsdcToLp += toLp;
        totalPipsMinted += pipsMinted;
        totalLpAdded += liquidity;

        emit FeesSplitAndDeployed(
            msg.sender, usdcAmount, toPips, toLp, pipsMinted,
            nutBought, liquidity, pipsUID, lpUID, block.timestamp
        );
    }

    // ═══════════════ INTERNAL ═══════════════

    function _attestPips(
        address caller, uint256 usdcTotal, uint256 usdcToPips, uint256 pipsMinted
    ) internal returns (bytes32) {
        bytes memory data = abi.encode(
            "PIPS_MINT",
            caller,
            usdcTotal,
            usdcToPips,
            pipsMinted,
            block.timestamp
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
            "NUT_LP",
            caller,
            usdcTotal,
            usdcToLp,
            nutBought,
            liquidity,
            block.timestamp
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

    function setPipsBps(uint256 newBps) external onlyOwner {
        if (newBps == 0 || newBps >= 10_000) revert BadSplit();
        emit PipsBpsUpdated(pipsBps, newBps);
        pipsBps = newBps;
    }

    function setSchemaUIDs(bytes32 pipsSchema_, bytes32 lpSchema_) external onlyOwner {
        pipsSchemaUID = pipsSchema_;
        lpSchemaUID = lpSchema_;
        emit SchemaUIDsUpdated(pipsSchema_, lpSchema_);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// @notice Recover stuck PIPS or NUT dust (never USDC).
    function recoverPips(address pipsToken, address to) external onlyOwner returns (uint256) {
        uint256 bal = IERC20(pipsToken).balanceOf(address(this));
        if (bal > 0) IERC20(pipsToken).safeTransfer(to, bal);
        emit PipsRecovered(to, bal);
        return bal;
    }
}
