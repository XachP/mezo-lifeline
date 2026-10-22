// Filled in after `forge script script/Deploy.s.sol --rpc-url mezo_testnet --broadcast`.
window.GUARDIAN_CONFIG = {
  chainId: 31611,
  chainName: "Mezo Testnet",
  rpcUrl: "https://rpc.test.mezo.org",
  explorer: "https://explorer.test.mezo.org",
  factory: "0x37aC7acd4e48b79bb0dc6AaCA5AF3611cF176149", // LifelineFactory on Mezo testnet
  demoVault: "0xC92BfDC83b03d32e39930Bfb789233e1Cc0fdbEF", // live demo vault (pre-filled in the watcher)
  musd: "0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503",
  priceFeed: "0x86bCF0841622a5dAC14A313a15f96A95421b9366",
  troveManager: "0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0",
  sortedTroves: "0x722E4D24FD6Ff8b0AC679450F3D91294607268fA",
  hintHelpers: "0x4e4cBA3779d56386ED43631b4dCD6d8EacEcBCF6",
};
