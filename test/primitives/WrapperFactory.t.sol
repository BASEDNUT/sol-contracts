// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Wrapper} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Wrapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WrapperFactory} from "../../src/primitives/WrapperFactory.sol";
import {Wrapper} from "../../src/primitives/Wrapper.sol";
import {TokenFactory} from "../../src/primitives/TokenFactory.sol";
import {Token} from "../../src/primitives/Token.sol";

contract MockUnderlying is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _decimals = d;
        _mint(msg.sender, 1_000_000e18);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

contract FeeOnTransferToken is ERC20 {
    uint256 public constant FEE_BPS = 100; // 1% fee on every transfer

    constructor() ERC20("Fee Nut", "FEE") {
        _mint(msg.sender, 1_000_000e18);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) {
            uint256 fee = (value * FEE_BPS) / 10_000;
            super._update(from, to, value - fee);
            super._update(from, address(0xBEEF), fee);
        } else {
            super._update(from, to, value);
        }
    }
}

contract SelfWrap is ERC20Wrapper {
    // address(0) selects the self-wrap path (reverts ERC20InvalidUnderlying);
    // any other address is a valid underlying, giving the compiler a viable assignment path.
    constructor(address u) ERC20("self", "self") ERC20Wrapper(u == address(0) ? IERC20(address(this)) : IERC20(u)) {}
}

contract WrapperFactoryTest is Test {
    WrapperFactory internal wrapperFactory;
    TokenFactory internal tokenFactory;
    MockUnderlying internal underlying;
    FeeOnTransferToken internal feeToken;
    Wrapper internal wrapper;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        wrapperFactory = new WrapperFactory();
        tokenFactory = new TokenFactory();
        underlying = new MockUnderlying("Mock Under", "MUND", 18);
        feeToken = new FeeOnTransferToken();
        vm.prank(alice);
        wrapper = Wrapper(payable(wrapperFactory.create(address(underlying), "Wrapped Mock", "wMUND")));
        deal(address(underlying), alice, 1_000_000e18);
        deal(address(feeToken), alice, 1_000e18);
    }

    // ---------- TEST 3: depositFor / withdrawTo 1:1 roundtrip ----------

    function test_Wrap_DepositWithdrawRoundtrip() public {
        vm.startPrank(alice);
        underlying.approve(address(wrapper), 100e18);
        wrapper.depositFor(alice, 100e18);
        vm.stopPrank();

        assertEq(wrapper.balanceOf(alice), 100e18, "wrapped minted 1:1");
        assertEq(underlying.balanceOf(address(wrapper)), 100e18, "underlying custody");

        vm.prank(alice);
        wrapper.withdrawTo(alice, 100e18);

        assertEq(wrapper.balanceOf(alice), 0, "wrapped burned");
        assertEq(underlying.balanceOf(alice), 1_000_000e18, "underlying returned");
        assertEq(wrapper.totalSupply(), 0, "supply zero");
    }

    // ---------- TEST 4: decimals auto-inherit ----------

    function test_Wrap_DecimalsInheritUnderlying() public {
        MockUnderlying six = new MockUnderlying("Six Dec", "SIXD", 6);
        vm.prank(alice);
        address w6 = wrapperFactory.create(address(six), "Wrapped Six", "wSIXD");
        assertEq(ERC20(w6).decimals(), 6, "inherits 6");
        assertEq(wrapper.decimals(), 18, "inherits 18");
    }

    // ---------- TEST 5: self-wrap reverts ----------

    function test_Wrap_SelfWrapReverts() public {
        // try/catch instead of expectRevert(selector): Foundry 1.8.3 bare-selector matching
        // requires argless errors; raw revert-data assert is precise and version-proof.
        try new SelfWrap(address(0)) returns (SelfWrap) {
            fail("self-wrap must revert");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), ERC20Wrapper.ERC20InvalidUnderlying.selector, "ERC20InvalidUnderlying");
            assertEq(reason.length, 36, "selector + one address arg");
        }
    }

    function test_Factory_SelfWrapStructurallyImpossible() public {
        // Factory-created wrappers get a fresh address; underlying is chosen BEFORE deploy,
        // so underlying == wrapper can never hold. Wrapping an existing wrapper is legal composition.
        vm.prank(alice);
        address w2 = wrapperFactory.create(address(wrapper), "Wrapped Wrapper", "wWRAP");
        assertTrue(w2 != address(wrapper), "w2 is a new contract");
        assertEq(address(Wrapper(payable(w2)).underlying()), address(wrapper), "wraps the wrapper, not itself");
    }

    // ---------- TEST 6: wrap a BPT-like token, usable as pool input ----------

    function test_Wrap_WrapBptUsableAsPoolInput() public {
        vm.prank(alice);
        address mockBpt = tokenFactory.create("Mock Pool Token", "mBPT", 10_000e18);

        vm.prank(alice);
        address wrappedBpt = wrapperFactory.create(mockBpt, "Wrapped mBPT", "wmBPT");

        vm.startPrank(alice);
        Token(mockBpt).approve(wrappedBpt, 500e18);
        Wrapper(payable(wrappedBpt)).depositFor(alice, 500e18);
        vm.stopPrank();

        assertEq(ERC20(wrappedBpt).balanceOf(alice), 500e18, "BPT wrapped 1:1");

        vm.prank(alice);
        ERC20(wrappedBpt).transfer(bob, 250e18);
        assertEq(ERC20(wrappedBpt).balanceOf(bob), 250e18, "wrapped BPT transfers = pool-input ready");
    }

    // ---------- TEST 8: fee-on-transfer underlying quarantined ----------

    function test_Wrap_FeeOnTransferQuarantined() public {
        vm.prank(alice);
        address wFee = wrapperFactory.create(address(feeToken), "Wrapped Fee", "wFEE");

        vm.startPrank(alice);
        feeToken.approve(wFee, 1_000e18);
        Wrapper(payable(wFee)).depositFor(alice, 100e18);
        vm.stopPrank();

        assertEq(ERC20(wFee).balanceOf(alice), 99e18, "mints received (99), not requested (100)");
        assertEq(feeToken.balanceOf(wFee), 99e18, "custody = received");
        assertLe(ERC20(wFee).totalSupply(), feeToken.balanceOf(wFee), "solvency holds");

        vm.prank(alice);
        Wrapper(payable(wFee)).withdrawTo(alice, 99e18);

        assertEq(ERC20(wFee).totalSupply(), 0, "full exit burned");
        assertEq(feeToken.balanceOf(wFee), 0, "custody drained");
        // deal 1_000; deposit 100 -> fee 1; withdraw 99 -> fee 0.99; total fee loss 1.99
        assertEq(feeToken.balanceOf(alice), 998.01e18, "user exited with fee loss only");
    }

    // ---------- factory validation + events ----------

    function test_RevertWhen_UnderlyingNotAContract() public {
        address eoa = makeAddr("eoa");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WrapperFactory.WrapperFactory__NotAContract.selector, eoa));
        wrapperFactory.create(eoa, "Bad", "BAD");
    }

    function test_RevertWhen_CreateEmptyName() public {
        vm.prank(alice);
        vm.expectRevert(WrapperFactory.WrapperFactory__EmptyName.selector);
        wrapperFactory.create(address(underlying), "", "SYM");
    }

    function test_RevertWhen_CreateEmptySymbol() public {
        vm.prank(alice);
        vm.expectRevert(WrapperFactory.WrapperFactory__EmptySymbol.selector);
        wrapperFactory.create(address(underlying), "Name", "");
    }

    function test_Factory_TwoCreatesDistinctAddressesAndEvents() public {
        vm.startPrank(alice);
        vm.expectEmit(false, true, true, true);
        emit WrapperFactory.WrapperCreated(address(0), alice, address(underlying), "Wrapped Mock", "wMUND");
        address w1 = wrapperFactory.create(address(underlying), "Wrapped Mock", "wMUND");
        vm.expectEmit(false, true, true, true);
        emit WrapperFactory.WrapperCreated(address(0), alice, address(underlying), "Wrapped Mock 2", "wMUN2");
        address w2 = wrapperFactory.create(address(underlying), "Wrapped Mock 2", "wMUN2");
        vm.stopPrank();

        assertTrue(w1 != w2, "distinct wrappers");
        assertTrue(w1 != address(0) && w2 != address(0));
    }

    function test_Wrapper_UnderlyingViewMatches() public view {
        assertEq(address(wrapper.underlying()), address(underlying), "underlying() view");
    }

    // ---------- fuzz: roundtrip + fee-on-transfer solvency ----------

    function testFuzz_Wrap_Roundtrip(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e18);
        deal(address(underlying), alice, amount);

        vm.startPrank(alice);
        underlying.approve(address(wrapper), amount);
        wrapper.depositFor(alice, amount);
        assertEq(wrapper.balanceOf(alice), amount, "deposit exact");
        wrapper.withdrawTo(alice, amount);
        vm.stopPrank();

        assertEq(underlying.balanceOf(alice), amount, "roundtrip exact");
        assertEq(wrapper.totalSupply(), 0, "supply zero");
    }

    function testFuzz_Wrap_FeeOnTransferStaysSolvent(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e18);
        vm.prank(alice);
        address wFee = wrapperFactory.create(address(feeToken), "Wrapped Fee", "wFEE");
        deal(address(feeToken), alice, amount);

        vm.startPrank(alice);
        feeToken.approve(wFee, amount);
        Wrapper(payable(wFee)).depositFor(alice, amount);
        vm.stopPrank();

        assertLe(ERC20(wFee).totalSupply(), feeToken.balanceOf(wFee), "invariant: supply <= custody");
        assertGt(ERC20(wFee).balanceOf(alice), 0, "minted something");
    }
}
