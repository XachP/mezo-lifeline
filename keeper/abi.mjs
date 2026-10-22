export const FACTORY_ABI = [
  "function vaultCount() view returns (uint256)",
  "function vaults(uint256) view returns (address)",
  "function vaultsOfOwner(address) view returns (address[])",
  "function scan(uint256 start, uint256 count) view returns (address[])",
  "function createVault((uint64 triggerICR,uint64 targetICR,uint16 tipBps,uint128 maxTipWei,uint128 redemptionBufferMusd) p) returns (address)",
  "event VaultCreated(address indexed owner, address vault, uint256 triggerICR, uint256 targetICR)",
];
export const VAULT_ABI = [
  "function owner() view returns (address)",
  "function policy() view returns (uint64 triggerICR,uint64 targetICR,uint16 tipBps,uint128 maxTipWei,uint128 redemptionBufferMusd)",
  "function health() view returns ((uint8 status,uint256 price,uint256 icr,uint256 trigger,uint256 target,bool recoveryMode,bool needsProtection,uint256 coll,uint256 debt,uint256 reserveBtc,uint256 reserveMusd,uint256 liquidationPrice,uint256 redemptionSafeICR,bool redemptionRisk))",
  "function protect(address upperHint, address lowerHint) returns (uint256 collAdded, uint256 musdRepaid, uint256 tip)",
  "function openTrove(uint256 collateral, uint256 debtAmount, address upperHint, address lowerHint) payable",
  "function fundReserve(uint256 musdAmount) payable",
  "function withdrawReserve(uint256 btc, uint256 musdAmount)",
  "event Protected(address indexed keeper, uint256 icrBefore, uint256 icrAfter, uint256 collAdded, uint256 musdRepaid, uint256 tip, bool recoveryMode, bool redemptionGuard)",
];
export const TM_ABI = ["function liquidate(address)", "function getTroveStatus(address) view returns (uint8)"];
export const TROVE_ABI = [
  "function getEntireDebtAndColl(address) view returns (uint256 coll,uint256 principal,uint256 interest,uint256 pendingCollateral,uint256 pendingPrincipal,uint256 pendingInterest)",
  "function getTroveOwnersCount() view returns (uint256)",
];
export const HINTS_ABI = ["function getApproxHint(uint256 cr,uint256 numTrials,uint256 seed) view returns (address hintAddress,uint256 diff,uint256 latestRandomSeed)"];
export const SORTED_ABI = ["function findInsertPosition(uint256 nicr,address prevId,address nextId) view returns (address,address)"];
// Mezo testnet (matsnet) mUSD deployment
export const MEZO_TESTNET = {
  troveManager: "0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0",
  hintHelpers: "0x4e4cBA3779d56386ED43631b4dCD6d8EacEcBCF6",
  sortedTroves: "0x722E4D24FD6Ff8b0AC679450F3D91294607268fA",
};
