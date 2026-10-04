// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {WrapperFactory} from "../../src/primitives/WrapperFactory.sol";
import {Wrapper} from "../../src/primitives/Wrapper.sol";

contract HandlerToken is ERC20 {
    constructor() ERC20("Handler Under", "HUND") {
        _mint(msg.sender, 1_000_000e18);
    }
}

/// @dev Handler-driven depositFor/withdrawTo/transfer sequences over a standard
///      (non-fee, non-rebasing) underlying. ARD-06 invariant: solvency always holds.
contract WrapHandler {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    Wrapper public wrapper;
    HandlerToken public underlying;
    address[3] internal actors;

    constructor() {
        underlying = new HandlerToken();
        WrapperFactory factory = new WrapperFactory();
        wrapper = Wrapper(payable(factory.create(address(underlying), "Handler Wrapped", "hWRAP")));
        actors = [
            vm.addr(uint160(uint256(keccak256(abi.encodePacked("hAlice"))))),
            vm.addr(uint160(uint256(keccak256(abi.encodePacked("hBob"))))),
            vm.addr(uint160(uint256(keccak256(abi.encodePacked("hCarol")))))
        ];
        // HandlerToken minted to this handler (the `new` deployer); distribute directly.
        for (uint256 i; i < 3; ++i) {
            vm.deal(actors[i], 1 ether);
            underlying.transfer(actors[i], 100_000e18);
        }
    }

    function depositFor(uint256 actorIdx, uint256 amount) external {
        address actor = actors[actorIdx % 3];
        uint256 bal = underlying.balanceOf(actor);
        if (bal == 0) return;
        amount = amount % (bal + 1);
        if (amount == 0) return;
        vm.startPrank(actor);
        underlying.approve(address(wrapper), amount);
        wrapper.depositFor(actor, amount);
        vm.stopPrank();
    }

    function withdrawTo(uint256 actorIdx, uint256 shares) external {
        address actor = actors[actorIdx % 3];
        uint256 bal = wrapper.balanceOf(actor);
        if (bal == 0) return;
        shares = shares % (bal + 1);
        if (shares == 0) return;
        vm.prank(actor);
        wrapper.withdrawTo(actor, shares);
    }

    function transferWrapped(uint256 fromIdx, uint256 toIdx, uint256 amount) external {
        address from = actors[fromIdx % 3];
        address to = actors[toIdx % 3];
        uint256 bal = wrapper.balanceOf(from);
        if (bal == 0) return;
        amount = amount % (bal + 1);
        if (amount == 0) return;
        vm.prank(from);
        wrapper.transfer(to, amount);
    }
}

contract WrapperInvariantTest is Test {
    WrapHandler internal handler;
    Wrapper internal wrapper;
    HandlerToken internal underlying;

    function setUp() public {
        handler = new WrapHandler();
        wrapper = handler.wrapper();
        underlying = handler.underlying();

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = bytes4(keccak256("depositFor(uint256,uint256)"));
        selectors[1] = bytes4(keccak256("withdrawTo(uint256,uint256)"));
        selectors[2] = bytes4(keccak256("transferWrapped(uint256,uint256,uint256)"));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// ARD-06 invariant: wrapper.totalSupply() <= underlying.balanceOf(wrapper) — ALWAYS.
    function invariant_WrapperSolvent() public view {
        assertLe(wrapper.totalSupply(), underlying.balanceOf(address(wrapper)), "solvency: supply <= custody");
    }
}
