// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interfaces/IXcm.sol";
import "./XCMBuilder.sol";

/// @title CarryTradeVault
/// @notice Cross-chain carry trade vault deployed on Polkadot Hub (AssetHub).
///
///         The carry trade captures the spread between:
///           - DOT staking yield via Bifrost SLPx (~15% APY as vDOT)
///           - Basis hedge cost via Hydration Router (~2%)
///           = ~13% net carry APY
///
///         Flow:
///           1. Users deposit DOT (native currency) and receive shares
///           2. Owner calls executeCarry() to deploy capital cross-chain:
///              a. execute() → DepositReserveAsset → DOT to Bifrost sovereign
///              b. send()   → Transact → SLPx.mint(DOT to vDOT)
///              c. execute() → DepositReserveAsset → DOT to Hydration sovereign
///              d. send()   → Transact → Router.sell(DOT to USDT hedge)
///           3. Yield accrues on Bifrost (vDOT exchange rate increases)
///           4. Owner calls harvest() periodically to claim yield
///           5. Users withdraw shares for DOT + accumulated yield
///
///         Why 2 steps per destination:
///           DepositReserveAsset auto-prepends ClearOrigin on the destination,
///           which sets origin = None. Transact needs a valid origin to dispatch
///           pallet calls. By using send() separately, origin is preserved as
///           the AssetHub sovereign account.
///
///         Track 2 features used:
///           - XCM precompile (0x00...0a0000): execute() + send() for cross-chain ops
///           - XCMBuilder library: SCALE encoding in Solidity (PVM experiment)
///           - Native DOT as msg.value (Polkadot native asset)
///
/// @dev Deployed on Polkadot Hub mainnet (Chain ID 420420419)
///      XCM precompile: 0x00000000000000000000000000000000000a0000
contract CarryTradeVault is Ownable, ReentrancyGuard, Pausable {
    using XCMBuilder for *;

    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev XCM precompile on Polkadot Hub
    IXcm public constant XCM = IXcm(XCM_PRECOMPILE);

    /// @dev Bifrost Polkadot parachain ID
    uint32 public constant BIFROST_PARA_ID = 2001;

    /// @dev Hydration parachain ID
    uint32 public constant HYDRATION_PARA_ID = 2034;

    /// @dev Maximum hedge ratio: 50% of capital
    uint256 public constant MAX_HEDGE_BPS = 5000;

    /// @dev Basis points denominator
    uint256 public constant BPS_DENOM = 10_000;

    /// @dev XCM fee for Step 1 inner XCM (BuyExecution + DepositAsset on destination).
    ///      Lightweight — only 2 instructions, no Transact.
    uint256 public constant XCM_TRANSFER_FEE = 0.01 ether;

    /// @dev XCM fee for Step 2 Bifrost Transact (slpx.mint).
    ///      BuyExecution charges upfront based on require_weight_at_most (10B ref_time).
    uint256 public constant XCM_BIFROST_FEE = 0.05 ether;

    /// @dev XCM fee for Step 2 Hydration Transact (router.sell multi-hop).
    ///      BuyExecution charges upfront based on require_weight_at_most (100B ref_time).
    ///      Excess refunded via RefundSurplus + DepositAsset.
    uint256 public constant XCM_HYDRATION_FEE = 0.1 ether;

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Vault lifecycle state
    enum VaultState {
        IDLE,      // No active position; accepts deposits
        EXECUTING, // XCM messages sent; awaiting cross-chain confirmation
        ACTIVE     // Capital deployed on Bifrost + Hydration; earning yield
    }

    VaultState public state;

    /// @notice Total DOT deposited by all users (18-decimal)
    uint256 public totalDeposited;

    /// @notice Total yield harvested from Bifrost (18-decimal)
    uint256 public totalYieldHarvested;

    /// @notice Fraction of capital to hedge on Hydration (basis points)
    uint256 public hedgeRatioBps;

    /// @notice Total vault shares outstanding
    uint256 public totalShares;

    /// @notice Each user's share balance
    mapping(address => uint256) public shares;

    /// @notice SCALE-encoded Bifrost SLPx.mint call bytes.
    ///         Generated off-chain by scripts/generateCallBytes.ts
    ///         Set by owner via setCallTemplates()
    bytes public bifrostMintCall;

    /// @notice SCALE-encoded Hydration Router.sell call bytes.
    bytes public hydrationSellCall;

    /// @notice 32-byte substrate account ID of this vault on remote chains.
    ///         This is the account that receives minted vDOT and trade proceeds.
    ///         Derived from the contract's EVM address.
    bytes32 public vaultSubstrateAccount;

    /// @notice 32-byte AssetHub sovereign account on Bifrost/Hydration.
    ///         This is the account that receives DOT via DepositReserveAsset (Step 1)
    ///         and from which Transact dispatches pallet calls (Step 2).
    ///         Derived as: blake2_256("sibl" ++ LE(1000))
    bytes32 public assetHubSovereign;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event Deposited(address indexed user, uint256 dotAmount, uint256 sharesIssued);
    event CarryExecuted(uint256 bifrostAmount, uint256 hedgeAmount, uint256 timestamp);
    event CarryConfirmed(uint256 timestamp);
    event HarvestInitiated(uint256 feeSent, uint256 timestamp);
    event YieldReceived(uint256 amount, uint256 newTotalDeposited);
    event Withdrawn(address indexed user, uint256 sharesRedeemed, uint256 dotReturned);
    event PositionUnwound(uint256 timestamp);
    event HedgeRatioUpdated(uint256 oldBps, uint256 newBps);
    event CallTemplatesUpdated();
    event SubstrateAccountUpdated(bytes32 account);
    event AssetHubSovereignUpdated(bytes32 account);
    event EmergencyXCMSent(uint32 destParaId, uint256 timestamp);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error InvalidState(VaultState current, VaultState required);
    error ZeroDeposit();
    error ZeroShares();
    error HedgeRatioTooHigh(uint256 bps);
    error CallTemplatesNotSet();
    error SubstrateAccountNotSet();
    error AssetHubSovereignNotSet();
    error InsufficientBalance(uint256 available, uint256 requested);
    error InsufficientFee(uint256 sent, uint256 required);
    error WithdrawNotAllowed(VaultState current);

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    /// @param initialHedgeRatioBps Fraction of capital to hedge (e.g. 3000 = 30%)
    constructor(uint256 initialHedgeRatioBps) Ownable(msg.sender) {
        if (initialHedgeRatioBps > MAX_HEDGE_BPS) revert HedgeRatioTooHigh(initialHedgeRatioBps);
        hedgeRatioBps = initialHedgeRatioBps;
        state = VaultState.IDLE;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // User-facing functions
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Deposit DOT and receive proportional vault shares.
    ///         Deposits are accepted in IDLE and ACTIVE states.
    ///         In ACTIVE state new deposits wait for the next carry cycle.
    function deposit() external payable nonReentrant whenNotPaused {
        if (msg.value == 0) revert ZeroDeposit();
        if (state == VaultState.EXECUTING) revert InvalidState(state, VaultState.IDLE);

        uint256 sharesToIssue;
        if (totalShares == 0 || totalDeposited == 0) {
            // First deposit: shares 1:1 with deposited amount (1e18 precision)
            sharesToIssue = msg.value;
        } else {
            // Pro-rata: newShares = (depositAmount / totalDeposited) * totalShares
            sharesToIssue = (msg.value * totalShares) / totalDeposited;
        }

        if (sharesToIssue == 0) revert ZeroShares();

        shares[msg.sender] += sharesToIssue;
        totalShares += sharesToIssue;
        totalDeposited += msg.value;

        emit Deposited(msg.sender, msg.value, sharesToIssue);
    }

    /// @notice Withdraw DOT by redeeming vault shares.
    ///         Only allowed in IDLE state (before carry execution or after unwind).
    ///         In EXECUTING/ACTIVE states, DOT is deployed cross-chain — call
    ///         unwindCarry() first to return funds to the vault.
    /// @param shareAmount Number of shares to redeem
    function withdraw(uint256 shareAmount) external nonReentrant whenNotPaused {
        if (state != VaultState.IDLE) revert WithdrawNotAllowed(state);
        if (shares[msg.sender] < shareAmount) {
            revert InsufficientBalance(shares[msg.sender], shareAmount);
        }
        if (shareAmount == 0) revert ZeroShares();

        // Calculate proportional DOT amount
        uint256 dotToReturn = (shareAmount * totalDeposited) / totalShares;

        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        totalDeposited -= dotToReturn;

        (bool success, ) = payable(msg.sender).call{value: dotToReturn}("");
        require(success, "DOT transfer failed");

        emit Withdrawn(msg.sender, shareAmount, dotToReturn);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Owner: carry trade execution
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Deploy vault capital cross-chain to open the carry trade.
    ///
    ///         Uses a 2-step pattern per destination to avoid the ClearOrigin issue:
    ///
    ///         Step 1 (execute): DepositReserveAsset moves DOT from vault to the
    ///         AssetHub sovereign account on the destination chain. ClearOrigin is
    ///         auto-prepended but that's OK — no Transact in this step.
    ///
    ///         Step 2 (send): Transact calls the pallet (slpx.mint / router.sell).
    ///         Origin is preserved as AssetHub, so Transact dispatches correctly.
    ///         WithdrawAsset pulls DOT from AssetHub sovereign (funded in Step 1).
    ///
    ///         Total: 4 XCM calls (2 execute + 2 send).
    ///         XCM messages from the same block are processed FIFO on destination,
    ///         so Step 1 always completes before Step 2.
    function executeCarry() external onlyOwner whenNotPaused {
        if (state != VaultState.IDLE) revert InvalidState(state, VaultState.IDLE);
        if (bifrostMintCall.length == 0 || hydrationSellCall.length == 0) {
            revert CallTemplatesNotSet();
        }
        if (vaultSubstrateAccount == bytes32(0)) revert SubstrateAccountNotSet();
        if (assetHubSovereign == bytes32(0)) revert AssetHubSovereignNotSet();

        uint256 hedgeAmount   = (totalDeposited * hedgeRatioBps) / BPS_DENOM;
        uint256 bifrostAmount = totalDeposited - hedgeAmount;

        // ── Bifrost: Step 1 — transfer DOT via DepositReserveAsset ──────────
        bytes memory bifrostTransfer = XCMBuilder.buildDotTransferXCM(
            bifrostAmount,
            XCM_TRANSFER_FEE,
            assetHubSovereign,
            BIFROST_PARA_ID
        );
        XCM.execute(bifrostTransfer, XCM.weighMessage(bifrostTransfer));

        // ── Bifrost: Step 2 — call SLPx.mint via send() + Transact ──────────
        bytes memory bifrostDest = XCMBuilder.encodeParaDest(BIFROST_PARA_ID);
        bytes memory bifrostTransact = XCMBuilder.buildBifrostTransactXCM(
            XCM_BIFROST_FEE,
            vaultSubstrateAccount,
            bifrostMintCall
        );
        XCM.send(bifrostDest, bifrostTransact);

        // ── Hydration: Step 1 — transfer DOT via DepositReserveAsset ────────
        bytes memory hydrationTransfer = XCMBuilder.buildDotTransferXCM(
            hedgeAmount,
            XCM_TRANSFER_FEE,
            assetHubSovereign,
            HYDRATION_PARA_ID
        );
        XCM.execute(hydrationTransfer, XCM.weighMessage(hydrationTransfer));

        // ── Hydration: Step 2 — call Router.sell via send() + Transact ──────
        bytes memory hydrationDest = XCMBuilder.encodeParaDest(HYDRATION_PARA_ID);
        bytes memory hydrationTransact = XCMBuilder.buildHydrationTransactXCM(
            XCM_HYDRATION_FEE,
            vaultSubstrateAccount,
            hydrationSellCall
        );
        XCM.send(hydrationDest, hydrationTransact);

        state = VaultState.EXECUTING;

        emit CarryExecuted(bifrostAmount, hedgeAmount, block.timestamp);
    }

    /// @notice Confirm the carry trade is active after XCM execution is verified.
    ///         Called by owner after observing XCM execution on Bifrost + Hydration
    ///         (via Subscan cross-chain explorer or off-chain indexer).
    function confirmActive() external onlyOwner {
        if (state != VaultState.EXECUTING) revert InvalidState(state, VaultState.EXECUTING);
        state = VaultState.ACTIVE;
        emit CarryConfirmed(block.timestamp);
    }

    /// @notice Harvest accrued vDOT yield from Bifrost.
    ///         Owner must set bifrostMintCall to an SLPx.redeem call before invoking.
    ///         vDOT exchange rate auto-increases; redeem converts vDOT back to DOT.
    ///
    ///         This is a 2-step XCM operation (same pattern as executeCarry):
    ///           Step 1 (execute): Send fee DOT to AssetHub sovereign on Bifrost
    ///           Step 2 (send):    Transact slpx.redeem as AssetHub sovereign
    ///
    ///         The redeemed DOT returns asynchronously via XCM to the vault's
    ///         receive() function. Call recordYield() after DOT arrives.
    ///
    ///         Must send msg.value >= XCM_TRANSFER_FEE + XCM_BIFROST_FEE to cover both steps.
    function harvest() external payable onlyOwner {
        if (state != VaultState.ACTIVE) revert InvalidState(state, VaultState.ACTIVE);
        uint256 minFee = XCM_TRANSFER_FEE + XCM_BIFROST_FEE;
        if (msg.value < minFee) revert InsufficientFee(msg.value, minFee);

        // Step 1: Send fee DOT to AssetHub sovereign on Bifrost
        bytes memory feeTransfer = XCMBuilder.buildDotTransferXCM(
            msg.value,
            XCM_TRANSFER_FEE,
            assetHubSovereign,
            BIFROST_PARA_ID
        );
        XCM.execute(feeTransfer, XCM.weighMessage(feeTransfer));

        // Step 2: Transact slpx.redeem on Bifrost
        bytes memory bifrostDest = XCMBuilder.encodeParaDest(BIFROST_PARA_ID);
        bytes memory harvestMsg = XCMBuilder.buildBifrostTransactXCM(
            XCM_BIFROST_FEE,
            vaultSubstrateAccount,
            bifrostMintCall  // owner sets this to a redeem call before harvesting
        );
        XCM.send(bifrostDest, harvestMsg);

        emit HarvestInitiated(msg.value, block.timestamp);
    }

    /// @notice Record yield that arrived via XCM from Bifrost.
    ///         Called by owner after observing DOT returned to the vault's balance.
    ///         This increases totalDeposited, raising the share price for all holders.
    /// @param yieldAmount The amount of yield DOT that arrived (18-decimal)
    function recordYield(uint256 yieldAmount) external onlyOwner {
        if (state != VaultState.ACTIVE) revert InvalidState(state, VaultState.ACTIVE);
        totalDeposited += yieldAmount;
        totalYieldHarvested += yieldAmount;
        emit YieldReceived(yieldAmount, totalDeposited);
    }

    /// @notice Unwind the carry trade and return to IDLE state.
    ///         Called by owner after all cross-chain assets have been redeemed
    ///         and DOT has returned to the vault's balance.
    ///         This re-enables user withdrawals.
    function unwindCarry() external onlyOwner {
        if (state != VaultState.ACTIVE) revert InvalidState(state, VaultState.ACTIVE);
        state = VaultState.IDLE;
        emit PositionUnwound(block.timestamp);
    }

    /// @notice Emergency: send arbitrary XCM to recover trapped assets.
    ///         Owner can send custom XCM messages to Bifrost/Hydration to
    ///         retrieve DOT/vDOT stuck in sovereign accounts after a failed
    ///         cross-chain operation.
    ///
    ///         Step 1 (if msg.value > 0): Send fee DOT to AssetHub sovereign
    ///         Step 2: Send the provided XCM message to the destination
    ///
    /// @param destParaId   Destination parachain ID (2001 for Bifrost, 2034 for Hydration)
    /// @param xcmMessage   SCALE-encoded VersionedXcm message to send
    function emergencyRecoverXCM(
        uint32 destParaId,
        bytes calldata xcmMessage
    ) external payable onlyOwner {
        // Optionally fund AssetHub sovereign with fee DOT
        if (msg.value > 0) {
            bytes memory feeTransfer = XCMBuilder.buildDotTransferXCM(
                msg.value,
                XCM_TRANSFER_FEE,
                assetHubSovereign,
                destParaId
            );
            XCM.execute(feeTransfer, XCM.weighMessage(feeTransfer));
        }

        // Send the recovery XCM message
        bytes memory dest = XCMBuilder.encodeParaDest(destParaId);
        XCM.send(dest, xcmMessage);

        emit EmergencyXCMSent(destParaId, block.timestamp);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Owner: configuration
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Set the SCALE-encoded call bytes for Bifrost and Hydration.
    ///         Generate these with scripts/generateCallBytes.ts
    ///
    ///         IMPORTANT: The call bytes contain hardcoded DOT amounts (encoded
    ///         by polkadot-js API). The owner MUST regenerate and update these
    ///         before each executeCarry() call to match the actual deposit amount.
    ///         Example: if totalDeposited = 50 DOT with 30% hedge:
    ///           - Regenerate bifrost call with amount = 35 DOT (70%)
    ///           - Regenerate hydration call with amount = 15 DOT (30%)
    ///           - Call setCallTemplates() with the new bytes
    ///           - Then call executeCarry()
    function setCallTemplates(
        bytes calldata _bifrostMintCall,
        bytes calldata _hydrationSellCall
    ) external onlyOwner {
        bifrostMintCall = _bifrostMintCall;
        hydrationSellCall = _hydrationSellCall;
        emit CallTemplatesUpdated();
    }

    /// @notice Update the vault's sovereign substrate account on remote chains.
    ///         Derive this from the contract address using accountId32FromEvm().
    function setVaultSubstrateAccount(bytes32 _account) external onlyOwner {
        vaultSubstrateAccount = _account;
        emit SubstrateAccountUpdated(_account);
    }

    /// @notice Set the AssetHub sovereign account on Bifrost/Hydration.
    ///         This is blake2_256("sibl" ++ LE(1000)) — same on all sibling chains.
    ///         DOT is deposited here in Step 1 and withdrawn by Step 2.
    function setAssetHubSovereign(bytes32 _account) external onlyOwner {
        assetHubSovereign = _account;
        emit AssetHubSovereignUpdated(_account);
    }

    /// @notice Update the hedge ratio (capped at MAX_HEDGE_BPS = 50%).
    function setHedgeRatio(uint256 newBps) external onlyOwner {
        if (newBps > MAX_HEDGE_BPS) revert HedgeRatioTooHigh(newBps);
        emit HedgeRatioUpdated(hedgeRatioBps, newBps);
        hedgeRatioBps = newBps;
    }

    /// @notice Pause all state-changing operations.
    function pause() external onlyOwner { _pause(); }

    /// @notice Unpause operations.
    function unpause() external onlyOwner { _unpause(); }

    // ─────────────────────────────────────────────────────────────────────────
    // View functions
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Current price of one share in DOT (18-decimal)
    function sharePrice() external view returns (uint256) {
        if (totalShares == 0) return 1e18;
        return (totalDeposited * 1e18) / totalShares;
    }

    /// @notice A user's proportional DOT value
    function positionValue(address user) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return (shares[user] * totalDeposited) / totalShares;
    }

    /// @notice Full position details for a user
    function getPosition(address user)
        external
        view
        returns (
            uint256 userShares,
            uint256 dotValue,
            uint256 sharePct  // share of total pool in basis points
        )
    {
        userShares = shares[user];
        if (totalShares == 0) {
            dotValue = 0;
            sharePct = 0;
        } else {
            dotValue = (userShares * totalDeposited) / totalShares;
            sharePct = (userShares * BPS_DENOM) / totalShares;
        }
    }

    /// @notice Estimated bifrost deployment amount (after hedge split)
    function bifrostDeploymentAmount() external view returns (uint256) {
        return totalDeposited - (totalDeposited * hedgeRatioBps) / BPS_DENOM;
    }

    /// @notice Estimated hedge amount
    function hedgeDeploymentAmount() external view returns (uint256) {
        return (totalDeposited * hedgeRatioBps) / BPS_DENOM;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Receive ETH/DOT
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Accept DOT returned from XCM (yield from Bifrost, hedge proceeds, etc.)
    receive() external payable {}
}
