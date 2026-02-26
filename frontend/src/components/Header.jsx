import { ConnectButton } from "@rainbow-me/rainbowkit";

export function Header() {
  return (
    <header className="topbar">
      <div>
        <p className="eyebrow">Polkadot Hub / Cross-Chain DeFi</p>
        <h1>Carry Trade Vault</h1>
      </div>
      <ConnectButton />
    </header>
  );
}
