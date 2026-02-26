export function formatAmount(value, max = 6) {
  const n = Number(value);
  if (!Number.isFinite(n)) return "0";
  return n.toLocaleString(undefined, { maximumFractionDigits: max });
}

export function shortAddress(addr) {
  if (!addr || addr.length < 10) return addr || "-";
  return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
}
