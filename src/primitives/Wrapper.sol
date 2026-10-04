// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Wrapper} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Wrapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Wrapper — factory-deployed 1:1 ERC-20 wrapper over any ERC-20
 * @notice Deployed exclusively by WrapperFactory. 1:1 depositFor/withdrawTo, decimals
 *         auto-inherit from the underlying, self-wrap reverts (OZ ERC20Wrapper).
 *         depositFor mints the MEASURED received amount, so fee-on-transfer underlyings
 *         quarantine into a solvent-but-lossy wrapper: totalSupply <= underlying custody
 *         ALWAYS holds (ARD-06 invariant). Non-transient ReentrancyGuard by design — the
 *         toolchain default EVM is paris; transient variant requires cancun.
 * @custom:security-contact see https://basednut.com
 */
contract Wrapper is ERC20Wrapper, ReentrancyGuard {
    using SafeERC20 for IERC20;

    constructor(address underlying_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC20Wrapper(IERC20(underlying_))
    {}

    /*//////////////////////////////////////////////////////////////
                      USER-FACING STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit underlying and mint the measured received amount (fee-on-transfer safe).
    function depositFor(address account, uint256 value) public virtual override nonReentrant returns (bool) {
        address sender = _msgSender();
        if (sender == address(this)) revert ERC20InvalidSender(address(this));
        if (account == address(this)) revert ERC20InvalidReceiver(account);

        IERC20 token = underlying();
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(sender, address(this), value);
        uint256 received = token.balanceOf(address(this)) - balanceBefore;

        _mint(account, received);
        return true;
    }

    /// @notice Burn wrapped tokens and withdraw the matching underlying amount (CEI: burn before transfer).
    function withdrawTo(address account, uint256 value) public virtual override nonReentrant returns (bool) {
        if (account == address(this)) revert ERC20InvalidReceiver(account);

        _burn(_msgSender(), value);
        underlying().safeTransfer(account, value);
        return true;
    }
}
