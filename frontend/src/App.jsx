import { useEffect, useState } from "react";
import { useAccount } from "wagmi";
import { ContractPanel } from "./components/ContractPanel";
import { Header } from "./components/Header";
import { OwnerActions } from "./components/OwnerActions";
import { StatsGrid } from "./components/StatsGrid";
import { UserActions } from "./components/UserActions";
import { useVault } from "./hooks/useVault";

export default function App() {
  const [status, setStatus] = useState("Connect wallet and set your deployed contract address.");
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

      <ContractPanel
        contractAddress={contractAddress}
        onContractAddressChange={setContractAddress}
      />

      <StatsGrid stats={stats} />

      <section className="grid two">
        <UserActions
          stats={stats}
          canWrite={canWrite}
          pending={pending}
          contractAddress={contractAddress}
          executeTx={executeTx}
          refresh={refresh}
        />

        <OwnerActions
          stats={stats}
          isOwner={isOwner}
          canWrite={canWrite}
          pending={pending}
          contractAddress={contractAddress}
          executeTx={executeTx}
        />
      </section>

      <footer className="status">{status}</footer>
    </div>
  );
}
