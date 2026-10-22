// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LifelineVault} from "./LifelineVault.sol";
import {IBorrowerOperations, ITroveManager, IPriceFeed, IERC20Min, ISortedTroves} from "./interfaces/IMezo.sol";

/// @title LifelineFactory
/// @notice Deploys one LifelineVault per user and keeps a registry so keepers can scan every vault.
contract LifelineFactory {
    IBorrowerOperations public immutable borrowerOperations;
    ITroveManager public immutable troveManager;
    IPriceFeed public immutable priceFeed;
    IERC20Min public immutable musd;
    ISortedTroves public immutable sortedTroves;

    address[] public vaults;
    mapping(address => address[]) public vaultsOf;

    event VaultCreated(address indexed owner, address vault, uint256 triggerICR, uint256 targetICR);

    constructor(IBorrowerOperations _bo, ITroveManager _tm, IPriceFeed _pf, IERC20Min _musd, ISortedTroves _st) {
        borrowerOperations = _bo;
        troveManager = _tm;
        priceFeed = _pf;
        musd = _musd;
        sortedTroves = _st;
    }

    function createVault(LifelineVault.Policy calldata p) external returns (LifelineVault v) {
        v = new LifelineVault(msg.sender, borrowerOperations, troveManager, priceFeed, musd, sortedTroves, p);
        vaults.push(address(v));
        vaultsOf[msg.sender].push(address(v));
        emit VaultCreated(msg.sender, address(v), p.triggerICR, p.targetICR);
    }

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    function vaultsOfOwner(address o) external view returns (address[] memory) {
        return vaultsOf[o];
    }

    /// @notice Keeper helper: which vaults in [start, start+count) need protection right now.
    function scan(uint256 start, uint256 count) external view returns (address[] memory hits) {
        uint256 end = start + count;
        if (end > vaults.length) end = vaults.length;
        address[] memory tmp = new address[](end > start ? end - start : 0);
        uint256 n;
        uint256 price = priceFeed.fetchPrice();
        bool rm = troveManager.checkRecoveryMode(price);
        for (uint256 i = start; i < end; i++) {
            LifelineVault v = LifelineVault(payable(vaults[i]));
            if (troveManager.getTroveStatus(address(v)) != 1) continue;
            (uint256 trigger,) = v.effectiveThresholds(rm);
            uint256 icr = troveManager.getCurrentICR(address(v), price);
            uint256 safe = v.redemptionSafeICR(price);
            if (icr < trigger || (safe != 0 && icr < safe)) tmp[n++] = address(v);
        }
        hits = new address[](n);
        for (uint256 j; j < n; j++) hits[j] = tmp[j];
    }
}
