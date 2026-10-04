// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {TokenFactory} from "src/primitives/TokenFactory.sol";
import {WrapperFactory} from "src/primitives/WrapperFactory.sol";

/**
 * @title DeployPrimitives — TokenFactory + WrapperFactory (Base Sepolia 84532)
 * @notice Broadcast account: hot wallet via forge keystore (no plaintext keys).
 *         Pre-GO gate: simulation only (no --broadcast).
 * @custom:security-contact see https://basednut.com
 */
contract DeployPrimitives is Script {
    function run() public returns (TokenFactory tokenFactory, WrapperFactory wrapperFactory) {
        vm.startBroadcast();
        tokenFactory = new TokenFactory();
        wrapperFactory = new WrapperFactory();
        vm.stopBroadcast();

        console2.log("TokenFactory:", address(tokenFactory));
        console2.log("WrapperFactory:", address(wrapperFactory));
    }
}
