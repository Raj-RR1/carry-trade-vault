import { ConnectButton } from "@rainbow-me/rainbowkit";

export function Header() {
  return (
    <header className="topbar">
      <div>
        <p className="eyebrow">Polkadot Hub / Cross-Chain DeFi</p>
        <h1>Carry Trade Vault</h1>
      </div>
      <ConnectButton.Custom>
        {({ account, chain, openAccountModal, openChainModal, openConnectModal, mounted }) => {
          const connected = mounted && account && chain;

          if (!connected) {
            return (
              <button onClick={openConnectModal} style={{ width: "auto", padding: "10px 20px" }}>
                Connect Wallet
              </button>
            );
          }

          return (
            <div className="wallet-bar">
              <button className="wallet-chain" onClick={openChainModal}>
                {chain.unsupported ? "Wrong Network" : chain.name}
              </button>
              <button className="wallet-account" onClick={openAccountModal}>
                <span className="wallet-balance">{account.displayBalance || ""}</span>
                <span className="wallet-address">{account.address.slice(0, 6)}...{account.address.slice(-6)}</span>
              </button>
            </div>
          );
        }}
      </ConnectButton.Custom>
    </header>
  );
}
