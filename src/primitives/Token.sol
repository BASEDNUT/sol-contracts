// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title Token — factory-deployed fixed-supply ERC-20
 * @notice Deployed exclusively by TokenFactory. Supply is minted once, at construction,
 *         to the creator. No admin, no mint-after-deploy, no fees, no pausing — nothing to administer.
 * @custom:security-contact see https://basednut.com
 */
contract Token is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply_, address creator) ERC20(name_, symbol_) {
        _mint(creator, supply_);
    }
}
