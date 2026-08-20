// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Wrapper} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Wrapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title WNUT — Wrapped NUT
 * @notice 1:1 ERC-20 wrapper over NUT (18 decimals). Custodies NUT, reissues wNUT.
 *         Immutable. No governance, no pausing, no upgradeability.
 *         Direct NUT transfers do NOT mint wNUT — owner-only recoverSurplus() handles surplus.
 */
contract WNUT is ERC20Wrapper, Ownable2Step {
    using SafeERC20 for IERC20;

    IERC20 public immutable nut;

    event Recovered(address indexed token, address indexed to, uint256 amount);
    event SurplusRecovered(address indexed to, uint256 amount);

    constructor(address nut_)
        ERC20("Wrapped NUT", "wNUT")
        ERC20Wrapper(IERC20(nut_))
        Ownable(msg.sender)
    {
        require(nut_ != address(0), "WNUT: zero NUT");
        require(nut_.code.length > 0, "WNUT: NUT not a contract");
        nut = IERC20(nut_);
    }

    /// @notice Recover accidentally sent ERC-20s (never NUT or wNUT itself).
    function recover(address token) external onlyOwner returns (uint256) {
        require(token != address(nut), "WNUT: cannot recover NUT (use recoverSurplus)");
        require(token != address(this), "WNUT: cannot recover wNUT");
        uint256 bal = IERC20(token).balanceOf(address(this));
        require(bal > 0, "WNUT: nothing to recover");
        IERC20(token).safeTransfer(owner(), bal);
        emit Recovered(token, owner(), bal);
        return bal;
    }

    /// @notice Mint wNUT to owner covering direct NUT transfers or rebasing surplus.
    function recoverSurplus() external onlyOwner returns (uint256) {
        uint256 amount = _recover(owner());
        require(amount > 0, "WNUT: no surplus");
        emit SurplusRecovered(owner(), amount);
        return amount;
    }

    /// @notice Underlying NUT address.
    function underlyingNUT() external view returns (address) {
        return address(nut);
    }
}
