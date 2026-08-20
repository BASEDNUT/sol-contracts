// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {WNUT} from "../../src/wnut/WNUT.sol";
import {MockERC20} from "../mocks/Mocks.sol";

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
        assertEq(wnut.decimals(), 18);
        assertEq(wnut.underlyingNUT(), address(nut));
    }

    // ── Wrap / unwrap 1:1 ──
    function test_DepositFor_Mints1to1() public {
        vm.prank(alice);
        nut.approve(address(wnut), 100e18);
        vm.prank(alice);
        bool ok = wnut.depositFor(alice, 100e18);
        assertTrue(ok);
        assertEq(wnut.balanceOf(alice), 100e18);
        assertEq(nut.balanceOf(address(wnut)), 100e18);
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

    // ── Surplus does NOT mint wNUT ──
    function test_DirectTransfer_NoMint() public {
        vm.prank(alice);
        nut.transfer(address(wnut), 50e18);
        assertEq(wnut.totalSupply(), 0);
    }

    // ── Recover ──
    function test_Recover_NonNUTToken() public {
        MockERC20 junk = new MockERC20("JUNK", "JUNK");
        junk.mint(address(wnut), 7e18);
        uint256 got = wnut.recover(address(junk));
        assertEq(got, 7e18);
        assertEq(junk.balanceOf(wnut.owner()), 7e18);
    }

    function test_Recover_RevertsOnNUT() public {
        vm.prank(alice);
        nut.transfer(address(wnut), 5e18);
        vm.expectRevert();
        wnut.recover(address(nut));
    }

    function test_Recover_RevertsOnSelf() public {
        vm.expectRevert();
        wnut.recover(address(wnut));
    }

    function test_Recover_OnlyOwner() public {
        MockERC20 junk = new MockERC20("JUNK", "JUNK");
        junk.mint(address(wnut), 7e18);
        vm.prank(alice);
        vm.expectRevert();
        wnut.recover(address(junk));
    }

    function test_Recover_RevertsOnEmpty() public {
        MockERC20 junk = new MockERC20("JUNK", "JUNK");
        vm.expectRevert();
        wnut.recover(address(junk));
    }
}
