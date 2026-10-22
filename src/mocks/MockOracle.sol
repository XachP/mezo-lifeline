// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice LOCAL DEMO ONLY. Chainlink-style oracle used to replace Mezo's oracle precompile on an
///         anvil fork (precompiles don't exist off-chain), so the demo can "crash" the BTC price.
contract MockOracle {
    int256 public price;
    address public immutable admin;

    constructor(int256 p) {
        price = p;
        admin = msg.sender;
    }

    function setPrice(int256 p) external {
        require(msg.sender == admin, "admin");
        price = p;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, block.timestamp, block.timestamp, 1);
    }
}
