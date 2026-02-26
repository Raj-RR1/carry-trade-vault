// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../XCMBuilder.sol";

/// @title XCMBuilderHarness
/// @notice Exposes XCMBuilder library functions as external calls for testing.
contract XCMBuilderHarness {
    function compactEncode(uint256 n) external pure returns (bytes memory) {
        return XCMBuilder.compactEncode(n);
    }

    function encodeParaDest(uint32 paraId) external pure returns (bytes memory) {
        return XCMBuilder.encodeParaDest(paraId);
    }

    function encodeDotAsset(uint256 amount) external pure returns (bytes memory) {
        return XCMBuilder.encodeDotAsset(amount);
    }

    function encodeDotAssetOnDestination(uint256 amount) external pure returns (bytes memory) {
        return XCMBuilder.encodeDotAssetOnDestination(amount);
    }

    function buildDotTransferXCM(
        uint256 dotAmount,
        uint256 xcmFeeAmount,
        bytes32 assetHubSovereign,
        uint32 destParaId
    ) external pure returns (bytes memory) {
        return XCMBuilder.buildDotTransferXCM(dotAmount, xcmFeeAmount, assetHubSovereign, destParaId);
    }

    function buildBifrostTransactXCM(
        uint256 xcmFeeAmount,
        bytes32 vaultAccount,
        bytes calldata slpxCallBytes
    ) external pure returns (bytes memory) {
        return XCMBuilder.buildBifrostTransactXCM(xcmFeeAmount, vaultAccount, slpxCallBytes);
    }

    function buildHydrationTransactXCM(
        uint256 xcmFeeAmount,
        bytes32 vaultAccount,
        bytes calldata routerSellCallBytes
    ) external pure returns (bytes memory) {
        return XCMBuilder.buildHydrationTransactXCM(xcmFeeAmount, vaultAccount, routerSellCallBytes);
    }
}
