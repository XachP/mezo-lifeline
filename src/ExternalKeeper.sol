// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LifelineVault} from "./LifelineVault.sol";

/// @title ExternalKeeper
/// @notice A third-party contract that calls `LifelineVault.protect()`. It has no right to
///         withdraw, borrow, or close the vault. The keeper tip is paid here, and only the
///         operator can withdraw that BTC.
contract ExternalKeeper {
    address public immutable operator;

    event Rescued(
        address indexed vault, address indexed caller, uint256 collAdded, uint256 musdRepaid, uint256 tip
    );

    error NotOperator();
    error TransferFailed();

    constructor(address _operator) {
        operator = _operator;
    }

    receive() external payable {}

    /// @notice Run the vault's rescue. Anyone may call; the tip lands in this contract.
    function rescue(LifelineVault vault, address upperHint, address lowerHint)
        external
        returns (uint256 collAdded, uint256 musdRepaid, uint256 tip)
    {
        (collAdded, musdRepaid, tip) = vault.protect(upperHint, lowerHint);
        emit Rescued(address(vault), msg.sender, collAdded, musdRepaid, tip);
    }

    /// @notice Send this contract's BTC (keeper tips) to `to`. Operator only.
    function withdrawTip(address payable to) external {
        if (msg.sender != operator) revert NotOperator();
        uint256 bal = address(this).balance;
        (bool ok,) = to.call{value: bal}("");
        if (!ok) revert TransferFailed();
    }
}
