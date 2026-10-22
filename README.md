# Lifeline

**A standing safety policy for MUSD troves on Mezo: liquidation protection and a redemption guard.**

You park a small BTC and/or MUSD *rescue reserve* next to your trove and set a rule once. When either of these happens, any keeper can call `protect()`:

1. **Liquidation risk.** BTC falls and your collateral ratio (ICR) drops under your trigger.
2. **Redemption risk.** Your trove drifts to the front of mUSD's redemption queue. mUSD redeems MUSD for BTC from the lowest-ICR troves at or above 110% first, so a trove at 127% that is nowhere near liquidation can still lose BTC.

`protect()` moves your reserve into **your own trove** until it is safe again, and pays the keeper a small tip that you cap. Keepers can't borrow, withdraw, or send funds anywhere else. The rule keeps working through every dip, not just once.

Built for the **Mezo Buildathon** (AKINDO). Tracks: **DeFi** (MUSD borrowing safety) and **Access & Distribution** (keeper and alert bot, browser dashboard).

| | |
|---|---|
| Contracts | `src/LifelineVault.sol`, `src/LifelineFactory.sol` (MIT, Solidity 0.8.24) |
| Integrates | mUSD `BorrowerOperations`, `TroveManager`, `PriceFeed`, `SortedTroves`, `HintHelpers`, `MUSD`. These are the real deployments, not forks of the protocol |
| Tests | **16 Foundry fork tests against the live mUSD deployment on Mezo testnet**. Run them with `forge test` |
| Demo | `demo/local-demo.sh` runs on a local fork. Part 1: a 45% BTC crash where the unprotected trove is liquidated and the Lifeline trove survives. Part 2: a 20,000 MUSD redemption hits other troves and leaves the guarded trove's BTC untouched ([sample output](demo/sample-output.txt)) |
| Keeper | `keeper/keeper.mjs`. A permissionless rescue bot that computes exact sorted-list hints, pauses on a stale oracle, and can send Telegram alerts |
| Dashboard | `docs/index.html` (GitHub Pages). It has a crash simulator, a **live redemption-queue radar**, wallet actions with exact hints, and a read-only vault watcher |
| Testnet | **Live on Mezo testnet**: LifelineFactory [`0x37aC7acd4e48b79bb0dc6AaCA5AF3611cF176149`](https://explorer.test.mezo.org/address/0x37aC7acd4e48b79bb0dc6AaCA5AF3611cF176149), demo vault [`0xC92BfDC83b03d32e39930Bfb789233e1Cc0fdbEF`](https://explorer.test.mezo.org/address/0xC92BfDC83b03d32e39930Bfb789233e1Cc0fdbEF) with real rescue txs (see "Deployments") |

## Why

MUSD is a Liquity-style CDP, which means two ways to lose BTC:

* **Liquidation.** A trove under **110% ICR** can be liquidated. If the whole system drops under 150% TCR (Recovery Mode), any trove under **150%** can be liquidated. Bitcoin regularly falls 20–30% in days, and interest slowly pulls ICR down.
* **Redemption.** Anyone can swap MUSD for BTC from the lowest-ICR troves at or above 110%. On Mezo testnet today, the front of the queue is at 114–131% ICR. At 127% ICR you have only **~18,600 MUSD** of other debt in front of you (live reading from the dashboard's radar on Oct 21, 2026), so one mid-sized redemption reaches your collateral.

Today the protection is to watch the chart and the queue, then top up by hand. Lifeline turns that into a rule: *"if my ICR drops below 130%, put my reserve in until it's back to 160%, and always keep at least 25,000 MUSD of other debt ahead of me in the redemption queue."* Anyone can enforce the rule, and no one can abuse it.

### How Lifeline compares to other approaches

| | Alerts only | Pre-signed one-shot rescue | **Lifeline** |
|---|---|---|---|
| Acts while you sleep | no | once | **every time the rule is broken** |
| Rescue with BTC (keep your MUSD) | – | repay only | **add BTC, or repay MUSD, or both** |
| Recovery Mode (150% line) | sometimes warns | no | **trigger auto-raised to 155%** |
| Redemption queue | monitor | monitor | **on-chain guard moves you behind a buffer** |
| Smart accounts / Passport | – | needs an EOA signature | **owner can be any address** |
| Gas on a 280-trove list | – | zero hints (millions of gas) | **exact HintHelpers hints (~0.66M vs 6.3M gas to open)** |

## How it works

1. `LifelineFactory.createVault(policy)` deploys a `LifelineVault` that you own. The policy has five fields: `triggerICR`, `targetICR`, `tipBps` (≤ 2%), `maxTipWei`, and `redemptionBufferMusd` (0 turns the guard off).
2. `vault.openTrove{value: coll + reserve}(coll, debt, upperHint, lowerHint)` makes the vault the **borrower of record**. The borrowed MUSD goes to you. Any BTC beyond `coll` stays in the vault as the reserve. `fundReserve` adds more BTC (msg.value) or MUSD (pulled from the caller).
3. `vault.health()` reports ICR, liquidation price, Recovery Mode, reserve, `redemptionSafeICR` and `redemptionRisk`. `needsProtection` is true when `ICR < trigger` **or** the trove is inside the redemption buffer.
4. Anyone calls `vault.protect(upperHint, lowerHint)`. The vault:
   * reads the mUSD price feed and Recovery Mode state;
   * picks the target: your target ICR, or for a redemption rescue, `redemptionSafeICR` + 1 point. The extra point stops rounding from triggering it again;
   * adds BTC from the reserve (`addColl`). If BTC runs short, it repays debt from the MUSD reserve (`repayMUSD`), never going below mUSD's min net debt;
   * reverts if the rescue can't lift the trove above 110% (or 150% in Recovery Mode), so keepers don't waste a partial rescue;
   * pays `min(tipBps × rescue size, maxTip)` to the caller and emits `Protected(..., redemptionGuard)`.
5. **The redemption guard** (`redemptionSafeICR`) walks `SortedTroves` from the lowest ICR upward, at most 60 steps, and adds up the debt of other redeemable troves until it reaches your buffer. Your safe ICR is that trove's ICR + 2 points. The result is capped at 250%, so a thin queue can't drain your reserve.
6. **Recovery-Mode aware.** When system TCR is under 150%, the effective trigger rises to ≥ 155% and the target to ≥ trigger + 10 points.
7. The owner keeps full control: `borrow`, `repay`, `withdrawColl`, `withdrawReserve`, `setPolicy`, `closeTrove` (returns all BTC and MUSD), and `claimAndSweep`.

### Security model
* Only the owner can move value **out** of the vault. `protect()` can only move the vault's own reserve **into the vault's own trove**, and only when the on-chain state shows it is needed.
* The tip is bounded twice: ≤ 2% by code and ≤ `maxTipWei` by the owner. The tip cap is held back from the rescue budget, so the rescue is never starved.
* `nonReentrant` guards every state-changing entry point. There are no upgrade keys and no admin.
* The price comes from mUSD's own `PriceFeed`, the same one that liquidations and redemptions use.
* Not audited. This is testnet software built for a buildathon.

## Try it

```bash
# 1) tests: fork Mezo testnet and run against the real mUSD contracts
forge install foundry-rs/forge-std   # first time only
forge test -vv

# 2) the crash + redemption demo (local fork, costs nothing)
cd keeper && npm ci && cd ..
./demo/local-demo.sh
```

On the fork, the test suite and demo mock only `PriceFeed`'s oracle. Mezo's oracle is a chain precompile that local forks can't execute, and the demo has to move the BTC price anyway. Everything else is the deployed mUSD system: 280+ real troves, the sorted list, interest, Recovery Mode, liquidations, and redemptions.

Expected demo result (abridged from `demo/sample-output.txt`):
```
== BTC crashes 45%: $84,000 -> $46,200 ...
RESCUE 0x81c6…: ICR 104.9% < trigger 130.0%
Lifeline rescued 0x81c6…: ICR 104.9% -> 160.0%, added 0.02626 BTC, keeper tip 0.00013 BTC
Bob (no Lifeline):  LIQUIDATED. His 0.05 BTC collateral is gone.
Alice (guarded):    liquidation REVERTED. Trove still active at the 160% target.
== Part 2: the redemption guard ...
RESCUE 0x8e9b…: front of the redemption queue (ICR 127.4% < safe 132.8%)
Lifeline rescued 0x8e9b… (redemption guard): ICR 127.4% -> 133.8%
== A redeemer swaps 20,000 MUSD for BTC ...
Carol (guarded):    collateral unchanged. The redemption never reached her.
```

### Run a keeper on Mezo testnet
```bash
cd keeper && npm ci
RPC_URL=https://rpc.test.mezo.org FACTORY=<factory> KEEPER_PRIVATE_KEY=<gas-only key> node keeper.mjs
node keeper.mjs --status <vault>          # read-only health check
# optional alerts: TELEGRAM_BOT_TOKEN=... TELEGRAM_CHAT_ID=...
```
The keeper:
* scans `LifelineFactory.scan()`;
* warns when a vault comes within 10 points of its trigger;
* simulates `protect()` and computes exact `HintHelpers`/`SortedTroves` insert hints;
* sends the rescue and posts every warning and rescue to Telegram if configured;
* pauses if the oracle is stale.

### Deploy
```bash
forge script script/Deploy.s.sol --rpc-url mezo_testnet --broadcast --private-key $DEPLOYER_KEY
```
Then put the factory address in `docs/config.js` to turn on the dashboard's write actions.

## Deployments
| Network | LifelineFactory |
|---|---|
| Mezo testnet (31611) | [`0x37aC7acd4e48b79bb0dc6AaCA5AF3611cF176149`](https://explorer.test.mezo.org/address/0x37aC7acd4e48b79bb0dc6AaCA5AF3611cF176149) |

**Live demo on Mezo testnet (real oracle, real trove list), Oct 22, 2026 UTC:**

| Step | Transaction |
|---|---|
| Deploy LifelineFactory | [0x4114…4cd6](https://explorer.test.mezo.org/tx/0x41146e9104744557b171f0ca949ec77eea0c800e93a4befa5e341914a0294cd6) |
| Create vault [`0xC92BfDC83b03d32e39930Bfb789233e1Cc0fdbEF`](https://explorer.test.mezo.org/address/0xC92BfDC83b03d32e39930Bfb789233e1Cc0fdbEF) (trigger 120%, target 130%, tip 0.5% capped at 0.0005 BTC, redemption buffer 25,000 MUSD) | [0x2311…c951](https://explorer.test.mezo.org/tx/0x2311c6345ff68888892aa76c7f5f139bffbd0e6e5a747439a04e98b8e091c951) |
| Open a 1,800 MUSD trove at **127.0% ICR** through the vault (exact hints) + 0.009 BTC reserve | [0xd624…9da0](https://explorer.test.mezo.org/tx/0xd624a32c5f10ab2e91c35783d7d4f0dd8b36b3d8a3738bc023f4ffa09af09da0) |
| **Redemption-guard lift** by the keeper: the trove sat at the front of the redemption queue (127.0% < safe 133.1%), lifted to 134.1% (+0.00168 BTC) | [0x2374…6e91](https://explorer.test.mezo.org/tx/0x2374b4b318d0f80c8b8ce4c5daec692d879825fdad7b26889693c1c389746e91) |
| Owner tightens the policy: trigger 140%, target 150% | [0xeb93…bdec](https://explorer.test.mezo.org/tx/0xeb93cddc6e5539bd463cd448b24f9e14671a859291d6e8e1450c9b16017dbdec) |
| **Trigger rescue** by the keeper: ICR 134.1% < trigger 140%, restored to exactly 150.0% (+0.00378 BTC) | [0x1470…13ea](https://explorer.test.mezo.org/tx/0x1470fdfb0b0ce434cf104feb5dd4869af458b4e70d55fb1d97fc2e032d1413ea) |

The live BTC price can't be crashed on demand, so the liquidation-trigger rescue is shown by raising the trigger above the current ICR. The 45% crash itself runs on a fork in `demo/local-demo.sh`. Check the vault any time: `node keeper/keeper.mjs --status 0xC92BfDC83b03d32e39930Bfb789233e1Cc0fdbEF` or the dashboard's watcher, which is pre-filled.

mUSD testnet addresses used (from `mezo-org/musd/solidity/deployments/matsnet`): BorrowerOperations `0xCdF7…beE5`, TroveManager `0xE47c…6bb0`, PriceFeed `0x86bC…9366`, SortedTroves `0x722E…68fA`, HintHelpers `0x4e4c…BCF6`, MUSD `0x1189…c503`.

## Test list (`test/LifelineFork.t.sol`, 16 tests)
- opening through the vault makes the vault the borrower, and the owner receives the MUSD
- `protect` reverts while healthy
- **a 45% crash: the unprotected twin trove gets liquidated; the Lifeline trove is restored to exactly 160% and can't be liquidated**
- MUSD-only reserve: the rescue repays debt instead of adding BTC
- Recovery Mode (real system TCR pushed under 150%): the trigger rises to 155%, and the trove is lifted to ≥ 165%
- a reserve too small to save the trove reverts with `ReserveTooSmall`
- only the owner can withdraw, borrow, close, or change the policy
- the keeper tip is capped; invalid policies are rejected
- `factory.scan()` finds at-risk vaults, and none after the rescue
- `health()` liquidation price math; `closeTrove` returns everything; `withdrawColl` and `borrow` pay the owner
- the redemption guard is off by default
- **the redemption guard, with a control: without the guard, a real 20,000 MUSD redemption against the live trove list takes the vault's BTC. With a 25k buffer, `protect()` lifts it behind the buffer, it does not trigger again, and the same redemption leaves its collateral untouched**
- the redemption guard reports healthy when the trove is already far enough back in the queue

## Roadmap (Wave 2)
- **Auto-deleverage without a reserve.** Sell a slice of collateral for MUSD on a Mezo pool and repay, for users who don't want idle BTC.
- **Earn on the reserve.** Hold the MUSD reserve in MUSD savings and redeem just in time.
- **One-click migration** of existing EOA troves into a vault, plus BorrowerOperationsSignatures support.
- Keeper incentives, a public keeper leaderboard, and a hosted alert bot. Mainnet deployment after review.

## AI disclosure
This project was designed, written, and tested with an AI coding agent working for the submitter. The submitter reviewed it and is responsible for it.

## License
MIT
