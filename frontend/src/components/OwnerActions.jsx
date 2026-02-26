import { useState } from "react";
import { parseEther } from "viem";
import { shortAddress } from "../utils/format";

export function OwnerActions({ stats, isOwner, canWrite, pending, executeTx }) {
  const [newHedgeBps, setNewHedgeBps] = useState("3000");
  const [bifrostCall, setBifrostCall] = useState("");
  const [hydrationCall, setHydrationCall] = useState("");
  const [substrateAccount, setSubstrateAccount] = useState("");
  const [assetHubSovereign, setAssetHubSovereign] = useState("");
  const [harvestFee, setHarvestFee] = useState("0.02");
  const [recordYieldAmount, setRecordYieldAmount] = useState("0");
  const [emergencyParaId, setEmergencyParaId] = useState("2001");
  const [emergencyMsg, setEmergencyMsg] = useState("");
  const [emergencyFee, setEmergencyFee] = useState("0");
  const [showConfig, setShowConfig] = useState(false);
  const [showEmergency, setShowEmergency] = useState(false);

  const disabled = !canWrite || !isOwner || pending;

  return (
    <article className="panel">
      <h2>Owner Controls</h2>
      <p className="helper">
        Owner: {shortAddress(stats.owner)} {isOwner ? <span className="state-badge idle">you</span> : ""}
      </p>

      {/* ── Lifecycle Actions ── */}
      <div className="owner-group">
        <div className="owner-group-title">Lifecycle</div>
        <div className="row">
          <button disabled={disabled} onClick={() => executeTx("Execute Carry", { functionName: "executeCarry" })}>
            Execute Carry
          </button>
          <button disabled={disabled} onClick={() => executeTx("Confirm Active", { functionName: "confirmActive" })}>
            Confirm Active
          </button>
          <button disabled={disabled} onClick={() => executeTx("Unwind Carry", { functionName: "unwindCarry" })}>
            Unwind
          </button>
        </div>
      </div>

      {/* ── Yield ── */}
      <div className="owner-group">
        <div className="owner-group-title">Yield Management</div>
        <label>Harvest Fee (DOT)</label>
        <input value={harvestFee} onChange={(e) => setHarvestFee(e.target.value)} placeholder="0.02" />
        <button
          disabled={disabled}
          onClick={() =>
            executeTx("Harvest", {
              functionName: "harvest",
              value: parseEther(harvestFee || "0"),
            })
          }
        >
          Harvest
        </button>

        <label>Record Yield (DOT)</label>
        <input value={recordYieldAmount} onChange={(e) => setRecordYieldAmount(e.target.value)} placeholder="0" />
        <button
          disabled={disabled}
          onClick={() =>
            executeTx("Record Yield", {
              functionName: "recordYield",
              args: [parseEther(recordYieldAmount || "0")],
            })
          }
        >
          Record Yield
        </button>
      </div>

      {/* ── Configuration (collapsible) ── */}
      <div className="owner-group">
        <div className="section-header" onClick={() => setShowConfig(!showConfig)}>
          <div className="owner-group-title">Configuration</div>
          <span className={`toggle-icon ${showConfig ? "open" : ""}`}>&#9660;</span>
        </div>
        {showConfig && (
          <>
            <label>Hedge Ratio (BPS, max 5000)</label>
            <input value={newHedgeBps} onChange={(e) => setNewHedgeBps(e.target.value)} />
            <button
              disabled={disabled}
              onClick={() =>
                executeTx("Set Hedge Ratio", {
                  functionName: "setHedgeRatio",
                  args: [BigInt(newHedgeBps || "0")],
                })
              }
            >
              Update Hedge Ratio
            </button>

            <label>Bifrost Mint Call (hex)</label>
            <textarea value={bifrostCall} onChange={(e) => setBifrostCall(e.target.value.trim())} placeholder="0x..." rows={2} />
            <label>Hydration Sell Call (hex)</label>
            <textarea value={hydrationCall} onChange={(e) => setHydrationCall(e.target.value.trim())} placeholder="0x..." rows={2} />
            <button
              disabled={disabled}
              onClick={() =>
                executeTx("Set Call Templates", {
                  functionName: "setCallTemplates",
                  args: [bifrostCall, hydrationCall],
                })
              }
            >
              Save Call Templates
            </button>

            <label>Vault Substrate Account (bytes32)</label>
            <input value={substrateAccount} onChange={(e) => setSubstrateAccount(e.target.value.trim())} placeholder="0x...32bytes" />
            <button
              disabled={disabled}
              onClick={() =>
                executeTx("Set Substrate Account", {
                  functionName: "setVaultSubstrateAccount",
                  args: [substrateAccount],
                })
              }
            >
              Save Substrate Account
            </button>

            <label>AssetHub Sovereign (bytes32)</label>
            <input value={assetHubSovereign} onChange={(e) => setAssetHubSovereign(e.target.value.trim())} placeholder="0x...32bytes" />
            <button
              disabled={disabled}
              onClick={() =>
                executeTx("Set AssetHub Sovereign", {
                  functionName: "setAssetHubSovereign",
                  args: [assetHubSovereign],
                })
              }
            >
              Save AssetHub Sovereign
            </button>
          </>
        )}
      </div>

      {/* ── Emergency (collapsible) ── */}
      <div className="owner-group">
        <div className="section-header" onClick={() => setShowEmergency(!showEmergency)}>
          <div className="owner-group-title">Emergency Recovery</div>
          <span className={`toggle-icon ${showEmergency ? "open" : ""}`}>&#9660;</span>
        </div>
        {showEmergency && (
          <>
            <label>Destination Para ID</label>
            <input value={emergencyParaId} onChange={(e) => setEmergencyParaId(e.target.value)} />
            <label>XCM Message (hex)</label>
            <textarea value={emergencyMsg} onChange={(e) => setEmergencyMsg(e.target.value.trim())} placeholder="0x..." rows={3} />
            <label>Fee DOT (optional)</label>
            <input value={emergencyFee} onChange={(e) => setEmergencyFee(e.target.value)} />
            <button
              disabled={disabled}
              onClick={() =>
                executeTx("Emergency Recover XCM", {
                  functionName: "emergencyRecoverXCM",
                  args: [Number(emergencyParaId || "0"), emergencyMsg],
                  value: parseEther(emergencyFee || "0"),
                })
              }
            >
              Send Emergency XCM
            </button>
          </>
        )}
      </div>

      {/* ── Pause / Unpause ── */}
      <div className="row">
        <button className="secondary" disabled={disabled} onClick={() => executeTx("Pause", { functionName: "pause" })}>
          Pause
        </button>
        <button className="secondary" disabled={disabled} onClick={() => executeTx("Unpause", { functionName: "unpause" })}>
          Unpause
        </button>
      </div>
    </article>
  );
}
