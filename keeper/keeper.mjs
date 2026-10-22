#!/usr/bin/env node
// Lifeline keeper: scans every LifelineVault and calls protect() on the ones at risk.
// Anyone can run it; the only thing a keeper can do is push the vault's own reserve into the
// vault's own trove, and it earns the capped tip set by the vault owner.
//
//   RPC_URL=https://rpc.test.mezo.org FACTORY=0x... KEEPER_PRIVATE_KEY=0x... node keeper.mjs
//   node keeper.mjs --status 0xVault      # print one vault's health and exit (no key needed)
//   node keeper.mjs --once                # one scan + rescue pass, then exit
// Optional alerts: TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID -> a message for every warning/rescue.
import { ethers } from "ethers";
import { FACTORY_ABI, VAULT_ABI, TROVE_ABI, HINTS_ABI, SORTED_ABI, MEZO_TESTNET } from "./abi.mjs";

const RPC_URL = process.env.RPC_URL || "https://rpc.test.mezo.org";
const FACTORY = process.env.FACTORY;
const INTERVAL = Number(process.env.INTERVAL_MS || 15000);
const WARN_MARGIN = BigInt(process.env.WARN_MARGIN_BPS || 1000) * 10n ** 14n; // warn 10 pts above trigger
const args = process.argv.slice(2);

const provider = new ethers.JsonRpcProvider(RPC_URL);
const pct = (x) => (Number(ethers.formatUnits(x, 16))).toFixed(1) + "%";
const usd = (x) => "$" + Number(ethers.formatUnits(x, 18)).toLocaleString("en-US", { maximumFractionDigits: 0 });
const btc = (x) => Number(ethers.formatUnits(x, 18)).toFixed(5) + " BTC";
const ts = () => new Date().toISOString().slice(11, 19);
const log = (...a) => console.log(`[${ts()}]`, ...a);

async function notify(text) {
  const { TELEGRAM_BOT_TOKEN: t, TELEGRAM_CHAT_ID: c } = process.env;
  if (!t || !c) return;
  try {
    await fetch(`https://api.telegram.org/bot${t}/sendMessage`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ chat_id: c, text }),
    });
  } catch (e) { log("telegram error:", e.message); }
}

export function describe(addr, h) {
  if (Number(h.status) !== 1) return `${addr}  no active trove (status ${h.status})`;
  return [
    `${addr}`,
    `  BTC price ${usd(h.price)}${h.recoveryMode ? "  ** SYSTEM IN RECOVERY MODE **" : ""}`,
    `  ICR ${pct(h.icr)}  (trigger ${pct(h.trigger)}, target ${pct(h.target)})  ${h.needsProtection ? "AT RISK" : "ok"}`,
    `  collateral ${btc(h.coll)}  debt ${Number(ethers.formatUnits(h.debt, 18)).toFixed(2)} MUSD  liquidation price ${usd(h.liquidationPrice)}`,
    `  rescue reserve ${btc(h.reserveBtc)} + ${Number(ethers.formatUnits(h.reserveMusd, 18)).toFixed(2)} MUSD`,
    h.redemptionSafeICR > 0n
      ? `  redemption guard: needs ICR >= ${pct(h.redemptionSafeICR)} to stay behind the buffer  ${h.redemptionRisk ? "REDEMPTION RISK" : "ok"}`
      : `  redemption guard: off`,
  ].join("\n");
}

// Exact insert hints for the post-rescue position: cheaper than (0,0), which makes SortedTroves walk the list.
async function hintsFor(v, addr) {
  try {
    const [added, repaid] = await v.protect.staticCall(ethers.ZeroAddress, ethers.ZeroAddress);
    const tm = new ethers.Contract(process.env.TROVE_MANAGER || MEZO_TESTNET.troveManager, TROVE_ABI, provider);
    const d = await tm.getEntireDebtAndColl(addr);
    const coll = d.coll + added;
    const principal = d.principal - (repaid > d.interest ? repaid - d.interest : 0n);
    const nicr = (coll * 10n ** 20n) / principal;
    const n = await tm.getTroveOwnersCount();
    const trials = BigInt(Math.min(40, Math.ceil(15 * Math.sqrt(Number(n)))));
    const hh = new ethers.Contract(process.env.HINT_HELPERS || MEZO_TESTNET.hintHelpers, HINTS_ABI, provider);
    const [approx] = await hh.getApproxHint(nicr, trials, 42n);
    const st = new ethers.Contract(process.env.SORTED_TROVES || MEZO_TESTNET.sortedTroves, SORTED_ABI, provider);
    const [up, low] = await st.findInsertPosition(nicr, approx, approx);
    return [up, low];
  } catch (e) {
    return [ethers.ZeroAddress, ethers.ZeroAddress];
  }
}

async function status(addr) {
  const v = new ethers.Contract(addr, VAULT_ABI, provider);
  console.log(describe(addr, await v.health()));
}

const warned = new Set();

async function pass(wallet) {
  const f = new ethers.Contract(FACTORY, FACTORY_ABI, provider);
  const n = Number(await f.vaultCount());
  const atRisk = n ? await f.scan(0, n) : [];
  // early warnings (close to trigger but not yet below)
  for (let i = 0; i < n; i++) {
    const addr = await f.vaults(i);
    const h = await new ethers.Contract(addr, VAULT_ABI, provider).health();
    if (Number(h.status) !== 1) continue;
    const near = h.icr < h.trigger + WARN_MARGIN && !h.needsProtection;
    if (near && !warned.has(addr)) {
      warned.add(addr);
      const msg = `Lifeline warning: vault ${addr} ICR ${pct(h.icr)} is within 10 pts of its ${pct(h.trigger)} trigger (BTC ${usd(h.price)}).`;
      log(msg); await notify(msg);
    } else if (!near) warned.delete(addr);
  }
  log(`scanned ${n} vault(s), ${atRisk.length} at risk`);
  for (const addr of atRisk) {
    const v = new ethers.Contract(addr, VAULT_ABI, wallet);
    const before = await v.health();
    const why = before.redemptionRisk && before.icr >= before.trigger
      ? `front of the redemption queue (ICR ${pct(before.icr)} < safe ${pct(before.redemptionSafeICR)})`
      : `ICR ${pct(before.icr)} < trigger ${pct(before.trigger)}`;
    log(`RESCUE ${addr}: ${why}`);
    try {
      const [up, low] = await hintsFor(v, addr);
      const tx = await v.protect(up, low);
      const rc = await tx.wait();
      const ev = rc.logs.map((l) => { try { return v.interface.parseLog(l); } catch { return null; } }).find((e) => e && e.name === "Protected");
      const a = ev.args;
      const msg = `Lifeline rescued ${addr}${a.redemptionGuard ? " (redemption guard)" : ""}: ICR ${pct(a.icrBefore)} -> ${pct(a.icrAfter)}, added ${btc(a.collAdded)}, repaid ${Number(ethers.formatUnits(a.musdRepaid, 18)).toFixed(2)} MUSD, keeper tip ${btc(a.tip)}. tx ${rc.hash}`;
      log(msg); await notify(msg);
    } catch (e) {
      const msg = `Lifeline could NOT rescue ${addr}: ${e.shortMessage || e.message}. Owner should add reserve or repay now.`;
      log(msg); await notify(msg);
    }
  }
}

async function main() {
  if (args[0] === "--status") return status(args[1]);
  if (!FACTORY) throw new Error("set FACTORY=0x... (LifelineFactory address)");
  if (!process.env.KEEPER_PRIVATE_KEY) throw new Error("set KEEPER_PRIVATE_KEY (gas only, holds no user funds)");
  const wallet = new ethers.Wallet(process.env.KEEPER_PRIVATE_KEY, provider);
  log(`keeper ${wallet.address} watching factory ${FACTORY} on ${RPC_URL}`);
  if (args.includes("--once")) return pass(wallet);
  for (;;) {
    try { await pass(wallet); } catch (e) {
      const m = e.shortMessage || e.message || "";
      // mUSD's PriceFeed reverts when the oracle is > 60 s old. Never act on a guessed price.
      if (/stale/i.test(m) || /Oracle/i.test(String(e.data || e.reason || ""))) log("oracle stale: keeper paused this round");
      else log("pass error:", m);
    }
    await new Promise((r) => setTimeout(r, INTERVAL));
  }
}

main().catch((e) => { console.error(e.shortMessage || e.message); process.exit(1); });
