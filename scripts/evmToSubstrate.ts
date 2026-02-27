/**
 * evmToSubstrate.ts
 *
 * Converts a 20-byte MetaMask (EVM) address to its 32-byte Substrate
 * equivalent on Polkadot Hub, and prints the SS58 address you can
 * send DOT to from polkadot.js apps.
 *
 * How it works:
 *   1. Takes your 20-byte MetaMask address (e.g. 0x5d84...7a58)
 *   2. Pads it with 12 × 0xEE bytes to get the 32-byte AccountId32
 *      that the Polkadot Hub runtime maps to that EVM address
 *   3. Converts to SS58 format
 *
 * The resulting SS58 address is controlled by your MetaMask private key —
 * the 0xEE suffix is a deterministic, reversible mapping used by pallet_revive.
 *
 * Usage:
 *   npx ts-node scripts/evmToSubstrate.ts 0xYourMetaMaskAddress
 */

import { encodeAddress } from "@polkadot/util-crypto";
import { hexToU8a } from "@polkadot/util";

const SS58_PREFIX = 0; // Polkadot

function evmToSubstrate(evmAddress: string): { accountId32Hex: string; ss58: string } {
  const clean = evmAddress.toLowerCase();
  if (!/^0x[0-9a-f]{40}$/.test(clean)) {
    throw new Error(`Invalid EVM address: ${evmAddress}. Expected 0x + 40 hex chars.`);
  }

  const accountId32Hex = clean + "ee".repeat(12);
  const accountBytes = hexToU8a(accountId32Hex);
  const ss58 = encodeAddress(accountBytes, SS58_PREFIX);

  return { accountId32Hex, ss58 };
}

const evmAddress = process.argv[2];

if (!evmAddress) {
  console.log("Usage:");
  console.log("  npx ts-node scripts/evmToSubstrate.ts <0xEvmAddress>");
  process.exit(1);
}

const { accountId32Hex, ss58 } = evmToSubstrate(evmAddress);

console.log("=".repeat(60));
console.log(" EVM → Substrate Address Conversion");
console.log("=".repeat(60));
console.log(`  EVM address:     ${evmAddress}`);
console.log(`  AccountId32:     ${accountId32Hex}`);
console.log(`  SS58 (Polkadot): ${ss58}`);
console.log("");
console.log("  This SS58 address is controlled by your MetaMask private key.");
console.log("  Send DOT to this address via polkadot.js apps and it will");
console.log("  appear in MetaMask on Polkadot Hub.");
console.log("=".repeat(60));
