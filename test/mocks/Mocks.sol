// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AttestationRequest} from "../../src/interfaces/EAS.sol";

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract MockPipsBuyer {
    MockERC20 public usdc;
    MockERC20 public pips;
    uint256 public rate = 2; // 1 USDC -> 2 PIPS
    constructor(address usdc_, address pips_) { usdc = MockERC20(usdc_); pips = MockERC20(pips_); }
    function buyPips(uint256 usdcAmount) external returns (uint256) {
        usdc.transferFrom(msg.sender, address(this), usdcAmount);
        uint256 out = usdcAmount * rate;
        pips.mint(address(this), out);
        pips.transfer(msg.sender, out);
        return out;
    }
}

contract MockSwapRouter {
    MockERC20 public usdc;
    MockERC20 public nut;
    uint256 public rate = 3; // 1 USDC -> 3 NUT
    constructor(address usdc_, address nut_) { usdc = MockERC20(usdc_); nut = MockERC20(nut_); }
    function swapExactTokensForTokens(
        uint256 amountIn, uint256, address[] calldata, address to, uint256
    ) external returns (uint256[] memory amounts) {
        usdc.transferFrom(msg.sender, address(this), amountIn);
        uint256 out = amountIn * rate;
        nut.mint(address(this), out);
        nut.transfer(to, out);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }
}

contract MockLpRouter {
    function addLiquidity(
        address, address, uint256 amountADesired, uint256 amountBDesired,
        uint256, uint256, address, uint256
    ) external returns (uint256, uint256, uint256) {
        uint256 liq = (amountADesired * amountBDesired) / 1e12;
        return (amountADesired, amountBDesired, liq);
    }
}

contract MockEAS {
    uint256 public attestCount;
    mapping(bytes32 => bool) public exists;
    function attest(AttestationRequest calldata request) external payable returns (bytes32 uid) {
        attestCount++;
        uid = keccak256(abi.encodePacked(attestCount, request.schema, request.data.recipient));
        exists[uid] = true;
    }
}
