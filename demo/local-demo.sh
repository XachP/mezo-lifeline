#!/usr/bin/env bash
# End-to-end demo on a local fork of Mezo testnet (real mUSD contracts, fake price feed).
# Shows: (1) a Lifeline trove survives a 45% BTC crash while an identical unguarded trove is liquidated;
# (2) the redemption guard moves a trove out of the front of mUSD's redemption queue before a 20k MUSD redemption.
# Needs: foundry (anvil/forge/cast), node 18+. Costs nothing: runs entirely on a local fork.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
FORK_URL=${FORK_URL:-https://rpc.test.mezo.org}
RPC=http://127.0.0.1:8545
BO=0xCdF7028ceAB81fA0C6971208e83fa7872994beE5
TM=0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0
PF=0x86bCF0841622a5dAC14A313a15f96A95421b9366
MUSD=0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503
ST=0x722E4D24FD6Ff8b0AC679450F3D91294607268fA
# anvil's well-known public test keys (never use on a real network)
DEPLOYER=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ALICE=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
BOB=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
KEEPER=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
LIQUIDATOR=0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a
CAROL=0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba
Z=0x0000000000000000000000000000000000000000
addr() { cast wallet address --private-key "$1"; }
# exact SortedTroves insert hints for a trove with collateral $1 and total debt $2 (wei): "upper lower"
hints() { local n; n=$(python3 -c "print($1*10**20//$2)"); local h; h=$(cast call 0x4e4cBA3779d56386ED43631b4dCD6d8EacEcBCF6 'getApproxHint(uint256,uint256,uint256)(address,uint256,uint256)' $n 40 42 -r $RPC | head -1); cast call $ST 'findInsertPosition(uint256,address,address)(address,address)' $n $h $h -r $RPC | tr '\n' ' '; }
# wait until the keeper has rescued vault $1
wait_rescued() { for i in $(seq 90); do cast call $1 'health()((uint8,uint256,uint256,uint256,uint256,bool,bool,uint256,uint256,uint256,uint256,uint256,uint256,bool))' -r $RPC 2>/dev/null | tr -d '()' | awk -F', ' '{exit ($7=="false")?0:1}' && return 0; sleep 1; done; return 1; }
say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; sleep "${PAUSE:-1}"; }

say "Forking Mezo testnet (chain 31611) locally"
anvil --fork-url "$FORK_URL" --port 8545 --silent --hardfork shanghai --gas-limit 60000000 --retries 10 --fork-retry-backoff 2000 &
ANVIL=$!; trap 'kill $ANVIL $KPID 2>/dev/null || true' EXIT; KPID=
for i in $(seq 60); do cast chain-id -r $RPC >/dev/null 2>&1 && break; sleep 1; done
cast chain-id -r $RPC >/dev/null 2>&1 || { echo "anvil fork failed to start (RPC hiccup?) - re-run"; exit 1; }
echo "Real mUSD contracts on the fork. MUSD supply: $(cast call $MUSD 'totalSupply()(uint256)' -r $RPC | cut -d' ' -f1 | cast from-wei | cut -d. -f1) MUSD, troves: $(cast call $TM 'getTroveOwnersCount()(uint256)' -r $RPC)"

say "Swapping Mezo's oracle precompile for a mock (so we can crash BTC on demand)"
ORACLE=$(forge create src/mocks/MockOracle.sol:MockOracle --broadcast -r $RPC --private-key $DEPLOYER --constructor-args 84000000000000000000000 | awk '/Deployed to/{print $3}')
cast rpc anvil_setStorageAt $PF 0x0 "0x000000000000000000000000${ORACLE:2}" -r $RPC >/dev/null
echo "BTC price: \$$(cast call $PF 'fetchPrice()(uint256)' -r $RPC | cut -d' ' -f1 | cast from-wei | cut -d. -f1)"

say "Deploying LifelineFactory (Lifeline: auto-rescue for MUSD troves)"
FACTORY=$(forge create src/LifelineFactory.sol:LifelineFactory --broadcast -r $RPC --private-key $DEPLOYER --constructor-args $BO $TM $PF $MUSD $ST | awk '/Deployed to/{print $3}')
echo "LifelineFactory: $FACTORY"

say "Alice creates a vault: protect below 130% ICR, restore to 160%, keeper tip 0.5% (max 0.0005 BTC)"
cast send $FACTORY 'createVault((uint64,uint64,uint16,uint128,uint128))' '(1300000000000000000,1600000000000000000,50,500000000000000,0)' -r $RPC --gas-limit 5000000 --private-key $ALICE >/dev/null
VAULT=$(cast call $FACTORY 'vaultsOfOwner(address)(address[])' $(addr $ALICE) -r $RPC | tr -d '[]')
echo "Alice's vault: $VAULT"

say "Alice opens a trove through the vault: 0.05 BTC collateral, borrows 2,000 MUSD; parks 0.04 BTC as rescue reserve"
cast send $VAULT 'openTrove(uint256,uint256,address,address)' 50000000000000000 2000000000000000000000 0x0000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000 --value 0.09ether -r $RPC --gas-limit 5000000 --private-key $ALICE >/dev/null
echo "Alice's MUSD balance: $(cast call $MUSD 'balanceOf(address)(uint256)' $(addr $ALICE) -r $RPC | cut -d' ' -f1 | cast from-wei)"

say "Bob opens the SAME trove directly on mUSD, with no Lifeline"
cast send $BO 'openTrove(uint256,address,address)' 2000000000000000000000 0x0000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000 --value 0.05ether -r $RPC --gas-limit 3000000 --private-key $BOB | grep -E '^(status|transactionHash)'
echo "Bob's ICR: $(cast call $TM 'getCurrentICR(address,uint256)(uint256)' $(addr $BOB) 84000000000000000000000 -r $RPC | cut -d' ' -f1 | cast from-wei | cut -c1-5) (same as Alice's)"

say "Starting the keeper bot (anyone can run one)"
(cd keeper && RPC_URL=$RPC FACTORY=$FACTORY KEEPER_PRIVATE_KEY=$KEEPER INTERVAL_MS=3000 node keeper.mjs) &
KPID=$!
sleep 4
(cd keeper && RPC_URL=$RPC node keeper.mjs --status $VAULT)

say "BTC crashes 45%: \$84,000 -> \$46,200. Both troves fall to ~105%, under the 110% liquidation line"
cast send $ORACLE 'setPrice(int256)' 46200000000000000000000 -r $RPC --private-key $DEPLOYER >/dev/null
sleep 3; wait_rescued $VAULT; sleep 1

say "Vault after the keeper's rescue"
(cd keeper && RPC_URL=$RPC node keeper.mjs --status $VAULT)

say "A liquidator tries both troves"
cast send $TM 'liquidate(address)' $(addr $BOB) -r $RPC --gas-limit 5000000 --private-key $LIQUIDATOR >/dev/null 2>&1 || true
cast send $TM 'liquidate(address)' $VAULT -r $RPC --gas-limit 5000000 --private-key $LIQUIDATOR >/dev/null 2>&1 || true
SB=$(cast call $TM 'getTroveStatus(address)(uint8)' $(addr $BOB) -r $RPC)
SA=$(cast call $TM 'getTroveStatus(address)(uint8)' $VAULT -r $RPC)
[ "$SB" = 3 ] && echo "Bob (no Lifeline):  LIQUIDATED. His 0.05 BTC collateral is gone." || echo "Bob: status $SB"
[ "$SA" = 1 ] && echo "Alice (guarded):    liquidation REVERTED. Trove still active at the 160% target." || echo "Alice: status $SA"
say "Part 2: the redemption guard. BTC recovers to \$84,000"
cast send $ORACLE 'setPrice(int256)' 84000000000000000000000 -r $RPC --private-key $DEPLOYER >/dev/null
echo "mUSD redeems MUSD for BTC from the LOWEST-ICR troves above 110% first. Real testnet troves sit at 114-131%."
say "Carol opens a vault at ~127% ICR (safe from liquidation) with a redemption guard: keep >= 25,000 MUSD of other debt ahead of me"
cast send $FACTORY 'createVault((uint64,uint64,uint16,uint128,uint128))' '(1200000000000000000,1300000000000000000,50,500000000000000,25000000000000000000000)' -r $RPC --gas-limit 5000000 --private-key $CAROL >/dev/null
CV=$(cast call $FACTORY 'vaultsOfOwner(address)(address[])' $(addr $CAROL) -r $RPC | tr -d '[]')
H=$(hints 33400000000000000 2202000000000000000000)
echo "Insert hints from HintHelpers + SortedTroves: $H (cuts openTrove gas from ~6.3M to ~0.66M on this list)"
cast send $CV 'openTrove(uint256,uint256,address,address)' 33400000000000000 2000000000000000000000 $H --value 0.0634ether -r $RPC --gas-limit 3000000 --private-key $CAROL >/dev/null
echo "Carol's trove is open at ~127%. The keeper notices she is at the front of the redemption queue..."
sleep 3; wait_rescued $CV; sleep 1
(cd keeper && RPC_URL=$RPC node keeper.mjs --status $CV)
say "A redeemer swaps 20,000 MUSD for BTC through mUSD's redemption mechanism"
cast send $BO 'openTrove(uint256,address,address)' 20500000000000000000000 $(hints 1500000000000000000 20720500000000000000000) --value 1.5ether -r $RPC --gas-limit 5000000 --private-key $DEPLOYER >/dev/null
C0=$(cast call $TM 'getTroveColl(address)(uint256)' $CV -r $RPC | cut -d' ' -f1)
PRICE=$(cast call $PF 'fetchPrice()(uint256)' -r $RPC | cut -d' ' -f1)
RH=($(cast call 0x4e4cBA3779d56386ED43631b4dCD6d8EacEcBCF6 'getRedemptionHints(uint256,uint256,uint256)(address,uint256,uint256)' 20000000000000000000000 $PRICE 50 -r $RPC | cut -d' ' -f1))
AH=$(cast call 0x4e4cBA3779d56386ED43631b4dCD6d8EacEcBCF6 'getApproxHint(uint256,uint256,uint256)(address,uint256,uint256)' ${RH[1]} 40 42 -r $RPC | head -1)
PH=$(cast call $ST 'findInsertPosition(uint256,address,address)(address,address)' ${RH[1]} $AH $AH -r $RPC | tr '\n' ' ')
cast send $TM 'redeemCollateral(uint256,address,address,address,uint256,uint256)' ${RH[2]} ${RH[0]} $PH ${RH[1]} 50 -r $RPC --gas-limit 20000000 --private-key $DEPLOYER | grep -E '^status' || echo "redemption tx failed"
C1=$(cast call $TM 'getTroveColl(address)(uint256)' $CV -r $RPC | cut -d' ' -f1)
echo "Redeemer MUSD left: $(cast call $MUSD 'balanceOf(address)(uint256)' $(addr $DEPLOYER) -r $RPC | cut -d' ' -f1 | cast from-wei | cut -d. -f1) (20,000 MUSD redeemed from other troves)"
[ "$C0" = "$C1" ] && echo "Carol (guarded):    collateral unchanged at $(cast from-wei $C1) BTC. The redemption never reached her." || echo "Carol collateral changed: $C0 -> $C1"
say "Done"
