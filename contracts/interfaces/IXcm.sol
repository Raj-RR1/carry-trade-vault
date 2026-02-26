// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev XCM precompile address on Polkadot Hub (AssetHub mainnet & testnet)
address constant XCM_PRECOMPILE = 0x00000000000000000000000000000000000a0000;

/// @title IXcm
/// @notice Interface for the Polkadot Hub XCM precompile
/// @dev Precompile at 0x00000000000000000000000000000000000a0000
///      Allows Solidity contracts to send and execute XCM messages cross-chain.
interface IXcm {
    /// @notice Computational weight for XCM execution
    struct Weight {
        uint64 refTime;    // Computation time on reference hardware
        uint64 proofSize;  // Size of state proof required
    }

    /// @notice Execute an XCM message locally on Polkadot Hub
    /// @param message SCALE-encoded Versioned XCM message
    /// @param weight  Maximum weight to spend on execution
    function execute(bytes calldata message, Weight calldata weight) external;

    /// @notice Send an XCM message to a remote chain
    /// @param destination SCALE-encoded MultiLocation of the target chain
    /// @param message     SCALE-encoded Versioned XCM message
    function send(bytes calldata destination, bytes calldata message) external;

    /// @notice Estimate the weight needed to execute an XCM message
    /// @param message SCALE-encoded Versioned XCM message
    /// @return weight Estimated computational weight
    function weighMessage(bytes calldata message) external view returns (Weight memory weight);
}
