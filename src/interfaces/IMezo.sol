// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Minimal interfaces for the mUSD protocol on Mezo (github.com/mezo-org/musd).
interface IBorrowerOperations {
    function openTrove(uint256 debtAmount, address upperHint, address lowerHint) external payable;
    function addColl(address upperHint, address lowerHint) external payable;
    function withdrawColl(uint256 amount, address upperHint, address lowerHint) external;
    function withdrawMUSD(uint256 amount, address upperHint, address lowerHint) external;
    function repayMUSD(uint256 amount, address upperHint, address lowerHint) external;
    /// @notice Collateral top-up (msg.value) and/or debt change in one trove update.
    ///         `_collWithdrawal` must be 0 when msg.value is positive. `_isDebtIncrease` false repays.
    function adjustTrove(
        uint256 collWithdrawal,
        uint256 debtChange,
        bool isDebtIncrease,
        address upperHint,
        address lowerHint
    ) external payable;
    function closeTrove() external;
    function claimCollateral() external;
    function minNetDebt() external view returns (uint256);
}

interface ITroveManager {
    function getCurrentICR(address borrower, uint256 price) external view returns (uint256);
    function getEntireDebtAndColl(address borrower)
        external
        view
        returns (
            uint256 coll,
            uint256 principal,
            uint256 interest,
            uint256 pendingCollateral,
            uint256 pendingPrincipal,
            uint256 pendingInterest
        );
    /// 0 nonExistent, 1 active, 2 closedByOwner, 3 closedByLiquidation, 4 closedByRedemption
    function getTroveStatus(address borrower) external view returns (uint8);
    function checkRecoveryMode(uint256 price) external view returns (bool);
    function getTCR(uint256 price) external view returns (uint256);
    function liquidate(address borrower) external;
    function redeemCollateral(
        uint256 amount,
        address firstRedemptionHint,
        address upperPartialRedemptionHint,
        address lowerPartialRedemptionHint,
        uint256 partialRedemptionHintNICR,
        uint256 maxIterations
    ) external;
}

interface IPriceFeed {
    function fetchPrice() external view returns (uint256);
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface ISortedTroves {
    function getLast() external view returns (address);
    function getFirst() external view returns (address);
    function getPrev(address id) external view returns (address);
    function getNext(address id) external view returns (address);
    function getSize() external view returns (uint256);
}

/// @notice Mezo MUSD Savings Rate. Deposits mint sMUSD 1:1; yield is separate and claimable.
///         Testnet proxy: 0x6f461c68B2c5492C0F5CCEc5a264d692aA7A8e16 (musdToken = matsnet MUSD).
interface IMUSDSavings {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function claimYield() external returns (uint256);
    function claimableYield(address holder) external view returns (uint256);
    function musdToken() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
}

interface IHintHelpers {
    function getApproxHint(uint256 cr, uint256 numTrials, uint256 inputRandomSeed)
        external
        view
        returns (address hintAddress, uint256 diff, uint256 latestRandomSeed);
}
