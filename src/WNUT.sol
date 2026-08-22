// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Wrapper} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Wrapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
contract WNUT is ERC20Wrapper {
    constructor(address nut_) ERC20("Wrapped NUT", "wNUT") ERC20Wrapper(IERC20(nut_)) {}
}