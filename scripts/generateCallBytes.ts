/**
 * generateCallBytes.ts
 *
 * Generates SCALE-encoded call bytes for:
 *   1. Bifrost SLPx.mint  (DOT → vDOT)
 *   2. Hydration Omnipool.sell (DOT → USDT hedge)
 *
 * Uses @polkadot/api for live RPC encoding.
 *
 * ─── Why @polkadot/api? ───────────────────────────────────────────────────
 *
 *  polkadot-api (PAPI) is the modern replacement and was the original choice,
 *  but Bifrost and Hydration nodes do not yet support the new `chainHead_v1`
 *  JSON-RPC spec that PAPI requires for live transaction encoding.
 *  (@polkadot-api/polkadot-sdk-compat helps for most chains, but the
 *  metadata checksum verification still fails on these specific parachains.)
 *
 *  @polkadot/api connects over the legacy `state_*` / `chain_*` JSON-RPC
 *  endpoints that Bifrost and Hydration fully support.
 *
 *  The SCALE bytes produced are identical — encoding is encoding.
 *
 * ─── Usage ───────────────────────────────────────────────────────────────
 *
 *   npx ts-node scripts/generateCallBytes.ts
 *   # or
 *   npm run gen:callbytes
 *
 * Output: hex-encoded call bytes for Bifrost and Hydration.
 * Paste into .env as BIFROST_MINT_CALL and HYDRATION_ROUTER_SELL_CALL.
 */

import { ApiPromise, WsProvider } from "@polkadot/api";
import * as dotenv from "dotenv";

dotenv.config();

// ─────────────────────────────────────────────────────────────────────────────
// RPC Endpoints (mainnet)
// ─────────────────────────────────────────────────────────────────────────────

const BIFROST_RPCS = [
  "wss://eu.bifrost-polkadot-rpc.liebi.com/ws",
  "wss://bifrost-polkadot.api.onfinality.io/public-ws",
];

const HYDRATION_RPCS = [
  "wss://hydration.dotters.network",
  "wss://rpc.hydradx.io",
  "wss://hydradx-rpc.dwellir.com",
];

// ─────────────────────────────────────────────────────────────────────────────
// Configuration
// ─────────────────────────────────────────────────────────────────────────────

// 32-byte substrate account of the vault on Bifrost/Hydration.
// Set VAULT_SUBSTRATE_ACCOUNT in .env after deploying CarryTradeVault.
const VAULT_SUBSTRATE_ACCOUNT =
  process.env.VAULT_SUBSTRATE_ACCOUNT ??
  "0x0000000000000000000000000000000000000000000000000000000000000001";

// DOT amount for the call bytes (in 10-decimal Substrate planck units).
// Set DOT_AMOUNT_PLANCK in .env to match the actual deposit amount.
// IMPORTANT: Regenerate call bytes before each executeCarry() call!
// Example: 50 DOT = 500_000_000_000 planck (50 * 1e10)
const DOT_AMOUNT_PLANCK = BigInt(
  process.env.DOT_AMOUNT_PLANCK ?? "10000000000" // default: 1 DOT = 1e10 planck
);

// Hydration asset IDs (from Hydration runtime asset registry)
// NOTE: DOT (5) and USDT (10) are NOT in Hydration's Omnipool directly.
// They trade via the Router which multi-hops:
//   DOT(5) → aDOT(1001) [Aave pool] → LRNA(102) [Omnipool] → USDT(10) [StableSwap 102]
// Use router.sell (not omnipool.sell) to let the chain resolve the route automatically.
const HYDRATION_DOT_ASSET_ID  = 5;    // DOT (Polkadot native)
const HYDRATION_USDT_ASSET_ID = 10;   // Tether USDT

// ─────────────────────────────────────────────────────────────────────────────
// Helper: connect with fallback endpoints
// ─────────────────────────────────────────────────────────────────────────────

async function connectWithFallback(
  chainName: string,
  endpoints: string[],
  timeoutMs = 20_000
): Promise<ApiPromise> {
  for (const url of endpoints) {
    console.log(`  Trying ${url}...`);
    try {
      const provider = new WsProvider(url, false);
      await provider.connect();
      const api = await Promise.race([
        ApiPromise.create({ provider, noInitWarn: true }),
        new Promise<never>((_, rej) =>
          setTimeout(() => rej(new Error(`timeout after ${timeoutMs / 1000}s`)), timeoutMs)
        ),
      ]);
      console.log(`  Connected to ${chainName}`);
      return api;
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      console.log(`  ❌ ${msg}`);
    }
  }
  throw new Error(`All endpoints failed for ${chainName}`);
}

// ─────────────────────────────────────────────────────────────────────────────
// Bifrost: encode SLPx.mint call
// ─────────────────────────────────────────────────────────────────────────────

async function getBifrostMintCallBytes(): Promise<string> {
  console.log("\nConnecting to Bifrost...");
  const api = await connectWithFallback("Bifrost", BIFROST_RPCS);

  // ── SLPx.mint ──────────────────────────────────────────────────────────────
  //
  //  Rust signature:
  //    pub fn mint(
  //      origin,
  //      currency_id: CurrencyId,        // Token2(0) = DOT on Polkadot
  //      currency_amount: Balance,        // u128
  //      target_chain: TargetChain,       // AssetHub(AccountId32)
  //      remark: BoundedVec<u8, 32>,
  //      channel_id: u32,
  //    )
  //
  //  @polkadot/api encodes enum variants as { Token2: 0 }, { AssetHub: accountId }
  const mintCall = api.tx.slpx.mint(
    { Token2: 0 },                             // CurrencyId::Token2(0) = DOT
    DOT_AMOUNT_PLANCK,
    { AssetHub: VAULT_SUBSTRATE_ACCOUNT },     // target chain + 32-byte receiver
    new Uint8Array(0),                         // empty remark
    0                                          // channel_id
  );

  // .method.toHex() = pallet_index ++ call_index ++ SCALE(args)
  // Exactly what goes in the XCM Transact instruction's `call` field.
  const callHex = mintCall.method.toHex();

  const chainName = (await api.rpc.system.chain()).toString();
  console.log(`  Chain: ${chainName}`);
  console.log(`\n✅ Bifrost SLPx.mint call bytes:`);
  console.log(`   ${callHex}`);
  console.log(`   Length: ${Buffer.from(callHex.slice(2), "hex").length} bytes`);

  await api.disconnect();
  return callHex;
}

// ─────────────────────────────────────────────────────────────────────────────
// Hydration: encode Router.sell call (DOT → USDT via multi-hop)
// ─────────────────────────────────────────────────────────────────────────────

async function getHydrationSellCallBytes(): Promise<string> {
  console.log("\nConnecting to Hydration...");
  const api = await connectWithFallback("Hydration", HYDRATION_RPCS);

  // ── Router.sell ────────────────────────────────────────────────────────────
  //
  //  WHY NOT omnipool.sell?
  //  DOT (id=5) and USDT (id=10) are NOT direct Omnipool assets on Hydration.
  //  Calling omnipool.sell(5, 10, ...) would fail with an AssetNotFound error.
  //
  //  The Router pallet handles multi-hop routing automatically.
  //  On-chain stored route for DOT→USDT:
  //    DOT(5) → aDOT(1001) [Aave lending pool]
  //           → LRNA(102) [Omnipool hub]
  //           → USDT(10)  [StableSwap pool 102]
  //
  //  Rust signature:
  //    pub fn sell(
  //      origin,
  //      asset_in: T::AssetId,       // u32 — DOT = 5
  //      asset_out: T::AssetId,      // u32 — USDT = 10
  //      amount_in: T::Balance,      // u128
  //      min_amount_out: T::Balance, // u128 — slippage floor
  //      route: Vec<Trade<T>>,       // [] = use on-chain stored route automatically
  //    )
  //
  //  Passing an empty route ([]) makes the router use the pre-registered
  //  on-chain route, which is the most gas-efficient approach.
  const sellCall = api.tx.router.sell(
    HYDRATION_DOT_ASSET_ID,          // asset_in  = DOT (5)
    HYDRATION_USDT_ASSET_ID,         // asset_out = USDT (10)
    DOT_AMOUNT_PLANCK,
    0n,                              // min_amount_out — set slippage floor for mainnet
    []                               // route = [] → use stored on-chain route
  );

  const callHex = sellCall.method.toHex();

  const chainName = (await api.rpc.system.chain()).toString();
  console.log(`  Chain: ${chainName}`);
  console.log(`\n✅ Hydration Router.sell (DOT→USDT) call bytes:`);
  console.log(`   ${callHex}`);
  console.log(`   Length: ${Buffer.from(callHex.slice(2), "hex").length} bytes`);
  console.log(`   Route: DOT(5) → aDOT(1001)[aave] → LRNA(102)[omnipool] → USDT(10)[stableswap]`);

  await api.disconnect();
  return callHex;
}

// ─────────────────────────────────────────────────────────────────────────────
// Bonus: decode call bytes back to human-readable form for verification
// ─────────────────────────────────────────────────────────────────────────────

async function verifyEncoding(callHex: string, endpoints: string[]): Promise<void> {
  try {
    const api = await connectWithFallback("verify", endpoints, 10_000);
    const call = api.createType("Call", callHex);
    console.log(`\n🔍 Round-trip verification:`);
    console.log(`   section: ${call.section}`);
    console.log(`   method:  ${call.method}`);
    console.log(`   args:    ${call.args.map((a) => a.toString()).join(", ")}`);
    await api.disconnect();
  } catch {
    // Non-fatal: verification is a bonus
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Main
// ─────────────────────────────────────────────────────────────────────────────

async function main() {
  console.log("=".repeat(62));
  console.log(" CarryTradeVault — SCALE Call Byte Generator");
  console.log("=".repeat(62));
  console.log(`Vault substrate account: ${VAULT_SUBSTRATE_ACCOUNT}`);

  // ── Fetch call bytes ───────────────────────────────────────────────────────

  let bifrostCallBytes = "";
  let hydrationCallBytes = "";

  try {
    bifrostCallBytes = await getBifrostMintCallBytes();
    await verifyEncoding(bifrostCallBytes, BIFROST_RPCS);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`\n❌ Bifrost error: ${msg}`);
    bifrostCallBytes = "0x" + Buffer.from("bifrost_placeholder").toString("hex");
    console.log("   Using placeholder bytes — replace before mainnet deployment");
  }

  try {
    hydrationCallBytes = await getHydrationSellCallBytes();
    await verifyEncoding(hydrationCallBytes, HYDRATION_RPCS);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`\n❌ Hydration error: ${msg}`);
    hydrationCallBytes = "0x" + Buffer.from("hydration_placeholder").toString("hex");
    console.log("   Using placeholder bytes — replace before mainnet deployment");
  }

  // ── Summary ────────────────────────────────────────────────────────────────

  console.log("\n" + "=".repeat(62));
  console.log(" Output — paste into .env");
  console.log("=".repeat(62));
  console.log(`BIFROST_MINT_CALL=${bifrostCallBytes}`);
  console.log(`HYDRATION_ROUTER_SELL_CALL=${hydrationCallBytes}`);
  console.log();
  console.log("Next steps:");
  console.log("  1. Deploy: npx hardhat run scripts/deploy.ts --network polkadotHub");
  console.log("  2. Verify bytes on-chain via vault.bifrostMintCall() / vault.hydrationSellCall()");
  console.log("  3. Pre-fund vault sovereign accounts on Bifrost (BNC) and Hydration (HDX)");
  console.log("  4. Deposit DOT, then call executeCarry()");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
