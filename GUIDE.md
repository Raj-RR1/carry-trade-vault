# Polkadot Hub EVM — The Hacker's Guide to Precompiles & XCM

> **TL;DR:** You can call **ANY** pallet on Polkadot Hub from Solidity using the XCM precompile. No dedicated precompile needed. This guide shows you how.

## Table of Contents

1. [The Problem](#the-problem)
2. [Available Precompiles](#available-precompiles)
3. [The Escape Hatch: XCM Local Transact](#the-escape-hatch-xcm-local-transact)
4. [SCALE Encoding in Solidity](#scale-encoding-in-solidity)
5. [Pattern 1: Call Any Local Pallet](#pattern-1-call-any-local-pallet)
6. [Pattern 2: Send DOT Cross-Chain](#pattern-2-send-dot-cross-chain)
7. [Pattern 3: Call Remote Pallet on Another Chain](#pattern-3-call-remote-pallet-on-another-chain)
8. [Composing Precompiles Together](#composing-precompiles-together)
9. [Common Pallet Call Recipes](#common-pallet-call-recipes)
10. [How to Find Pallet Call Bytes](#how-to-find-pallet-call-bytes)
11. [Gotchas & Pitfalls](#gotchas--pitfalls)
12. [EVM ↔ Substrate Address Conversion](#evm--substrate-address-conversion)
13. [Reference: XCM Instruction Opcodes](#reference-xcm-instruction-opcodes)

---

## The Problem

You're building on Polkadot Hub (AssetHub) EVM and you need to:
- Swap DOT for USDT via the Asset Conversion pallet
- Mint an NFT via the NFTs pallet
- Create a new asset via the Assets pallet
- Transfer a foreign asset
- Call some pallet that has no precompile

You check the docs and see only a handful of precompiles (ERC20, XCM, System, Storage). Panic sets in: *"There's no precompile for Asset Conversion! I can't build my DEX aggregator!"*

**Don't panic.** The XCM precompile is your universal escape hatch.

---

## Available Precompiles

Polkadot Hub EVM ships with these precompiles:

| Precompile | Address | Purpose |
|---|---|---|
| **ERC20** | `0x[assetId]...01200000` | Interact with Assets pallet tokens (USDT, USDC, etc.) |
| **XCM** | `0x00...000a0000` | Execute local XCM, send cross-chain XCM, estimate weight |
| **System** | `0x00...00000800` | BLAKE2 hashing, sr25519 verify, account ID conversion |
| **Storage** | (varies) | Read runtime storage |

That's it. No precompile for Asset Conversion, NFTs, Staking, Identity, Multisig, Proxy, etc.

**But you don't need them.** Read on.

---

## The Escape Hatch: XCM Local Transact

The XCM precompile has three functions:

```solidity
interface IXcm {
    struct Weight { uint64 refTime; uint64 proofSize; }

    // Execute XCM locally on this chain
    function execute(bytes calldata message, Weight calldata weight) external;

    // Send XCM to another chain
    function send(bytes calldata destination, bytes calldata message) external;

    // Estimate weight for a message
    function weighMessage(bytes calldata message) external view returns (Weight memory);
}
```

The key insight: **`execute()` runs XCM instructions locally on Polkadot Hub**. One of those instructions is `Transact`, which dispatches an arbitrary pallet call.

```
XCM.execute([
    Transact(encoded_pallet_call)
])
```

This lets you call **ANY pallet** in the Polkadot Hub runtime from your Solidity contract.

---

## SCALE Encoding in Solidity

XCM messages use SCALE encoding (Substrate's native serialization format). Here's what you need to know:

### Compact Integer Encoding

Variable-length integers used everywhere in SCALE:

```solidity
function compactEncode(uint256 n) internal pure returns (bytes memory) {
    if (n < 64) {
        // Single byte: value << 2
        return abi.encodePacked(bytes1(uint8(n << 2)));
    } else if (n < 16384) {
        // Two bytes LE: (value << 2) | 0x01
        uint16 v = uint16((n << 2) | 0x01);
        return abi.encodePacked(bytes1(uint8(v)), bytes1(uint8(v >> 8)));
    } else if (n < 1073741824) {
        // Four bytes LE: (value << 2) | 0x02
        uint32 v = uint32((n << 2) | 0x02);
        return abi.encodePacked(
            bytes1(uint8(v)), bytes1(uint8(v >> 8)),
            bytes1(uint8(v >> 16)), bytes1(uint8(v >> 24))
        );
    }
    // else: big-integer mode (rarely needed)
}
```

### Key Constants

```solidity
// XCM version prefix
bytes1 constant XCM_V5 = 0x05;

// XCM instruction opcodes (V4/V5 — same opcodes)
uint8 constant WITHDRAW_ASSET       = 0x00;
uint8 constant TRANSACT             = 0x06;
uint8 constant DEPOSIT_ASSET        = 0x0D;
uint8 constant DEPOSIT_RESERVE_ASSET = 0x0E;
uint8 constant BUY_EXECUTION        = 0x13;
uint8 constant REFUND_SURPLUS       = 0x14;

// DOT decimals: EVM uses 18, Substrate uses 10
uint256 constant EVM_TO_SUBSTRATE = 1e8; // divide EVM amounts by this
```

### Encoding DOT as an Asset

DOT on Polkadot Hub (local context) = `{parents: 0, interior: Here}`:

```solidity
function encodeDotAsset(uint256 evmAmount) internal pure returns (bytes memory) {
    uint256 planck = evmAmount / EVM_TO_SUBSTRATE;
    return abi.encodePacked(
        bytes1(0x00),   // Concrete asset
        bytes1(0x00),   // parents = 0
        bytes1(0x00),   // interior = Here
        bytes1(0x01),   // Fungible
        compactEncode(planck)
    );
}
```

---

## Pattern 1: Call Any Local Pallet

This is the universal pattern. Want to call `assetConversion.swapExactTokensForTokens`? Or `nfts.mint`? Or literally anything?

### Step 1: Get the SCALE-encoded call bytes

Use polkadot.js/apps or `@polkadot/api` to encode your pallet call:

```typescript
import { ApiPromise, WsProvider } from "@polkadot/api";

const api = await ApiPromise.create({
    provider: new WsProvider("wss://polkadot-asset-hub-rpc.polkadot.io")
});

// Example: Asset Conversion swap
const call = api.tx.assetConversion.swapExactTokensForTokens(
    path,        // [DOT_location, USDT_location]
    amountIn,    // how much DOT
    amountOutMin // minimum USDT out
);

console.log("Call bytes:", call.method.toHex());
// Output: 0x3D0104...  (pallet_index=0x3D, call_index=0x01, params...)
```

### Step 2: Wrap in XCM Transact and execute

```solidity
// In your Solidity contract:
IXcm constant XCM = IXcm(0x00000000000000000000000000000000000a0000);

function swapDotForUsdt(bytes calldata swapCallBytes) external {
    // Build XCM message with Transact
    bytes memory xcmMsg = abi.encodePacked(
        bytes1(0x05),                    // XCM V5
        compactEncode(4),                // 4 instructions

        // 1. WithdrawAsset — pull DOT from contract balance into holding
        bytes1(0x00),                    // opcode: WithdrawAsset
        compactEncode(1),                // 1 asset
        encodeDotAsset(msg.value),       // DOT amount

        // 2. BuyExecution — pay for XCM processing
        bytes1(0x13),                    // opcode: BuyExecution
        encodeDotAsset(msg.value),       // fee asset
        bytes1(0x00),                    // WeightLimit::Unlimited

        // 3. Transact — call the pallet!
        bytes1(0x06),                    // opcode: Transact
        bytes1(0x01),                    // OriginKind::SovereignAccount
        compactEncode(1_000_000_000),    // refTime budget
        compactEncode(65_536),           // proofSize budget
        compactEncode(swapCallBytes.length),
        swapCallBytes,                   // the actual pallet call

        // 4. DepositAsset — put results back to an account
        bytes1(0x0D),                    // opcode: DepositAsset
        bytes1(0x01), bytes1(0x00),      // AssetFilter::Wild(All)
        bytes1(0x00),                    // parents = 0
        bytes1(0x01),                    // X1
        bytes1(0x01),                    // AccountId32
        bytes1(0x00),                    // network = None
        accountId32                      // 32-byte beneficiary
    );

    // Execute locally — weighMessage gives exact weight needed
    XCM.execute(xcmMsg, XCM.weighMessage(xcmMsg));
}
```

### That's it. This pattern works for ANY pallet call.

The pallet call bytes are opaque to the XCM — it just dispatches them. You generate the bytes off-chain (where encoding is easy) and pass them to your contract.

---

## Pattern 2: Send DOT Cross-Chain

Transfer DOT from Polkadot Hub to a sibling parachain (e.g., Bifrost, Hydration):

```solidity
function sendDotToParachain(uint256 amount, uint32 paraId, bytes32 recipient) external {
    // Since Polkadot Hub IS the DOT reserve (post Nov 2025 migration),
    // use DepositReserveAsset to send DOT to siblings.

    bytes memory innerXcm = abi.encodePacked(
        compactEncode(2),                     // 2 inner instructions
        // BuyExecution on destination
        bytes1(0x13), encodeDotAssetOnDest(0.01 ether), bytes1(0x00),
        // DepositAsset to recipient
        bytes1(0x0D), bytes1(0x01), bytes1(0x00),
        bytes1(0x00), bytes1(0x01), bytes1(0x01), bytes1(0x00), recipient
    );

    bytes memory xcmMsg = abi.encodePacked(
        bytes1(0x05),                         // XCM V5
        compactEncode(2),                     // 2 outer instructions
        // WithdrawAsset
        bytes1(0x00), compactEncode(1), encodeDotAsset(amount),
        // DepositReserveAsset — this moves DOT to the destination
        bytes1(0x0E),                         // opcode
        bytes1(0x01), bytes1(0x00),           // Wild(All)
        encodeParaSiblingLocation(paraId),    // dest: parents=1, X1(Parachain)
        innerXcm
    );

    XCM.execute(xcmMsg, XCM.weighMessage(xcmMsg));
}
```

**Important:** After the Nov 2025 migration, Polkadot Hub (AssetHub) is the DOT reserve. `DepositReserveAsset` is how you send DOT to other chains. DOT's XCM asset ID still remains `{parents:1, Here}`; `{parents:1, X1(Parachain(1000))}` refers to Asset Hub as a chain location/reserve, not to the DOT asset ID itself.

---

## Pattern 3: Call Remote Pallet on Another Chain

Want to call a pallet on Bifrost or Hydration? Use `send()`. But there's a catch: **you need DOT on the destination chain first**.

### The 2-Step Pattern (avoids ClearOrigin issue)

**Why 2 steps?** `DepositReserveAsset` auto-prepends `ClearOrigin` on the destination. This sets the XCM origin to `None`, which makes `Transact` fail with `BadOrigin`. By splitting into transfer + transact, you avoid this.

```solidity
function callRemotePallet(
    uint32 paraId,
    bytes calldata palletCall,
    uint256 dotAmount,
    bytes32 beneficiary
) external {
    // ── Step 1: execute() — Transfer DOT to destination ──
    // DepositReserveAsset moves DOT from Hub to sibling
    // ClearOrigin is harmless here (no Transact in inner XCM)
    bytes memory transferMsg = buildDotTransferXCM(dotAmount, paraId, sovereign);
    XCM.execute(transferMsg, XCM.weighMessage(transferMsg));

    // ── Step 2: send() — Call the pallet (origin preserved) ──
    // This message travels via HRMP to the destination
    // Origin = Polkadot Hub sovereign → Transact dispatches correctly
    bytes memory transactMsg = abi.encodePacked(
        bytes1(0x05), compactEncode(5),
        instrWithdrawAssetOnDest(fee),   // from Hub's sovereign account
        instrBuyExecutionDestDot(fee),
        instrTransact(refTime, proofSize, palletCall),
        instrRefundSurplus(),
        instrDepositAsset(beneficiary)
    );

    bytes memory dest = encodeParaDest(paraId);
    XCM.send(dest, transactMsg);
}
```

**Step 1** and **Step 2** are dispatched in the same EVM transaction (same block). HRMP messages are processed FIFO on the destination, so Step 1's DOT always arrives before Step 2 tries to use it.

---

## Composing Precompiles Together

You can combine multiple precompiles in a single contract:

```solidity
contract DeFiVault {
    IXcm constant XCM = IXcm(0x00000000000000000000000000000000000a0000);

    // ERC20 precompile for USDT (asset ID 1984)
    IERC20 constant USDT = IERC20(0x000007C000000000000000000000000001200000);

    function getUsdtBalance() external view returns (uint256) {
        // Use ERC20 precompile to check USDT balance
        return USDT.balanceOf(address(this));
    }

    function swapAndBridge(bytes calldata swapCall, uint32 destPara) external payable {
        // 1. Use XCM precompile to call Asset Conversion (local Transact)
        bytes memory swapXcm = buildLocalTransact(swapCall);
        XCM.execute(swapXcm, XCM.weighMessage(swapXcm));

        // 2. Use ERC20 precompile to check what we got
        uint256 usdtOut = USDT.balanceOf(address(this));

        // 3. Use XCM precompile to bridge USDT to another chain
        bytes memory bridgeXcm = buildBridgeXcm(usdtOut, destPara);
        XCM.execute(bridgeXcm, XCM.weighMessage(bridgeXcm));
    }
}
```

### ERC20 Precompile Address Formula

Every asset in the Assets pallet gets an ERC20 precompile address:

```
Address = 0x[assetId as 8 hex chars][24 zero chars][prefix 01200000]
```

Examples:
- USDT (asset 1984 = 0x7C0): `0x000007C000000000000000000000000001200000`
- Asset 42 (0x2A): `0x0000002A00000000000000000000000001200000`

Foreign assets use the same pattern but with a different prefix and a hash of the multilocation.

---

## Common Pallet Call Recipes

### Asset Conversion: Swap DOT → USDT

```typescript
// Off-chain: generate call bytes
const call = api.tx.assetConversion.swapExactTokensForTokens(
    [dotLocation, usdtLocation],  // path
    1_000_000_000_000n,           // amountIn (1 DOT in planck)
    0n                            // amountOutMin (set properly in production!)
);
console.log(call.method.toHex());
```

Then wrap in XCM Transact (Pattern 1).

### Assets: Transfer a Foreign Asset

```typescript
const call = api.tx.foreignAssets.transfer(
    vDotMultilocation,  // asset ID (multilocation)
    recipientAccountId, // who to send to
    amount              // how much
);
```

### NFTs: Mint

```typescript
const call = api.tx.nfts.mint(
    collectionId,
    itemId,
    recipientAccountId,
    null  // witness data
);
```

### Balances: Transfer DOT (Substrate-style)

```typescript
const call = api.tx.balances.transferKeepAlive(
    recipientAccountId,
    amount
);
```

**All of these become XCM Transact calls using the same pattern.**

---

## How to Find Pallet Call Bytes

### Method 1: polkadot.js/apps (UI)

1. Go to [Polkadot.js Apps](https://polkadot.js.org/apps/?rpc=wss://polkadot-asset-hub-rpc.polkadot.io)
2. Navigate to Developer → Extrinsics
3. Select the pallet and call you want
4. Fill in parameters
5. Click "Submit Transaction" but DON'T sign — look at the "encoded call data" field
6. Copy the hex bytes — that's your `callBytes`

### Method 2: @polkadot/api (script)

```typescript
import { ApiPromise, WsProvider } from "@polkadot/api";

async function main() {
    const api = await ApiPromise.create({
        provider: new WsProvider("wss://polkadot-asset-hub-rpc.polkadot.io")
    });

    // Build any call
    const call = api.tx.assetConversion.swapExactTokensForTokens(
        path, amountIn, amountOutMin
    );

    // Get the raw SCALE-encoded bytes (no signature, no extras)
    const callBytes = call.method.toHex();
    console.log("Use in Solidity:", callBytes);

    // First 2 bytes = pallet_index + call_index
    // e.g., 0x3D01... = pallet 0x3D, call 0x01
}
```

### Method 3: Subscan

1. Find an existing successful extrinsic of the same type on [Subscan](https://assethub-polkadot.subscan.io)
2. Look at the "call data" field
3. Modify the parameters as needed

---

## Gotchas & Pitfalls

### 1. DOT Decimal Mismatch

EVM uses 18 decimals (`1 DOT = 1e18`). Substrate uses 10 decimals (`1 DOT = 1e10`).

```solidity
// WRONG — sends 1e18 planck (100 million DOT!)
XCM.execute(buildTransact(msg.value));

// RIGHT — convert first
uint256 planck = msg.value / 1e8;  // 1e18 / 1e8 = 1e10
XCM.execute(buildTransact(planck));
```

### 2. ClearOrigin Kills Transact in DepositReserveAsset

`DepositReserveAsset` auto-prepends `ClearOrigin` on the destination. This sets origin to `None`, and `Transact` fails with `BadOrigin`.

```
// BROKEN: inner XCM has Transact but ClearOrigin kills origin
DepositReserveAsset {
    xcm: [BuyExecution, Transact(call), DepositAsset]  // Transact fails!
}

// WORKING: split into two messages
// Step 1 (execute): DepositReserveAsset with simple inner XCM (no Transact)
// Step 2 (send):    Transact separately (origin preserved)
```

### 3. OriginKind in Transact

The second byte of Transact is `OriginKind`. Use `0x01` (SovereignAccount), NOT `0x00` (Native):

```solidity
bytes1(0x06),  // Transact opcode
bytes1(0x01),  // OriginKind::SovereignAccount (NOT 0x00 = Native)
```

### 4. BuyExecution Charges Upfront

`BuyExecution` charges based on the **total estimated weight** of remaining instructions, including Transact's `require_weight_at_most`. If you set a high weight budget but don't have enough DOT in holding, it fails with `TooExpensive`.

```
// If require_weight_at_most = 100 billion refTime
// And FeePerSecond = 1 DOT/sec
// Then BuyExecution tries to charge ~0.1 DOT upfront
// RefundSurplus returns the unused portion later
```

### 5. Post-Migration DOT Identity vs Reserve

Since Nov 2025, AssetHub IS the DOT reserve. The important distinction is:
- **DOT asset ID in XCM:** `{parents: 1, interior: Here}`
- **Asset Hub reserve-chain location:** `{parents: 1, interior: X1(Parachain(1000))}`

So post-migration, `{parents: 1, interior: Here}` still names the DOT asset, while
`{parents: 1, interior: X1(Parachain(1000))}` identifies Asset Hub as the reserve chain.

### 6. weighMessage for execute, Not send

`weighMessage()` estimates the weight for local `execute()` calls only. It can't estimate weight for remote chains (send). For send messages, the remote chain determines execution cost.

### 7. NatSpec and @polkadot/api

Solidity's NatSpec parser chokes on `@polkadot/api` in doc comments. Use "polkadot-js API" instead:

```solidity
// BROKEN: DocstringParsingError
/// @dev Generated by @polkadot/api

// WORKING
/// @dev Generated by polkadot-js API
```

### EVM ↔ Substrate Address Conversion

Polkadot Hub uses 32-byte Substrate accounts, but MetaMask gives you a 20-byte EVM address. The runtime maps between them deterministically:

**EVM (20 bytes) → Substrate (32 bytes):** Pad with 12 × `0xEE` bytes.

```
EVM address:    0x5d84...7a58
AccountId32:    0x5d84...7a58 EEEEEEEEEEEEEEEEEEEEEEEE
SS58 (Polkadot): 1abc...xyz
```

The resulting 32-byte account is **controlled by your MetaMask private key**. The `0xEE` suffix is a fixed, deterministic mapping used by `pallet_revive` — no one else can control that account.

**To fund your MetaMask wallet with DOT:**

1. Convert your EVM address to SS58:
   ```bash
   npx ts-node scripts/evmToSubstrate.ts 0xYourMetaMaskAddress
   ```

2. Send DOT to the resulting SS58 address from [polkadot.js apps](https://polkadot.js.org/apps/) using `balances.transferKeepAlive`

3. The DOT will appear in MetaMask on Polkadot Hub

**Native Substrate (32 bytes) → EVM (20 bytes):** Only possible for accounts that were originally 20-byte EVM addresses (i.e., end with `0xEE × 12`). Native sr25519/ed25519 Substrate accounts must call `revive.map_account` to get a separate EVM address.

---

## Reference: XCM Instruction Opcodes

XCM V4 and V5 share the same instruction opcodes. V5 only changes the version prefix (0x04 → 0x05) and adds new instructions.

| Opcode | Hex | Instruction | Description |
|--------|-----|-------------|-------------|
| 0 | `0x00` | `WithdrawAsset` | Pull assets from account into holding register |
| 1 | `0x01` | `ReserveAssetDeposited` | Notify that reserve assets were deposited |
| 2 | `0x02` | `ReceiveTeleportedAsset` | Receive teleported assets |
| 3 | `0x03` | `QueryResponse` | Response to a query |
| 4 | `0x04` | `TransferAsset` | Transfer assets to a destination |
| 5 | `0x05` | `TransferReserveAsset` | Transfer + treat source as reserve |
| 6 | `0x06` | `Transact` | **Dispatch an encoded call** |
| 7 | `0x07` | `HrmpNewChannelOpenRequest` | HRMP channel management |
| 8 | `0x08` | `HrmpChannelAccepted` | HRMP channel accepted |
| 9 | `0x09` | `HrmpChannelClosing` | HRMP channel closing |
| 10 | `0x0A` | `ClearOrigin` | Clear the XCM origin |
| 11 | `0x0B` | `DescendOrigin` | Descend origin into a child |
| 12 | `0x0C` | `ReportError` | Report error to caller |
| 13 | `0x0D` | `DepositAsset` | Deposit holding to an account |
| 14 | `0x0E` | `DepositReserveAsset` | Deposit + notify dest as reserve |
| 15 | `0x0F` | `ExchangeAsset` | Exchange assets in holding |
| 16 | `0x10` | `InitiateReserveWithdraw` | Start reserve withdrawal |
| 17 | `0x11` | `InitiateTeleport` | Start teleport |
| 18 | `0x12` | `ReportHolding` | Report holding contents |
| 19 | `0x13` | `BuyExecution` | Pay for XCM execution |
| 20 | `0x14` | `RefundSurplus` | Return unused execution budget |
| 21 | `0x15` | `SetErrorHandler` | Set error handling XCM |
| 22 | `0x16` | `SetAppendix` | Set appendix XCM (runs after) |
| 23 | `0x17` | `ClearError` | Clear the error register |
| 24 | `0x18` | `ClaimAsset` | Claim trapped assets |
| 25 | `0x19` | `Trap` | Intentionally fail |

### OriginKind Enum (used in Transact)

| Value | Hex | Variant | Use Case |
|-------|-----|---------|----------|
| 0 | `0x00` | `Native` | Call as the chain's native origin |
| 1 | `0x01` | `SovereignAccount` | Call as the sovereign account (most common) |
| 2 | `0x02` | `Superuser` | Call with root privileges |
| 3 | `0x03` | `Xcm` | Call as XCM origin |

### XCM Message Structure

```
[Version prefix (1 byte)]
[Compact-encoded instruction count]
[Instruction 1: opcode byte + payload]
[Instruction 2: opcode byte + payload]
...
```

### Location Encoding

```
// Local (AssetHub itself): parents=0, Here
0x00 0x00

// Sibling parachain (e.g., Bifrost 2001): parents=1, X1(Parachain(2001))
0x01 0x01 0x00 [compact(2001)]

// Relay chain: parents=1, Here
0x01 0x00

// Account on local chain: parents=0, X1(AccountId32{None, id})
0x00 0x01 0x01 0x00 [32 bytes account ID]
```

### Versioned Location (for send)

Same as bare Location but prefixed with version byte:

```
// V5 + Sibling Bifrost
0x05 0x01 0x01 0x00 [compact(2001)]
```

---

## Quick Start Template

Copy this into your project and start building:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

address constant XCM_PRECOMPILE = 0x00000000000000000000000000000000000a0000;

interface IXcm {
    struct Weight { uint64 refTime; uint64 proofSize; }
    function execute(bytes calldata message, Weight calldata weight) external;
    function send(bytes calldata destination, bytes calldata message) external;
    function weighMessage(bytes calldata message) external view returns (Weight memory);
}

contract MyPalletCaller {
    IXcm constant XCM = IXcm(XCM_PRECOMPILE);

    /// @notice Call any pallet on Polkadot Hub from Solidity
    /// @param callBytes SCALE-encoded pallet call (generate with polkadot-js API)
    /// @param beneficiary 32-byte account to receive any output assets
    function callPallet(bytes calldata callBytes, bytes32 beneficiary) external payable {
        uint256 planck = msg.value / 1e8; // 18-decimal → 10-decimal

        bytes memory xcm = abi.encodePacked(
            bytes1(0x05),                              // XCM V5
            bytes1(0x10),                              // compact(4) = 4 instructions
            // WithdrawAsset
            bytes1(0x00),
            bytes1(0x04),                              // compact(1) asset
            bytes1(0x00), bytes1(0x00), bytes1(0x00),  // DOT: parents=0, Here, Concrete
            bytes1(0x01), compactEncode(planck),       // Fungible(amount)
            // BuyExecution
            bytes1(0x13),
            bytes1(0x00), bytes1(0x00), bytes1(0x00),
            bytes1(0x01), compactEncode(planck),
            bytes1(0x00),                              // Unlimited
            // Transact
            bytes1(0x06),
            bytes1(0x01),                              // SovereignAccount
            compactEncode(1_000_000_000),              // refTime
            compactEncode(65_536),                     // proofSize
            compactEncode(callBytes.length),
            callBytes,
            // DepositAsset
            bytes1(0x0D),
            bytes1(0x01), bytes1(0x00),                // Wild(All)
            bytes1(0x00), bytes1(0x01),                // parents=0, X1
            bytes1(0x01), bytes1(0x00),                // AccountId32, None
            beneficiary
        );

        XCM.execute(xcm, XCM.weighMessage(xcm));
    }

    function compactEncode(uint256 n) internal pure returns (bytes memory) {
        if (n < 64) return abi.encodePacked(bytes1(uint8(n << 2)));
        if (n < 16384) {
            uint16 v = uint16((n << 2) | 0x01);
            return abi.encodePacked(bytes1(uint8(v)), bytes1(uint8(v >> 8)));
        }
        uint32 v = uint32((n << 2) | 0x02);
        return abi.encodePacked(
            bytes1(uint8(v)), bytes1(uint8(v >> 8)),
            bytes1(uint8(v >> 16)), bytes1(uint8(v >> 24))
        );
    }
}
```

Generate your `callBytes` off-chain:

```typescript
import { ApiPromise, WsProvider } from "@polkadot/api";

const api = await ApiPromise.create({
    provider: new WsProvider("wss://polkadot-asset-hub-rpc.polkadot.io")
});

// Replace with ANY pallet call you need:
const call = api.tx.assetConversion.swapExactTokensForTokens(path, amount, min);
console.log("callBytes:", call.method.toHex());
```

Pass those bytes to `callPallet()` in your contract. Done.

---

## Bonus: ink! v6 as an XCM Library (Skip the Byte Stitching)

As of ink! v6, **ink! contracts compile to RISC-V and run on `pallet_revive`** — the exact same pallet as Solidity contracts. This means ink! and Solidity contracts are fully interoperable: they can call each other like any other contract.

> **Source:** [Why RISC-V and PolkaVM for Smart Contracts](https://use.ink/docs/v6/background/why-riscv-and-polkavm-for-smart-contracts/)

### Why this matters

Building XCM messages in Solidity means manual SCALE encoding byte by byte (see our `XCMBuilder.sol` — 400+ lines). In ink! (Rust), all of this is free:

```rust
// ink! — XCM message in 10 lines
use xcm::v5::prelude::*;

let message = Xcm::<()>(vec![
    WithdrawAsset((Here, amount).into()),
    BuyExecution { fees: (Here, amount).into(), weight_limit: Unlimited },
    Transact {
        origin_kind: OriginKind::SovereignAccount,
        call: encoded_call.into(),
    },
    RefundSurplus,
    DepositAsset { assets: Wild(All), beneficiary: account.into() },
]);

let bytes: Vec<u8> = message.encode(); // Native SCALE encoding — done!
```

vs Solidity (our approach):

```solidity
// Solidity — manual byte stitching
bytes memory msg = abi.encodePacked(
    bytes1(0x05),              // V5 prefix
    compactEncode(5),          // 5 instructions
    bytes1(0x00),              // WithdrawAsset opcode
    compactEncode(1),          // 1 asset
    bytes1(0x00),              // Concrete
    bytes1(0x00),              // parents=0
    bytes1(0x00),              // Here
    bytes1(0x01),              // Fungible
    compactEncode(amount),     // amount
    // ... 30 more lines of byte encoding
);
```

### Architecture: ink! XCM Library + Solidity App

You could split your project into two contracts on the same chain:

```
┌─────────────────────────────────┐
│  YourApp.sol (Solidity)         │
│  - Business logic               │
│  - User deposits/withdrawals    │
│  - State management             │
│                                 │
│  calls ↓                        │
├─────────────────────────────────┤
│  XcmLib.ink (ink! v6 / Rust)    │
│  - Native SCALE encoding        │
│  - Native XCM type constructors │
│  - Returns encoded bytes        │
│  - Zero manual byte stitching   │
└─────────────────────────────────┘
         │
         ↓ encoded bytes
┌─────────────────────────────────┐
│  XCM Precompile (0x...0a0000)   │
│  execute() / send()             │
└─────────────────────────────────┘
```

The ink! contract acts as a pure encoding library:

```rust
#[ink::contract]
mod xcm_lib {
    use xcm::v5::prelude::*;

    #[ink(message)]
    pub fn build_dot_transfer(
        &self,
        amount: u128,
        dest_para: u32,
        beneficiary: [u8; 32],
    ) -> Vec<u8> {
        let message = Xcm::<()>(vec![
            WithdrawAsset((Here, amount).into()),
            DepositReserveAsset {
                assets: Wild(All),
                dest: Location::new(1, [Parachain(dest_para)]),
                xcm: Xcm(vec![
                    BuyExecution {
                        fees: (Parent, Parachain(1000), amount / 100).into(),
                        weight_limit: Unlimited,
                    },
                    DepositAsset {
                        assets: Wild(All),
                        beneficiary: Location::new(0, [AccountId32 {
                            network: None,
                            id: beneficiary,
                        }]),
                    },
                ]),
            },
        ]);

        VersionedXcm::V5(message).encode()
    }

    #[ink(message)]
    pub fn build_transact(
        &self,
        fee_amount: u128,
        call_bytes: Vec<u8>,
        beneficiary: [u8; 32],
    ) -> Vec<u8> {
        let message = Xcm::<()>(vec![
            WithdrawAsset((Parent, fee_amount).into()),
            BuyExecution {
                fees: (Parent, fee_amount).into(),
                weight_limit: Unlimited,
            },
            Transact {
                origin_kind: OriginKind::SovereignAccount,
                call: call_bytes.into(),
            },
            RefundSurplus,
            DepositAsset {
                assets: Wild(All),
                beneficiary: Location::new(0, [AccountId32 {
                    network: None,
                    id: beneficiary,
                }]),
            },
        ]);

        VersionedXcm::V5(message).encode()
    }
}
```

Then from Solidity:

```solidity
interface IXcmLib {
    function buildDotTransfer(uint128 amount, uint32 destPara, bytes32 beneficiary)
        external view returns (bytes memory);
    function buildTransact(uint128 feeAmount, bytes calldata callBytes, bytes32 beneficiary)
        external view returns (bytes memory);
}

contract MyVault {
    IXcm constant XCM = IXcm(0x00000000000000000000000000000000000a0000);
    IXcmLib public xcmLib; // ink! contract address

    function executeCarry() external {
        // ink! builds the XCM — no manual SCALE encoding!
        bytes memory msg = xcmLib.buildDotTransfer(amount, 2001, sovereign);
        XCM.execute(msg, XCM.weighMessage(msg));
    }
}
```

### Tradeoffs

| Approach | Pros | Cons |
|----------|------|------|
| **Pure Solidity** | Single language, no dependencies, works fully in EVM tooling | Manual byte encoding, error-prone, verbose |
| **ink! v6 library** | Native types, type-safe, concise, impossible to mis-encode | Two languages, two build tools, newer ecosystem |
| **Off-chain encoding** | Easiest — just pass pre-built bytes | Can't build messages dynamically on-chain |

### Current Status

ink! v6 with `pallet_revive` support is evolving quickly. For the latest cross-contract interoperability details between ink! and Solidity, check [use.ink](https://use.ink).

> This repository uses pure Solidity SCALE encoding end-to-end to prove XCM composition directly from Solidity. If your priority is maintainability over single-language simplicity, an ink! XCM helper contract can still be a cleaner architecture.

---

## Further Reading

- [Polkadot XCM Format Specification](https://github.com/polkadot-fellows/xcm-format)
- [Polkadot Hub Precompiles](https://docs.polkadot.com/smart-contracts/precompiles/)
- [ERC20 Precompile (Assets Pallet)](https://docs.polkadot.com/smart-contracts/precompiles/erc20/)
- [SCALE Encoding](https://docs.substrate.io/reference/scale-codec/)
- [Asset Hub Runtime Source](https://github.com/polkadot-fellows/runtimes)
- [ink! v6: Why RISC-V and PolkaVM](https://use.ink/docs/v6/background/why-riscv-and-polkavm-for-smart-contracts/)
- [ink! Documentation](https://use.ink)

---

*Built during the Polkadot Solidity Hackathon 2026. If this helped you, star the repo!*
