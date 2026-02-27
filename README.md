# Carry Trade Vault

**Polkadot Solidity Hackathon 2026 — deployed on Polkadot Hub EVM (REVM)**

A Solidity vault on Polkadot Hub that executes a cross-chain carry trade — minting yield-bearing vDOT on Bifrost and hedging basis risk on Hydration — using XCM composed entirely in Solidity.

---

## The Carry Trade

A carry trade captures the spread between a high-yield asset and a low-cost hedge:

```
 Yield leg:   DOT → vDOT via Bifrost SLPx         ~15% APY (liquid staking yield)
 Hedge leg:   DOT → USDT via Hydration Router      ~2% cost (basis hedge)
              ────────────────────────────────────────────────
 Net carry:                                         ~13% APY
```

**Example:** 1000 DOT deposited with 30% hedge ratio
- 700 DOT → Bifrost → mints vDOT → earns ~105 DOT/year
- 300 DOT → Hydration → sells for USDT → hedge costs ~6 DOT/year
- **Net: ~99 DOT/year ≈ 9.9% APY**

---

## Architecture

The vault uses a **2-step XCM pattern** per destination to avoid the ClearOrigin + Transact incompatibility:

```
User (DOT)
    │ deposit()
    ▼
CarryTradeVault.sol ── Polkadot Hub EVM (Chain 420420419)
    │
    │ executeCarry() — 4 XCM calls:
    │
    │ Step 1a: XCM.execute(DepositReserveAsset → Bifrost)
    │   DOT moves atomically: vault → AssetHub sovereign on Bifrost
    │
    │ Step 1b: XCM.send(Transact → Bifrost)
    │   AssetHub sovereign calls slpx.mint(DOT → vDOT)
    │   vDOT → vault's substrate account on Bifrost
    │
    │ Step 2a: XCM.execute(DepositReserveAsset → Hydration)
    │   DOT moves atomically: vault → AssetHub sovereign on Hydration
    │
    │ Step 2b: XCM.send(Transact → Hydration)
    │   AssetHub sovereign calls router.sell(DOT → USDT)
    │   USDT → vault's substrate account on Hydration
    ▼
Carry spread = vDOT yield (~15%) − hedge cost (~2%) ≈ 13% net APY
```

### Why 2 Steps?

`DepositReserveAsset` auto-prepends `ClearOrigin` on the destination, which sets the XCM origin to `None`. `Transact` needs a valid origin to dispatch pallet calls. By using `execute()` for the DOT transfer (Step 1) and `send()` for the pallet call (Step 2), the origin is preserved in Step 2.

Both messages from the same block are processed FIFO on the destination — Step 1 always completes before Step 2.

---

## Track 2 Innovations

| Feature | Implementation |
|---|---|
| **XCM Precompile** | `execute()` + `send()` — 4 cross-chain XCM messages per carry cycle |
| **weighMessage()** | Exact weight calculation for local execute — no hardcoded gas estimates |
| **SCALE Encoding in Solidity** | `XCMBuilder.sol` — compact integers, XCM V5 instructions, asset/location encoding |
| **Polkadot Native Assets** | DOT as `msg.value`; vDOT registered as foreign asset on AssetHub |
| **Post-Migration DOT** | Correct `{parents:1, X1(Parachain(1000))}` DOT location (Nov 2025 reserve migration) |
| **REVM Deployment** | Production flow uses standard EVM bytecode on Polkadot Hub EVM (REVM) |
| **Split XCM Fees** | Per-destination fee constants matching BuyExecution upfront charging behavior |

---

## Project Structure

```
carry-trade-vault/
├── contracts/
│   ├── CarryTradeVault.sol          Main vault — deposit, executeCarry, harvest, withdraw
│   ├── XCMBuilder.sol               SCALE encoder + XCM V5 message builder (library)
│   ├── interfaces/
│   │   ├── IXcm.sol                 XCM precompile interface (execute, send, weighMessage)
│   │   └── IERC20Minimal.sol        ERC20 interface for foreign assets (vDOT, USDT)
│   └── test/
│       ├── MockXcm.sol              Test double — records execute() and send() calls
│       └── XCMBuilderHarness.sol    Exposes library functions for unit testing
├── scripts/
│   ├── deploy.ts                    Deploy + configure vault on Polkadot Hub
│   ├── generateCallBytes.ts         Generate SCALE call bytes via polkadot-js API
│   └── evmToSubstrate.ts            Convert EVM address → AccountId32/SS58 (0xEE padding)
├── test/
│   └── CarryTradeVault.test.ts      67 tests — full coverage
├── frontend/
│   └── ...                          React + Vite dashboard (deposit, withdraw, owner actions)
├── GUIDE.md                         Hacker's guide to XCM precompile + SCALE encoding
├── TODO.md                          Status tracker and remaining work
├── .env.example                     Environment variable template
├── hardhat.config.ts
├── package.json
└── tsconfig.json
```

---

## Quick Start

### 1. Install & Compile

```bash
cd carry-trade-vault
npm install
npx hardhat compile
```

### 2. Run Tests

```bash
npx hardhat test
# 67 passing
```

### 3. Generate Call Bytes

Connect to Bifrost + Hydration RPCs to generate SCALE-encoded pallet calls:

```bash
# Set per-destination DOT amounts in .env first (planck, 10 decimals):
# BIFROST_DOT_PLANCK=20900000000
# HYDRATION_DOT_PLANCK=8900000000
# Note: each value should already subtract 0.01 DOT XCM transfer fee.
npm run gen:callbytes
```

Copy output to `.env`:
```env
BIFROST_MINT_CALL=0x7d0008...
HYDRATION_ROUTER_SELL_CALL=0x430005...
```

### 4. Configure & Deploy

```bash
cp .env.example .env
# Set: PRIVATE_KEY, BIFROST_DOT_PLANCK, HYDRATION_DOT_PLANCK,
#      BIFROST_MINT_CALL, HYDRATION_ROUTER_SELL_CALL, ASSET_HUB_SOVEREIGN
```

Derive `VAULT_SUBSTRATE_ACCOUNT` from your deployed contract (or wallet) EVM address:

```bash
npx ts-node scripts/evmToSubstrate.ts 0xYourAddress
# Paste the AccountId32 output into VAULT_SUBSTRATE_ACCOUNT in .env
```

```bash
# Testnet
npx hardhat run scripts/deploy.ts --network polkadotHubTest

# Mainnet
npx hardhat run scripts/deploy.ts --network polkadotHub
```

### 5. Run Frontend

```bash
npm run frontend:install
npm run frontend:dev
# Opens at http://localhost:5173
```

---

## Network Configuration

| Network | Chain ID | RPC | Explorer |
|---|---|---|---|
| **Polkadot Hub Mainnet** | `420420419` | `https://services.polkadothub-rpc.com/mainnet/` | [Blockscout](https://blockscout.polkadot.io/) |
| **Polkadot Hub Testnet** | `420420417` | `https://services.polkadothub-rpc.com/testnet/` | [Blockscout Testnet](https://blockscout-testnet.polkadot.io/) |

**Key Addresses:**
- XCM Precompile: `0x00000000000000000000000000000000000a0000`
- Bifrost: Parachain 2001
- Hydration: Parachain 2034
- AssetHub: Parachain 1000 (DOT reserve)

---

## Contract Interface

### User Actions

```solidity
// Deposit DOT and receive shares
vault.deposit{ value: 10 ether }()

// Withdraw proportional DOT (IDLE state only)
vault.withdraw(shareAmount)

// View position
vault.getPosition(address)   // → (shares, dotValue, sharePct)
vault.sharePrice()            // → DOT per share (1e18 precision)
vault.positionValue(address)  // → user's DOT value
```

### Owner Actions

```solidity
// Deploy capital cross-chain (4 XCM calls)
vault.executeCarry()

// Confirm XCM execution verified on Bifrost + Hydration
vault.confirmActive()

// Harvest yield from Bifrost (payable — send fee DOT)
vault.harvest{ value: 0.1 ether }()

// Record yield that arrived via XCM
vault.recordYield(yieldAmount)

// Return to IDLE state (re-enables withdrawals)
vault.unwindCarry()

// Emergency: recover trapped assets via custom XCM
vault.emergencyRecoverXCM(destParaId, xcmMessage)

// Configuration
vault.setCallTemplates(bifrostCall, hydrationCall)
vault.setVaultSubstrateAccount(account)
vault.setAssetHubSovereign(account)
vault.setHedgeRatio(bps)  // max 5000 = 50%

// Circuit breaker
vault.pause()
vault.unpause()
```

---

## Vault Lifecycle

```
  IDLE ──────── executeCarry() ──────── EXECUTING
   ▲                                        │
   │                                   confirmActive()
   │                                        │
   │                                        ▼
   └──────── unwindCarry() ──────────── ACTIVE
                                         │    │
                                   harvest() recordYield()
```

- **IDLE**: Accepts deposits and withdrawals
- **EXECUTING**: XCM sent, awaiting cross-chain confirmation. Deposits and withdrawals blocked.
- **ACTIVE**: Capital deployed. Harvest yield, record returns. Withdrawals blocked until unwind.

---

## XCM Fee Structure

BuyExecution charges **upfront** based on the Transact weight budget. Different destinations need different fees:

| Fee Constant | Value | Used For |
|---|---|---|
| `XCM_TRANSFER_FEE` | 0.01 DOT | Step 1: DepositReserveAsset inner XCM (BuyExecution + DepositAsset) |
| `XCM_BIFROST_FEE` | 0.05 DOT | Step 2: Bifrost Transact (10B refTime for slpx.mint) |
| `XCM_HYDRATION_FEE` | 0.1 DOT | Step 2: Hydration Transact (100B refTime for router.sell multi-hop) |

Excess fees are refunded via `RefundSurplus + DepositAsset` to the vault's substrate account. The `weighMessage()` precompile calculates exact weights for local `execute()` calls.

---

## How XCMBuilder Works

`XCMBuilder.sol` is a pure Solidity library that SCALE-encodes XCM V5 messages entirely on-chain. No external dependencies, no off-chain encoding for the XCM envelope.

### SCALE Compact Encoding

```
n in [0, 63]        → 1 byte:  n << 2
n in [64, 16383]    → 2 bytes: (n << 2 | 0x01), little-endian
n in [16384, 2^30)  → 4 bytes: (n << 2 | 0x02), little-endian
n >= 2^30           → big-integer mode (prefix + LE bytes)
```

### XCM V5 Message Structure

```
0x05                            ← XCM version = V5
compact(instruction_count)      ← number of instructions
  [instruction opcode + payload]
  [instruction opcode + payload]
  ...
```

### Key Functions

| Function | Purpose |
|---|---|
| `compactEncode(n)` | SCALE compact integer encoding |
| `encodeDotAsset(amount)` | DOT as `{parents:0, Here}` with 18→10 decimal conversion |
| `encodeDotAssetOnDestination(amount)` | DOT as `{parents:1, X1(Parachain(1000))}` on siblings |
| `buildDotTransferXCM(...)` | Step 1: WithdrawAsset + DepositReserveAsset (for execute) |
| `buildBifrostTransactXCM(...)` | Step 2: 5-instruction Transact message (for send to Bifrost) |
| `buildHydrationTransactXCM(...)` | Step 2: 5-instruction Transact message (for send to Hydration) |

---

## Pallet Call References

### Bifrost SLPx

| Field | Value |
|---|---|
| Pallet | `slpx` |
| Call | `mint` (call_index 0) — **no whitelist check** |
| `currency_id` | `Token2(0)` = DOT on Polkadot |
| `target_chain` | `TargetChain::AssetHub(receiver)` |
| Origin | AssetHub sovereign via XCM Transact |

### Hydration Router

| Field | Value |
|---|---|
| Pallet | `router` (NOT `omnipool` — DOT/USDT aren't in the Omnipool) |
| Call | `sell` |
| Route | DOT(5) → aDOT(1001) → LRNA(102) → USDT(10) (multi-hop) |
| Origin | AssetHub sovereign via XCM Transact |

---

## Security

- **Owner-gated XCM**: `executeCarry()`, `harvest()`, `emergencyRecoverXCM()` are owner-only
- **ReentrancyGuard**: On all state-changing user functions
- **Pausable**: Emergency stop for deposits and executeCarry
- **Hedge ratio cap**: Max 50% to ensure majority of capital earns yield
- **State machine**: Withdrawals blocked in EXECUTING/ACTIVE — prevents withdrawing while DOT is cross-chain
- **Emergency recovery**: `emergencyRecoverXCM()` sends arbitrary XCM to retrieve trapped assets

---

## Known Limitations

1. **Hardcoded call bytes**: Bifrost/Hydration pallet calls contain hardcoded DOT amounts. Owner must regenerate via `generateCallBytes.ts` and call `setCallTemplates()` before each `executeCarry()`.

2. **Shared sovereign account**: The AssetHub sovereign on Bifrost/Hydration is shared by all AssetHub contracts. Safe for hackathon (same-block FIFO ordering). Production should use `DescendOrigin` for per-contract sub-accounts.

3. **Async yield tracking**: `recordYield()` is manually called by owner after verifying DOT returned via XCM. No on-chain oracle for cross-chain balance.

4. **Testnet verification needed**: DOT location post-migration, SLPx whitelist bypass, and XCM fee sufficiency should be verified on testnet before mainnet deployment.

---

## Additional Resources

- **[GUIDE.md](./GUIDE.md)** — Hacker's guide: how to call any pallet from Solidity using the XCM precompile, SCALE encoding patterns, ink! v6 interop
- **[TODO.md](./TODO.md)** — Detailed status of all fixes and remaining work
- **[Polkadot XCM Specification](https://github.com/polkadot-fellows/xcm-format)**
- **[Polkadot Hub Precompiles](https://docs.polkadot.com/smart-contracts/precompiles/)**

---

## Toolchain

- Hardhat v2.28.6 (NOT v3 — Node v22 ESM issues)
- Solidity ^0.8.24
- OpenZeppelin Contracts (Ownable, ReentrancyGuard, Pausable)
- polkadot-js API (for generateCallBytes.ts)
- React + Vite (frontend)

---

*Built for the [Polkadot Solidity Hackathon 2026](https://dorahacks.io/) — implemented on Polkadot Hub EVM (REVM)*
