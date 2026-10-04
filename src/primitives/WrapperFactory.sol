// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Wrapper} from "src/primitives/Wrapper.sol";

/**
 * @title WrapperFactory — permissionless wrap-any-token factory
 * @notice One call deploys a user-named 1:1 wrapper over any ERC-20 (BPTs included).
 *         The factory owns nothing, holds nothing, restricts nothing. Gas paid by the user.
 * @custom:security-contact see https://basednut.com
 */
contract WrapperFactory {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event WrapperCreated(
        address indexed wrapper, address indexed creator, address indexed underlying, string name, string symbol
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error WrapperFactory__NotAContract(address underlying);
    error WrapperFactory__EmptyName();
    error WrapperFactory__EmptySymbol();

    /*//////////////////////////////////////////////////////////////
                      USER-FACING STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy a 1:1 wrapper over an existing ERC-20.
    /// @param underlying ERC-20 to wrap (must be a contract; BPTs included).
    /// @param name   Wrapper name (nonempty).
    /// @param symbol Wrapper symbol (nonempty).
    /// @return wrapper Address of the deployed Wrapper.
    function create(address underlying, string calldata name, string calldata symbol)
        external
        returns (address wrapper)
    {
        if (underlying.code.length == 0) revert WrapperFactory__NotAContract(underlying);
        if (bytes(name).length == 0) revert WrapperFactory__EmptyName();
        if (bytes(symbol).length == 0) revert WrapperFactory__EmptySymbol();

        Wrapper newWrapper = new Wrapper(underlying, name, symbol);
        emit WrapperCreated(address(newWrapper), msg.sender, underlying, name, symbol);
        return wrapper = address(newWrapper);
    }
}
