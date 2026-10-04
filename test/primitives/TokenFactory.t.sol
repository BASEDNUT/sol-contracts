// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TokenFactory} from "../../src/primitives/TokenFactory.sol";
import {Token} from "../../src/primitives/Token.sol";

contract TokenFactoryTest is Test {
    TokenFactory internal factory;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        factory = new TokenFactory();
    }

    // ---------- TEST 1: premint to creator, balances exact ----------

    function test_Create_MintsFullSupplyToCreator() public {
        vm.prank(alice);
        address token = factory.create("Test Nut", "TNUT", 1_000_000e18);

        assertEq(Token(token).balanceOf(alice), 1_000_000e18, "creator balance");
        assertEq(Token(token).totalSupply(), 1_000_000e18, "total supply");
        assertEq(Token(token).balanceOf(bob), 0, "outsider balance");
    }

    // ---------- TEST 2: fixed supply, no admin surface ----------

    function test_Create_NoAdminSurface() public {
        vm.prank(alice);
        address token = factory.create("Test Nut", "TNUT", 1_000e18);

        (bool okOwner,) = token.call(abi.encodeWithSignature("owner()"));
        assertFalse(okOwner, "owner() must not exist");

        (bool okMint,) = token.call(abi.encodeWithSignature("mint(address,uint256)", bob, 1e18));
        assertFalse(okMint, "mint() must not exist");

        (bool okSetName,) = token.call(abi.encodeWithSignature("setName(string)", "x"));
        assertFalse(okSetName, "setName() must not exist");

        vm.prank(alice);
        Token(token).transfer(bob, 100e18);
        assertEq(Token(token).totalSupply(), 1_000e18, "supply immutable across transfers");
    }

    function test_Create_MetadataSetAtConstruction() public {
        vm.prank(alice);
        address token = factory.create("Immutable Name", "IMM", 1e18);
        assertEq(Token(token).name(), "Immutable Name");
        assertEq(Token(token).symbol(), "IMM");
    }

    // ---------- TEST 7: two creates, distinct addresses, events ----------

    function test_Factory_TwoCreatesDistinctAddresses() public {
        vm.startPrank(alice);
        address t1 = factory.create("First", "ONE", 1e18);
        address t2 = factory.create("Second", "TWO", 2e18);
        vm.stopPrank();

        assertTrue(t1 != t2, "distinct addresses");
        assertEq(Token(t1).balanceOf(alice), 1e18);
        assertEq(Token(t2).balanceOf(alice), 2e18);
    }

    function test_Create_EmitsTokenCreated() public {
        vm.prank(alice);
        vm.expectEmit(false, true, false, true);
        emit TokenFactory.TokenCreated(address(0), alice, "Test Nut", "TNUT", 1_000e18);
        address token = factory.create("Test Nut", "TNUT", 1_000e18);
        assertTrue(token != address(0), "token deployed");
    }

    // ---------- input validation ----------

    function test_RevertWhen_CreateZeroSupply() public {
        vm.prank(alice);
        vm.expectRevert(TokenFactory.TokenFactory__ZeroSupply.selector);
        factory.create("Zero", "Z", 0);
    }

    function test_RevertWhen_CreateEmptyName() public {
        vm.prank(alice);
        vm.expectRevert(TokenFactory.TokenFactory__EmptyName.selector);
        factory.create("", "Z", 1e18);
    }

    function test_RevertWhen_CreateEmptySymbol() public {
        vm.prank(alice);
        vm.expectRevert(TokenFactory.TokenFactory__EmptySymbol.selector);
        factory.create("Name", "", 1e18);
    }

    // ---------- fuzz: create paths ----------

    function testFuzz_Create_AnySupplyMintsExact(uint256 supply, address creator) public {
        supply = bound(supply, 1, type(uint256).max);
        creator = address(uint160(bound(uint256(uint160(creator)), 1, type(uint160).max)));
        vm.prank(creator);
        address token = factory.create("Fuzz Nut", "FNUT", supply);

        assertEq(Token(token).balanceOf(creator), supply, "creator gets full supply");
        assertEq(Token(token).totalSupply(), supply, "supply exact");
    }

    function testFuzz_Create_TransferPreservesSupply(uint256 supply, uint256 amount) public {
        supply = bound(supply, 1, 1_000_000e18);
        amount = bound(amount, 0, supply);
        vm.prank(alice);
        address token = factory.create("Fuzz Nut", "FNUT", supply);

        vm.prank(alice);
        Token(token).transfer(bob, amount);
        assertEq(Token(token).totalSupply(), supply, "transfers never change supply");
        assertEq(Token(token).balanceOf(alice), supply - amount);
        assertEq(Token(token).balanceOf(bob), amount);
    }
}
