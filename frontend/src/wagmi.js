import { getDefaultConfig } from "@rainbow-me/rainbowkit";
import { defineChain } from "viem";

export const polkadotHub = defineChain({
  id: 420_420_419,
  name: "Polkadot Hub",
  nativeCurrency: { name: "DOT", symbol: "DOT", decimals: 18 },
  rpcUrls: { default: { http: ["https://eth-rpc.polkadot.io/"] } },
  blockExplorers: {
    default: { name: "Blockscout", url: "https://blockscout.polkadot.io" },
  },
});

export const polkadotHubTestnet = defineChain({
  id: 420_420_417,
  name: "Polkadot Hub Testnet",
  nativeCurrency: { name: "PAS", symbol: "PAS", decimals: 18 },
  rpcUrls: { default: { http: ["https://eth-rpc-testnet.polkadot.io/"] } },
  blockExplorers: {
    default: { name: "Blockscout", url: "https://blockscout-testnet.polkadot.io" },
  },
});

const envNetwork = (import.meta.env.VITE_DEFAULT_NETWORK || "testnet").toLowerCase();

const chains =
  envNetwork === "mainnet"
    ? [polkadotHub, polkadotHubTestnet]
    : [polkadotHubTestnet, polkadotHub];

export const config = getDefaultConfig({
  appName: "Carry Trade Vault",
  projectId: import.meta.env.VITE_WALLETCONNECT_PROJECT_ID || "placeholder",
  chains,
});
