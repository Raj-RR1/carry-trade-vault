import { formatAmount } from "../utils/format";

function StateBadge({ state, paused }) {
  const label = paused ? "PAUSED" : state;
  const cls = state === "IDLE" ? "idle" : state === "EXECUTING" ? "executing" : "active";
  return <span className={`state-badge ${cls}`}>{label}</span>;
}

export function StatsGrid({ stats }) {
  return (
    <section className="stats-grid">
      <article className="metric">
        <p>Total Deposited</p>
        <h3>{formatAmount(stats.totalDeposited)} DOT</h3>
      </article>
      <article className="metric">
        <p>Total Shares</p>
        <h3>{formatAmount(stats.totalShares)}</h3>
      </article>
      <article className="metric">
        <p>Share Price</p>
        <h3>{formatAmount(stats.sharePrice)} DOT</h3>
      </article>
      <article className="metric">
        <p>Yield Harvested</p>
        <h3>{formatAmount(stats.totalYieldHarvested)} DOT</h3>
      </article>
      <article className="metric">
        <p>Bifrost Allocation</p>
        <h3>{formatAmount(stats.bifrostAmount)} DOT</h3>
      </article>
      <article className="metric">
        <p>Hydration Hedge</p>
        <h3>{formatAmount(stats.hedgeAmount)} DOT</h3>
      </article>
      <article className="metric">
        <p>Hedge Ratio</p>
        <h3>{(Number(stats.hedgeRatioBps) / 100).toFixed(1)}%</h3>
      </article>
      <article className="metric">
        <p>Vault State</p>
        <h3><StateBadge state={stats.state} paused={stats.paused} /></h3>
      </article>
    </section>
  );
}
