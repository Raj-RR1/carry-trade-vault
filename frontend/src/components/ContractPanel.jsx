import { useState } from "react";
import { shortAddress } from "../utils/format";

export function ContractPanel({ contractAddress, onContractAddressChange }) {
  const [editing, setEditing] = useState(!contractAddress);

  return (
    <section className="panel" style={{ gap: "8px", padding: "14px 20px" }}>
      <div className="meta-row" style={{ justifyContent: "space-between" }}>
        <span className="helper" style={{ display: "flex", alignItems: "center", gap: "8px" }}>
          {contractAddress ? (
            <>
              Vault:{" "}
              <code style={{ color: "var(--ink)", fontFamily: "'JetBrains Mono', monospace", fontSize: "13px" }}>
                {editing ? "" : shortAddress(contractAddress)}
              </code>
            </>
          ) : (
            "No vault address set"
          )}
        </span>
        <button
          className="secondary"
          style={{ width: "auto", padding: "4px 10px", fontSize: "12px" }}
          onClick={() => setEditing(!editing)}
        >
          {editing ? "Done" : "Change"}
        </button>
      </div>
      {editing && (
        <input
          value={contractAddress}
          onChange={(e) => onContractAddressChange(e.target.value.trim())}
          placeholder="Paste vault contract address (0x...)"
          autoFocus
        />
      )}
    </section>
  );
}
