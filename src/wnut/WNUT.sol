// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Wrapper} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Wrapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title WNUT — Wrapped NUT
 * @notice Standard WETH9-model wrapper: bare OZ ERC20Wrapper, no admin, no owner,
 *         no rescue, no upgrade path. Mint only via depositFor (NUT pulled before mint),
 *         burn only via withdrawTo (burned before release). Both permissionless.
 *         Underlying NUT is verified immutable 18-decimal pure ERC-20; decimals mirror
 *         underlying via OZ. Accidentally-sent tokens are permanently stranded (WETH parity).
 */
contract WNUT is ERC20Wrapper {
    constructor(address nut_) ERC20("Wrapped NUT", "wNUT") ERC20Wrapper(IERC20(nut_)) {}
}
