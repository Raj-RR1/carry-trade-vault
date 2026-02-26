import { useState } from "react";
import { parseEther } from "viem";
import { formatAmount } from "../utils/format";

export function UserActions({ stats, canWrite, pending, executeTx, refresh }) {
  const [depositAmount, setDepositAmount] = useState("1");
  const [withdrawShares, setWithdrawShares] = useState("0.1");
  const canWithdraw = stats.state === "IDLE";

  return (
    <article className="panel">
      <h2>Your Position</h2>

      <div className="stats-grid" style={{ gridTemplateColumns: "repeat(3, 1fr)" }}>
        <div className="metric">
          <p>Shares</p>
          <h3>{formatAmount(stats.userShares)}</h3>
        </div>
        <div className="metric">
          <p>Value</p>
          <h3>{formatAmount(stats.userDotValue)} DOT</h3>
        </div>
        <div className="metric">
          <p>Pool %</p>
          <h3>{stats.userSharePct}%</h3>
        </div>
      </div>

      <div className="divider" />

      <label>Deposit DOT</label>
      <input
        value={depositAmount}
        onChange={(e) => setDepositAmount(e.target.value)}
        placeholder="Amount in DOT"
      />
      <button
        disabled={!canWrite || pending}
        onClick={() =>
          executeTx("Deposit", {
            functionName: "deposit",
            value: parseEther(depositAmount || "0"),
          })
        }
      >
        Deposit
      </button>

      <label>Withdraw Shares</label>
      <input
        value={withdrawShares}
        onChange={(e) => setWithdrawShares(e.target.value)}
        placeholder="Share amount"
      />
      <button
        disabled={!canWrite || pending || !canWithdraw}
        onClick={() =>
          executeTx("Withdraw", {
            functionName: "withdraw",
            args: [parseEther(withdrawShares || "0")],
          })
        }
      >
        Withdraw
      </button>
      {!canWithdraw && (
        <p className="helper">Withdrawals are paused while capital is deployed. Owner must unwind first.</p>
      )}

      <button className="secondary" onClick={refresh}>
        Refresh
      </button>
    </article>
  );
}
