import { useCallback, useEffect, useMemo, useState } from "react";
import { useAccount, useReadContracts, useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { formatEther, isAddress } from "viem";
import { carryTradeVaultAbi } from "../abi/carryTradeVaultAbi";

const EMPTY_STATS = {
  owner: "-",
  state: "-",
  totalDeposited: "0",
  totalShares: "0",
  totalYieldHarvested: "0",
  hedgeRatioBps: "0",
  sharePrice: "0",
  bifrostAmount: "0",
  hedgeAmount: "0",
  vaultSubstrateAccount: "0x",
  assetHubSovereign: "0x",
  paused: false,
  userShares: "0",
  userDotValue: "0",
  userSharePct: "0",
};

export function useVault({ contractAddress, setStatus }) {
  const { address: account } = useAccount();
  const validAddress = isAddress(contractAddress || "");

  const contractBase = useMemo(
    () => (validAddress ? { address: contractAddress, abi: carryTradeVaultAbi } : null),
    [contractAddress, validAddress]
  );

  // ── Batch read all vault state ──
  const { data: readData, refetch } = useReadContracts({
    contracts: contractBase
      ? [
          { ...contractBase, functionName: "owner" },
          { ...contractBase, functionName: "state" },
          { ...contractBase, functionName: "totalDeposited" },
          { ...contractBase, functionName: "totalShares" },
          { ...contractBase, functionName: "totalYieldHarvested" },
          { ...contractBase, functionName: "hedgeRatioBps" },
          { ...contractBase, functionName: "sharePrice" },
          { ...contractBase, functionName: "bifrostDeploymentAmount" },
          { ...contractBase, functionName: "hedgeDeploymentAmount" },
          { ...contractBase, functionName: "vaultSubstrateAccount" },
          { ...contractBase, functionName: "assetHubSovereign" },
          { ...contractBase, functionName: "paused" },
          ...(account
            ? [{ ...contractBase, functionName: "getPosition", args: [account] }]
            : []),
        ]
      : [],
    query: { enabled: !!contractBase },
  });

  // ── Parse read results into stats object ──
  const stats = useMemo(() => {
    if (!readData || readData.length < 12) return EMPTY_STATS;

    const get = (i) => readData[i]?.result;
    const stateNum = Number(get(1) ?? 0);
    const currentState = ["IDLE", "EXECUTING", "ACTIVE"][stateNum] || `UNKNOWN(${stateNum})`;

    let userShares = 0n;
    let userDotValue = 0n;
    let userSharePct = 0n;

    if (account && readData.length > 12 && readData[12]?.result) {
      const pos = readData[12].result;
      userShares = pos[0] ?? 0n;
      userDotValue = pos[1] ?? 0n;
      userSharePct = pos[2] ?? 0n;
    }

    return {
      owner: get(0) || "-",
      state: currentState,
      totalDeposited: formatEther(get(2) ?? 0n),
      totalShares: formatEther(get(3) ?? 0n),
      totalYieldHarvested: formatEther(get(4) ?? 0n),
      hedgeRatioBps: (get(5) ?? 0n).toString(),
      sharePrice: formatEther(get(6) ?? 0n),
      bifrostAmount: formatEther(get(7) ?? 0n),
      hedgeAmount: formatEther(get(8) ?? 0n),
      vaultSubstrateAccount: get(9) || "0x",
      assetHubSovereign: get(10) || "0x",
      paused: get(11) ?? false,
      userShares: formatEther(userShares),
      userDotValue: formatEther(userDotValue),
      userSharePct: (Number(userSharePct) / 100).toFixed(2),
    };
  }, [readData, account]);

  const isOwner = account && stats.owner !== "-" && stats.owner.toLowerCase() === account.toLowerCase();

  // ── Write contract ──
  const {
    data: hash,
    writeContract: wagmiWrite,
    isPending: isWritePending,
    error: writeError,
    reset: resetWrite,
  } = useWriteContract();

  const { isLoading: isConfirming, isSuccess: isConfirmed } = useWaitForTransactionReceipt({ hash });

  const pending = isWritePending || isConfirming;

  // Track status messages
  const [txLabel, setTxLabel] = useState("");

  useEffect(() => {
    if (isWritePending && txLabel) {
      setStatus(`${txLabel}: waiting for wallet confirmation...`);
    }
  }, [isWritePending, txLabel, setStatus]);

  useEffect(() => {
    if (hash && txLabel) {
      setStatus(`${txLabel}: submitted ${hash}. Confirming...`);
    }
  }, [hash, txLabel, setStatus]);

  useEffect(() => {
    if (isConfirmed && txLabel) {
      setStatus(`${txLabel}: confirmed.`);
      refetch();
      setTxLabel("");
      resetWrite();
    }
  }, [isConfirmed, txLabel, setStatus, refetch, resetWrite]);

  useEffect(() => {
    if (writeError && txLabel) {
      setStatus(`${txLabel}: ${writeError.shortMessage || writeError.message}`);
      setTxLabel("");
      resetWrite();
    }
  }, [writeError, txLabel, setStatus, resetWrite]);

  // Generic write helper — components call this
  const executeTx = useCallback(
    (label, writeArgs) => {
      if (!validAddress) {
        setStatus("Set a valid contract address first.");
        return;
      }
      setTxLabel(label);
      wagmiWrite({
        address: contractAddress,
        abi: carryTradeVaultAbi,
        ...writeArgs,
      });
    },
    [contractAddress, validAddress, setStatus, wagmiWrite]
  );

  return {
    stats,
    isOwner,
    pending,
    canWrite: !!account && validAddress,
    executeTx,
    refresh: refetch,
  };
}
