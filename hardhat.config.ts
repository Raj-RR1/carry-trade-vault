import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-ethers";
import "@nomicfoundation/hardhat-chai-matchers";
import * as dotenv from "dotenv";

dotenv.config();

const PRIVATE_KEY = process.env.PRIVATE_KEY || "0x" + "0".repeat(64);

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    // Polkadot Hub Mainnet — REVM (standard EVM bytecode)
    polkadotHub: {
      url: "https://services.polkadothub-rpc.com/mainnet/",
      chainId: 420420419,
      accounts: [PRIVATE_KEY],
      gasPrice: 800_000_000_000,
    },
    // Polkadot Hub Testnet — REVM
    polkadotHubTest: {
      url: "https://services.polkadothub-rpc.com/testnet/",
      chainId: 420420417,
      accounts: [PRIVATE_KEY],
      gasPrice: 800_000_000_000,
    },
    // Local Hardhat for unit tests — standard solc (no polkadot flag)
    hardhat: {
      chainId: 31337,
    },
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },
};

export default config;
