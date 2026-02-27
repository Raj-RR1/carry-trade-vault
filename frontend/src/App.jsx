import { useEffect, useState } from "react";
import { useAccount } from "wagmi";
import { ContractPanel } from "./components/ContractPanel";
import { Header } from "./components/Header";
import { OwnerActions } from "./components/OwnerActions";
import { StatsGrid } from "./components/StatsGrid";
import { UserActions } from "./components/UserActions";
import { useVault } from "./hooks/useVault";

export default function App() {
  const [status, setStatus] = useState("Connect your wallet to get started.");
  const [contractAddress, setContractAddress] = useState(
    localStorage.getItem("vaultAddress") || import.meta.env.VITE_DEFAULT_CONTRACT_ADDRESS || ""
  );

  const { address: account } = useAccount();

  const { stats, isOwner, pending, canWrite, executeTx, refresh } = useVault({
    contractAddress,
    setStatus,
  });

  useEffect(() => {
    localStorage.setItem("vaultAddress", contractAddress);
  }, [contractAddress]);

  return (
    <div className="app-shell">
      <Header />

      {isOwner ? (
        <ContractPanel
          contractAddress={contractAddress}
          onContractAddressChange={setContractAddress}
        />
      ) : (
        <p className="helper" style={{ textAlign: "center" }}>
          {contractAddress ? (
            <>Vault: <code style={{ color: "var(--ink)", fontFamily: "'JetBrains Mono', monospace", fontSize: "13px" }}>{contractAddress}</code></>
          ) : (
            "Vault not yet deployed"
          )}
        </p>
      )}

      <StatsGrid stats={stats} />

      <section className={isOwner ? "grid two" : "grid-center"}>
        <UserActions
          stats={stats}
          canWrite={canWrite}
          pending={pending}
          contractAddress={contractAddress}
          executeTx={executeTx}
          refresh={refresh}
        />

        {isOwner && (
          <OwnerActions
            stats={stats}
            isOwner={isOwner}
            canWrite={canWrite}
            pending={pending}
            contractAddress={contractAddress}
            executeTx={executeTx}
          />
        )}
      </section>

      <footer className="status">{status}</footer>
    </div>
  );
}
