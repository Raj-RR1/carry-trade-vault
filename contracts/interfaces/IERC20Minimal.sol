// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IERC20Minimal
/// @notice Minimal ERC20 interface for vDOT and other foreign assets on Polkadot Hub
interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}
