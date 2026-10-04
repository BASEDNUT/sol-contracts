// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Token} from "src/primitives/Token.sol";

/**
 * @title TokenFactory — permissionless fixed-supply ERC-20 minter
 * @notice One call deploys a user-named, fixed-supply ERC-20 to the caller.
 *         The factory owns nothing, holds nothing, restricts nothing. Gas paid by the user.
 * @custom:security-contact see https://basednut.com
 */
contract TokenFactory {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event TokenCreated(address indexed token, address indexed creator, string name, string symbol, uint256 supply);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error TokenFactory__ZeroSupply();
    error TokenFactory__EmptyName();
    error TokenFactory__EmptySymbol();

    /*//////////////////////////////////////////////////////////////
                      USER-FACING STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy a fixed-supply ERC-20 with the full supply minted to the caller.
    /// @param name   Token name (nonempty).
    /// @param symbol Token symbol (nonempty).
    /// @param supply Total supply minted once at construction (must be > 0).
    /// @return token Address of the deployed Token.
    function create(string calldata name, string calldata symbol, uint256 supply)
        external
        returns (address token)
    {
        if (supply == 0) revert TokenFactory__ZeroSupply();
        if (bytes(name).length == 0) revert TokenFactory__EmptyName();
        if (bytes(symbol).length == 0) revert TokenFactory__EmptySymbol();

        Token newToken = new Token(name, symbol, supply, msg.sender);
        emit TokenCreated(address(newToken), msg.sender, name, symbol, supply);
        return token = address(newToken);
    }
}
