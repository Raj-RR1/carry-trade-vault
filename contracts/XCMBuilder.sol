// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title XCMBuilder
/// @notice Pure Solidity library for SCALE-encoding XCM V5 messages.
///         This is the PVM experiment: encoding Polkadot's native serialisation
///         format entirely within a Solidity smart contract running on PolkaVM.
///
/// @dev SCALE (Simple Concatenated Aggregate Little-Endian) encoding rules:
///      - Integers are little-endian
///      - Variable-length integers use "compact" encoding (see compactEncode)
///      - Vectors/sequences are prefixed with a compact-encoded length
///      - Enums are a single discriminant byte followed by the variant payload
///
///      XCM V4 instruction opcodes (enum indices) referenced below:
///      https://github.com/paritytech/polkadot-sdk/blob/master/polkadot/xcm/src/v4/mod.rs
///
///      Post-migration (Nov 2025): ALL DOT balances moved from the Relay Chain
///      to Asset Hub (now "Polkadot Hub"). Asset Hub IS the DOT reserve.
///      See: support.polkadot.network/support/solutions/articles/65000190561
///
///      Correct 2-step XCM flow (avoids ClearOrigin killing Transact):
///
///        Step 1 — execute() on AssetHub (transfers DOT to destination):
///          WithdrawAsset(DOT)
///          DepositReserveAsset {
///            dest: Bifrost/Hydration,
///            xcm: [BuyExecution, DepositAsset(assetHubSovereign)]
///          }
///
///        Step 2 — send() to destination (calls pallet, origin preserved):
///          WithdrawAsset(DOT fee from AssetHub sovereign)
///          BuyExecution(DOT)
///          Transact(pallet call)
///          RefundSurplus
///          DepositAsset(vaultSubstrateAccount)
///
///      Why 2 steps? DepositReserveAsset auto-prepends ClearOrigin on the
///      destination, which sets origin = None. Transact needs a valid origin
///      to dispatch calls. By separating transfer (step 1) from execution
///      (step 2 via send()), the origin is preserved in step 2.
library XCMBuilder {
    // ─────────────────────────────────────────────────────────────────────────
    // XCM V5 Instruction opcodes (SCALE enum discriminant index)
    // Same opcodes as V4; V5 adds new instructions but doesn't renumber.
    // Source: polkadot-sdk/polkadot/xcm/src/v5/mod.rs Instruction<Call> enum
    // ─────────────────────────────────────────────────────────────────────────
    uint8 constant OP_WITHDRAW_ASSET             = 0x00; //  0
    uint8 constant OP_RESERVE_ASSET_DEP          = 0x01; //  1
    uint8 constant OP_TRANSACT                   = 0x06; //  6
    uint8 constant OP_DEPOSIT_ASSET              = 0x0D; // 13
    uint8 constant OP_DEPOSIT_RESERVE_ASSET      = 0x0E; // 14
    uint8 constant OP_BUY_EXECUTION              = 0x13; // 19
    uint8 constant OP_REFUND_SURPLUS             = 0x14; // 20

    // ─────────────────────────────────────────────────────────────────────────
    // XCM version prefix (V5 — same instruction opcodes as V4, new features)
    // ─────────────────────────────────────────────────────────────────────────
    bytes1 constant XCM_VERSION = 0x05; // V5

    // ─────────────────────────────────────────────────────────────────────────
    // Parachain IDs
    // ─────────────────────────────────────────────────────────────────────────
    uint32 constant BIFROST_PARA_ID   = 2001;
    uint32 constant HYDRATION_PARA_ID = 2034;
    uint32 constant ASSET_HUB_PARA_ID = 1000;

    /// @dev Conversion factor: EVM uses 18-decimal DOT, Substrate/XCM uses 10-decimal.
    ///      Divide EVM amounts by this factor before SCALE-encoding into XCM messages.
    uint256 constant EVM_TO_SUBSTRATE = 1e8;

    // ─────────────────────────────────────────────────────────────────────────
    // SCALE compact integer encoding
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice SCALE compact-encode an unsigned integer.
    ///         Mode selection:
    ///           [0, 63]          → single byte:   (n << 2)
    ///           [64, 16383]      → two bytes LE:  (n << 2) | 0x01
    ///           [16384, 2^30-1]  → four bytes LE: (n << 2) | 0x02
    ///           >= 2^30          → big-integer mode (not needed for practical XCM)
    function compactEncode(uint256 n) internal pure returns (bytes memory out) {
        if (n < 64) {
            out = new bytes(1);
            out[0] = bytes1(uint8(n << 2));
        } else if (n < 16384) {
            uint16 v = uint16((n << 2) | 0x01);
            out = new bytes(2);
            out[0] = bytes1(uint8(v));         // low byte first (LE)
            out[1] = bytes1(uint8(v >> 8));
        } else if (n < 1073741824) {
            uint32 v = uint32((n << 2) | 0x02);
            out = new bytes(4);
            out[0] = bytes1(uint8(v));
            out[1] = bytes1(uint8(v >> 8));
            out[2] = bytes1(uint8(v >> 16));
            out[3] = bytes1(uint8(v >> 24));
        } else {
            // Big-integer mode: prefix byte = (bytes_needed - 4) << 2 | 0x03
            bytes memory raw = _uint128LE(uint128(n));
            uint8 needed = _countBytes128(uint128(n));
            out = new bytes(1 + needed);
            out[0] = bytes1(uint8(((needed - 4) << 2) | 0x03));
            for (uint8 i = 0; i < needed; i++) {
                out[1 + i] = raw[i];
            }
        }
    }

    /// @notice Encode a uint128 as little-endian bytes (16 bytes, zero-padded)
    function _uint128LE(uint128 n) private pure returns (bytes memory out) {
        out = new bytes(16);
        for (uint8 i = 0; i < 16; i++) {
            out[i] = bytes1(uint8(n >> (i * 8)));
        }
    }

    /// @notice Count the minimum number of bytes needed to represent n
    function _countBytes128(uint128 n) private pure returns (uint8 count) {
        count = 4; // minimum for big-int mode
        while (count < 16 && (n >> (count * 8)) != 0) {
            count++;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Uint helpers
    // ─────────────────────────────────────────────────────────────────────────

    function uint32LE(uint32 n) internal pure returns (bytes memory out) {
        out = new bytes(4);
        out[0] = bytes1(uint8(n));
        out[1] = bytes1(uint8(n >> 8));
        out[2] = bytes1(uint8(n >> 16));
        out[3] = bytes1(uint8(n >> 24));
    }

    function uint64LE(uint64 n) internal pure returns (bytes memory out) {
        out = new bytes(8);
        for (uint8 i = 0; i < 8; i++) {
            out[i] = bytes1(uint8(n >> (i * 8)));
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Asset encoding helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Encode DOT as a local/native asset (parents=0, Here).
    ///         Used for WithdrawAsset on AssetHub (vault's EVM balance).
    ///         Converts from 18-decimal EVM units to 10-decimal Substrate units.
    ///         Layout: Concrete(parents=0, Here) + Fungible(amount)
    /// @param amountEvm DOT amount in 18-decimal EVM units (e.g. 1e18 = 1 DOT)
    function encodeDotAsset(uint256 amountEvm) internal pure returns (bytes memory) {
        uint256 substrateAmount = amountEvm / EVM_TO_SUBSTRATE;
        return abi.encodePacked(
            bytes1(0x00),              // Concrete
            bytes1(0x00),              // parents = 0
            bytes1(0x00),              // interior = Here
            bytes1(0x01),              // Fungible
            compactEncode(substrateAmount)
        );
    }

    /// @notice Encode DOT as an AssetHub-native asset from a sibling parachain's perspective.
    ///         Post-migration (Nov 2025): DOT reserve moved from Relay to AssetHub (para 1000).
    ///         From Bifrost/Hydration, DOT is at: parents=1, X1(Parachain(1000)).
    ///         Converts from 18-decimal EVM units to 10-decimal Substrate units.
    ///         Layout: Concrete(parents=1, X1(Parachain(1000))) + Fungible(amount)
    /// @param amountEvm DOT amount in 18-decimal EVM units
    function encodeDotAssetOnDestination(uint256 amountEvm) internal pure returns (bytes memory) {
        uint256 substrateAmount = amountEvm / EVM_TO_SUBSTRATE;
        return abi.encodePacked(
            bytes1(0x00),              // Concrete
            bytes1(0x01),              // parents = 1 (up to relay)
            bytes1(0x01),              // interior = X1
            bytes1(0x00),              // junction = Parachain
            compactEncode(uint256(ASSET_HUB_PARA_ID)),  // 1000
            bytes1(0x01),              // Fungible
            compactEncode(substrateAmount)
        );
    }

    /// @notice Encode a single-asset MultiAssets vector using local DOT (parents=0).
    ///         Used in WithdrawAsset on AssetHub.
    function encodeSingleAssetVec(uint256 amount) internal pure returns (bytes memory) {
        return abi.encodePacked(
            compactEncode(1),          // vector length = 1
            encodeDotAsset(amount)
        );
    }

    /// @notice Encode a single-asset MultiAssets vector using destination DOT
    ///         (parents=1, X1(Parachain(1000))). Used in WithdrawAsset on Bifrost/Hydration.
    function encodeSingleAssetVecOnDest(uint256 amount) internal pure returns (bytes memory) {
        return abi.encodePacked(
            compactEncode(1),
            encodeDotAssetOnDestination(amount)
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Location encoding helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice SCALE-encode a Parachain destination as a VersionedLocation (for send()).
    ///         Layout: Version(V5=0x05) + Location { parents:1, X1(Parachain(id)) }
    function encodeParaDest(uint32 paraId) internal pure returns (bytes memory) {
        return abi.encodePacked(
            XCM_VERSION,         // XCM V5
            bytes1(0x01),        // parents = 1 (go up to relay chain)
            bytes1(0x01),        // interior = X1
            bytes1(0x00),        // junction = Parachain
            compactEncode(paraId)
        );
    }

    /// @notice Encode a sibling parachain as a bare Location (no version prefix).
    ///         parents=1, X1(Parachain(paraId)) — used as `dest` in DepositReserveAsset
    ///         when sending from AssetHub directly to a sibling parachain.
    ///         Post-migration: AssetHub IS the DOT reserve; sends directly to parachains.
    function encodeParaSiblingLocation(uint32 paraId) internal pure returns (bytes memory) {
        return abi.encodePacked(
            bytes1(0x01),          // parents = 1 (up to relay)
            bytes1(0x01),          // interior = X1
            bytes1(0x00),          // junction = Parachain
            compactEncode(paraId)
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // XCM Instruction builders
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Build a WithdrawAsset instruction (opcode 0x00) using local DOT (parents=0).
    ///         Withdraws DOT from the executing account into the holding register.
    ///         Used on AssetHub in execute() messages.
    function instrWithdrawAsset(uint256 amount) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes1(OP_WITHDRAW_ASSET), encodeSingleAssetVec(amount));
    }

    /// @notice Build a WithdrawAsset instruction using destination DOT
    ///         (parents=1, X1(Parachain(1000))). Used in send() messages that run
    ///         on Bifrost/Hydration where DOT is identified as AssetHub's native asset.
    function instrWithdrawAssetOnDest(uint256 amount) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes1(OP_WITHDRAW_ASSET), encodeSingleAssetVecOnDest(amount));
    }

    /// @notice Build a BuyExecution instruction (opcode 0x13) using local DOT (parents=0).
    ///         Use for: outer AssetHub context.
    function instrBuyExecution(uint256 feeAmount) internal pure returns (bytes memory) {
        return abi.encodePacked(
            bytes1(OP_BUY_EXECUTION),
            encodeDotAsset(feeAmount),
            bytes1(0x00)               // WeightLimit::Unlimited
        );
    }

    /// @notice Build a BuyExecution instruction using destination DOT
    ///         (parents=1, X1(Parachain(1000))). Used in XCM running on Bifrost/Hydration
    ///         where DOT is identified as AssetHub's native asset post-migration.
    function instrBuyExecutionDestDot(uint256 feeAmount) internal pure returns (bytes memory) {
        return abi.encodePacked(
            bytes1(OP_BUY_EXECUTION),
            encodeDotAssetOnDestination(feeAmount),
            bytes1(0x00)               // WeightLimit::Unlimited
        );
    }

    /// @notice Build a Transact instruction (opcode 0x06)
    ///         - origin_kind: SovereignAccount = 0x01
    ///         - require_weight_at_most: { refTime, proofSize } (compact-encoded)
    ///         - call: length-prefixed encoded call bytes
    function instrTransact(
        uint64 refTime,
        uint64 proofSize,
        bytes memory callBytes
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            bytes1(OP_TRANSACT),
            bytes1(0x01),                  // OriginKind::SovereignAccount
            compactEncode(refTime),        // refTime compact
            compactEncode(proofSize),      // proofSize compact
            compactEncode(callBytes.length),
            callBytes
        );
    }

    /// @notice Build a RefundSurplus instruction (opcode 0x14, no payload)
    function instrRefundSurplus() internal pure returns (bytes memory) {
        return abi.encodePacked(bytes1(OP_REFUND_SURPLUS));
    }

    /// @notice Build a DepositAsset instruction (opcode 0x0D)
    ///         - assets: Wild(All) — deposit everything in holding
    ///         - beneficiary: AccountId32 { network: None, id: accountId }
    function instrDepositAsset(bytes32 accountId) internal pure returns (bytes memory) {
        return abi.encodePacked(
            bytes1(OP_DEPOSIT_ASSET),
            // AssetFilter::Wild(WildAsset::All)
            bytes1(0x01),              // Wild variant
            bytes1(0x00),              // All variant
            // Location beneficiary: parents=0, X1(AccountId32{None, id})
            bytes1(0x00),              // parents = 0
            bytes1(0x01),              // X1 interior
            bytes1(0x01),              // AccountId32 junction variant
            bytes1(0x00),              // network = None
            accountId                  // 32-byte account ID
        );
    }

    /// @notice Build a DepositReserveAsset instruction (opcode 0x0E)
    ///         Locks assets in the current chain (acting as reserve) and sends
    ///         ReserveAssetDeposited + ClearOrigin + innerXcm to `dest`.
    ///
    ///         WARNING: ClearOrigin is auto-prepended on the destination.
    ///         Do NOT include Transact in innerXcm — it will fail with BadOrigin.
    ///         Use a separate send() call for Transact instead.
    ///
    /// @param dest      Bare Location of the destination (no version prefix)
    /// @param innerXcm  Xcm<()> bytes: compact(count) + instructions (no version prefix)
    function instrDepositReserveAsset(
        bytes memory dest,
        bytes memory innerXcm
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            bytes1(OP_DEPOSIT_RESERVE_ASSET),
            bytes1(0x01), bytes1(0x00),    // AssetFilter::Wild(All)
            dest,
            innerXcm
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Inner XCM builders — Xcm<()> (no version prefix; compact(count)+instrs)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Inner XCM for Step 1 (DOT transfer only, NO Transact).
    ///      Runs on destination after DepositReserveAsset sends DOT there.
    ///      Sequence: BuyExecution(DOT) → DepositAsset(beneficiary)
    ///
    ///      The beneficiary is the AssetHub sovereign account on the destination,
    ///      because Step 2 (send) will WithdrawAsset from the sender's sovereign
    ///      (which IS the AssetHub sovereign).
    function _buildDepositOnlyInnerXcm(
        uint256 xcmFeeAmount,
        bytes32 beneficiary
    ) private pure returns (bytes memory) {
        return abi.encodePacked(
            compactEncode(2),                           // 2 instructions
            instrBuyExecutionDestDot(xcmFeeAmount),     // fee = DOT (AssetHub perspective)
            instrDepositAsset(beneficiary)              // deposit to AssetHub sovereign
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Step 1: DOT transfer via execute() + DepositReserveAsset
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Build XCM V5 message for Step 1: transfer DOT from vault to a
    ///         sibling parachain via DepositReserveAsset.
    ///
    ///         This is an execute() message (runs locally on AssetHub).
    ///         DOT is deposited into the AssetHub sovereign account on the
    ///         destination chain, ready for Step 2's Transact to use.
    ///
    ///         Outer (AssetHub, 2 instructions):
    ///           WithdrawAsset(dotAmount)          ← vault EVM balance → holding
    ///           DepositReserveAsset(dest, inner)  ← AssetHub is DOT reserve
    ///
    ///         Inner (destination, 2 instructions — after auto-prepended ClearOrigin):
    ///           BuyExecution(DOT)                 ← pay execution fee
    ///           DepositAsset(assetHubSovereign)   ← DOT lands in AssetHub sovereign
    ///
    /// @param dotAmount         Amount of DOT to transfer
    /// @param xcmFeeAmount      DOT reserved for execution fees on destination
    /// @param assetHubSovereign 32-byte AssetHub sovereign account on destination
    /// @param destParaId        Destination parachain ID (2001 or 2034)
    function buildDotTransferXCM(
        uint256 dotAmount,
        uint256 xcmFeeAmount,
        bytes32 assetHubSovereign,
        uint32 destParaId
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            XCM_VERSION,              // XCM V5 versioned
            compactEncode(2),         // 2 outer instructions
            instrWithdrawAsset(dotAmount),
            instrDepositReserveAsset(
                encodeParaSiblingLocation(destParaId),
                _buildDepositOnlyInnerXcm(xcmFeeAmount, assetHubSovereign)
            )
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Step 2: Pallet calls via send() + Transact (origin preserved)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Build XCM V5 message for Step 2: call SLPx.mint on Bifrost.
    ///
    ///         This is a send() message (travels to Bifrost via HRMP).
    ///         Origin is preserved as AssetHub (no ClearOrigin), so Transact works.
    ///
    ///         Instructions (run on Bifrost, 5 total):
    ///           WithdrawAsset(DOT fee)          ← from AssetHub sovereign (funded in Step 1)
    ///           BuyExecution(DOT)               ← pay for execution
    ///           Transact(slpx.mint)             ← dispatched as AssetHub sovereign
    ///           RefundSurplus                   ← return unused fee
    ///           DepositAsset(vaultAccount)      ← leftover DOT + minted vDOT to vault
    ///
    /// @param xcmFeeAmount    DOT for execution fees (withdrawn from AssetHub sovereign)
    /// @param vaultAccount    32-byte vault sovereign account (receives leftovers/vDOT)
    /// @param slpxCallBytes   SCALE-encoded SLPx.mint call (from generateCallBytes.ts)
    function buildBifrostTransactXCM(
        uint256 xcmFeeAmount,
        bytes32 vaultAccount,
        bytes memory slpxCallBytes
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            XCM_VERSION,                                             // XCM V5
            compactEncode(5),                                        // 5 instructions
            instrWithdrawAssetOnDest(xcmFeeAmount),                  // from AssetHub sovereign
            instrBuyExecutionDestDot(xcmFeeAmount),                  // pay for execution
            instrTransact(10_000_000_000, 65_536, slpxCallBytes),   // call slpx.mint
            instrRefundSurplus(),                                    // return unused fee
            instrDepositAsset(vaultAccount)                          // leftovers to vault
        );
    }

    /// @notice Build XCM V5 message for Step 2: call Router.sell on Hydration.
    ///
    ///         This is a send() message (travels to Hydration via HRMP).
    ///         Origin preserved as AssetHub sovereign.
    ///
    ///         Instructions (run on Hydration, 5 total):
    ///           WithdrawAsset(DOT fee)
    ///           BuyExecution(DOT)
    ///           Transact(router.sell: DOT→aDOT→LRNA→USDT, multi-hop)
    ///           RefundSurplus
    ///           DepositAsset(vaultAccount)
    ///
    /// @param xcmFeeAmount        DOT for execution fees
    /// @param vaultAccount        32-byte vault sovereign account
    /// @param routerSellCallBytes SCALE-encoded router.sell call (from generateCallBytes.ts)
    function buildHydrationTransactXCM(
        uint256 xcmFeeAmount,
        bytes32 vaultAccount,
        bytes memory routerSellCallBytes
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            XCM_VERSION,                                                   // XCM V5
            compactEncode(5),                                              // 5 instructions
            instrWithdrawAssetOnDest(xcmFeeAmount),                        // from AssetHub sovereign
            instrBuyExecutionDestDot(xcmFeeAmount),                        // pay for execution
            instrTransact(
                100_000_000_000,  // 100B ps — 4-pool router.sell needs more weight
                262_144,          // 256 KB proof size for multi-pallet reads
                routerSellCallBytes
            ),
            instrRefundSurplus(),
            instrDepositAsset(vaultAccount)
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Utility: concatenate two byte arrays
    // ─────────────────────────────────────────────────────────────────────────
    function concat(bytes memory a, bytes memory b) internal pure returns (bytes memory out) {
        out = new bytes(a.length + b.length);
        uint256 i;
        for (i = 0; i < a.length; i++) out[i] = a[i];
        for (i = 0; i < b.length; i++) out[a.length + i] = b[i];
    }
}
