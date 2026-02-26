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
    // Polkadot Hub Mainnet
    polkadotHub: {
      url: "https://eth-rpc.polkadot.io/",
      chainId: 420420419,
      accounts: [PRIVATE_KEY],
    },
    // Polkadot Hub Testnet (Paseo)
    polkadotHubTest: {
      url: "https://eth-rpc-testnet.polkadot.io/",
      chainId: 420420417,
      accounts: [PRIVATE_KEY],
    },
    // Local Hardhat for unit tests
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
