// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {WNUT} from "../../src/wnut/WNUT.sol";
import {MockERC20} from "../mocks/Mocks.sol";

/// @dev WETH9-model invariants: permissionless wrap/unwrap, 1:1 backing,
///      no admin surface, unbacked mint impossible.
contract WNUTTest is Test {
    WNUT public wnut;
    MockERC20 public nut;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        nut = new MockERC20("NUT", "NUT");
        wnut = new WNUT(address(nut));
        nut.mint(alice, 1000e18);
    }

    // ── Identity ──
    function test_Metadata() public view {
        assertEq(wnut.name(), "Wrapped NUT");
        assertEq(wnut.symbol(), "wNUT");
        assertEq(wnut.decimals(), 18); // mirrors underlying via OZ
        assertEq(address(wnut.underlying()), address(nut));
    }

    // ── WETH model: wrap/unwrap permissionless, 1:1 ──
    function test_DepositFor_Mints1to1() public {
        vm.startPrank(alice);
        nut.approve(address(wnut), 100e18);
        bool ok = wnut.depositFor(alice, 100e18);
        vm.stopPrank();
        assertTrue(ok);
        assertEq(wnut.balanceOf(alice), 100e18);
        assertEq(nut.balanceOf(address(wnut)), 100e18);
    }

    function test_DepositFor_AnyoneCanWrapForAnyone() public {
        vm.startPrank(alice);
        nut.approve(address(wnut), 100e18);
        wnut.depositFor(bob, 100e18); // alice wraps, bob receives wNUT
        vm.stopPrank();
        assertEq(wnut.balanceOf(bob), 100e18);
        assertEq(nut.balanceOf(address(wnut)), 100e18);
    }

    /// @dev Standard OZ semantics: depositFor(0) is a harmless no-op success.
    function test_DepositFor_ZeroIsNoop() public {
        vm.prank(alice);
        bool ok = wnut.depositFor(alice, 0);
        assertTrue(ok);
        assertEq(wnut.totalSupply(), 0);
        assertEq(nut.balanceOf(address(wnut)), 0);
    }

    function test_WithdrawTo_Burns1to1() public {
        vm.startPrank(alice);
        nut.approve(address(wnut), 100e18);
        wnut.depositFor(alice, 100e18);
        wnut.withdrawTo(bob, 40e18);
        vm.stopPrank();
        assertEq(wnut.balanceOf(alice), 60e18);
        assertEq(nut.balanceOf(bob), 40e18);
    }

    function test_WithdrawTo_RevertsBeyondBalance() public {
        vm.startPrank(alice);
        nut.approve(address(wnut), 100e18);
        wnut.depositFor(alice, 100e18);
        vm.expectRevert();
        wnut.withdrawTo(bob, 100e18 + 1);
        vm.stopPrank();
    }

    // ── Core invariant: backing always >= supply (no unbacked mint path) ──
    function test_Invariant_SupplyNeverExceedsBacking() public {
        vm.startPrank(alice);
        nut.approve(address(wnut), type(uint256).max);
        wnut.depositFor(alice, 500e18);
        wnut.withdrawTo(alice, 200e18);
        wnut.depositFor(alice, 50e18);
        vm.stopPrank();
        assertEq(wnut.totalSupply(), 350e18);
        assertEq(nut.balanceOf(address(wnut)), 350e18);
    }

    function testFuzz_BackupUpBalance(uint256 wrapAmount, uint256 unwrapAmount) public {
        wrapAmount = bound(wrapAmount, 1, 1000e18);
        vm.startPrank(alice);
        nut.approve(address(wnut), type(uint256).max);
        wnut.depositFor(alice, wrapAmount);
        unwrapAmount = bound(unwrapAmount, 0, wnut.balanceOf(alice));
        if (unwrapAmount > 0) {
            wnut.withdrawTo(alice, unwrapAmount);
        }
        vm.stopPrank();
        // backing == supply, always
        assertEq(nut.balanceOf(address(wnut)), wnut.totalSupply());
    }

    // ── WETH parity: direct transfers never mint (permanently stranded) ──
    function test_DirectTransfer_NoMint() public {
        vm.prank(alice);
        nut.transfer(address(wnut), 50e18);
        assertEq(wnut.totalSupply(), 0);
        // stranded forever — no rescue exists, by design
        assertEq(nut.balanceOf(address(wnut)), 50e18);
    }

    // ── Zero admin surface ──
    function test_NoOwnerFunction() public {
        // no owner() selector exposed — call must fail
        (bool ok,) = address(wnut).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
    }

    function test_NoTransferOwnershipFunction() public {
        (bool ok,) = address(wnut).call(abi.encodeWithSignature("transferOwnership(address)", bob));
        assertFalse(ok);
    }

    function test_NoRecoverFunctions() public {
        (bool ok1,) = address(wnut).call(abi.encodeWithSignature("recover(address)", address(nut)));
        (bool ok2,) = address(wnut).call(abi.encodeWithSignature("recoverSurplus()"));
        assertFalse(ok1);
        assertFalse(ok2);
    }
}
