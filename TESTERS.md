# Testing Lifeline

Two different things are easy to mix up. This page keeps them apart.

## What is live today (Wave 1)

The public Mezo testnet frontend and the contracts it talks to are the **Wave 1** deployment. Nothing in this repository has replaced them.

| | |
|---|---|
| Dashboard | GitHub Pages, driven by [`docs/config.js`](docs/config.js) |
| Chain | Mezo testnet, chain id 31611, RPC `https://rpc.test.mezo.org` |
| LifelineFactory | [`0x37aC7acd4e48b79bb0dc6AaCA5AF3611cF176149`](https://explorer.test.mezo.org/address/0x37aC7acd4e48b79bb0dc6AaCA5AF3611cF176149) |
| Demo vault | [`0xC92BfDC83b03d32e39930Bfb789233e1Cc0fdbEF`](https://explorer.test.mezo.org/address/0xC92BfDC83b03d32e39930Bfb789233e1Cc0fdbEF) |

That factory and that vault are the October 2026 deployment. They do **not** include the Wave 2 contract behavior: one `adjustTrove` rescue, the 110% liquidation line in Recovery Mode, sMUSD savings, or `ExternalKeeper`.

`docs/config.js` still names those Wave 1 addresses. A fresh deploy has not been broadcast from the current contracts, and this repo does not claim one.

Use testnet BTC from [faucet.test.mezo.org](https://faucet.test.mezo.org/). Do not send mainnet funds.

What you can exercise on the live frontend:

- Crash simulator and redemption-queue radar (read-only, no wallet).
- Connect a wallet on Mezo testnet, create a vault from the **live** factory, open a trove, fund a BTC reserve, refresh `health()`, and call `protect()`.
- Read-only watcher, pre-filled with the demo vault above.
- `node keeper/keeper.mjs --status 0xC92BfDC83b03d32e39930Bfb789233e1Cc0fdbEF` against the live demo vault.

A rescue on that deployment can add BTC and repay MUSD in separate calls. It will not deposit to the MUSD Savings Vault, and it still follows the Wave 1 Recovery Mode behavior baked into those verified contracts.

## What Wave 2 is (code in this repo, not a public deployment)

Wave 2 is the current Solidity in `src/`. It is what `forge test` runs against a **local fork** of Mezo testnet. It is not what the dashboard writes to.

Included in that code, and not in the live factory above:

- Liquidation only below 110% ICR, including while the system is in Recovery Mode.
- `protect()` applies collateral and repayment in one `adjustTrove`.
- Idle MUSD can be deposited to the existing Mezo MUSD Savings Rate vault (`0x6f461c68B2c5492C0F5CCEc5a264d692aA7A8e16`). sMUSD there is 1:1 principal. Yield is claimed from the vault's own index. Lifeline does not look up a market price for sMUSD.
- `ExternalKeeper`, a separate contract whose only vault call is `protect()`.

Until someone broadcasts `script/Deploy.s.sol` and then deliberately updates `docs/config.js`, testers should treat Wave 2 as local-only:

```bash
forge install foundry-rs/forge-std   # first time only
forge test -vv
```

The fork uses the real mUSD contracts and the real savings vault. It does not spend testnet or mainnet funds. `demo/local-demo.sh` is the same kind of local fork.

`script/Deploy.s.sol` can deploy a new factory and `ExternalKeeper` and print a config block. Running that script, broadcasting it, and editing `docs/config.js` are separate steps. This file does not record that they have been done. If `DEMO_VAULT` is unset, the script does not invent a demo vault address.

## How to report

Open a GitHub issue with the **Tester report** template (`.github/ISSUE_TEMPLATE/tester-report.yml`).

Say which surface you used:

1. **Live Wave 1** — the public dashboard and the addresses in the table above.
2. **Wave 2 on a local fork** — `forge test`, `demo/local-demo.sh`, or a contract you deployed yourself and have not pointed the dashboard at.

Include the transaction hash for anything you sent, the vault address, and what you expected. A report against the live demo vault is a Wave 1 report even if you have the Wave 2 source checked out.
