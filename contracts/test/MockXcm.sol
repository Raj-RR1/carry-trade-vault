// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockXcm
/// @notice Test double for the XCM precompile.
///         Records all send() and execute() calls so tests can assert on them.
contract MockXcm {
    struct Weight {
        uint64 refTime;
        uint64 proofSize;
    }

    // ── send() recording ──────────────────────────────────────────────────────

    struct SendCall {
        bytes destination;
        bytes message;
    }

    SendCall[] private _sendCalls;
    uint256 public sendCallCount;

    function send(bytes calldata destination, bytes calldata message) external {
        _sendCalls.push(SendCall({ destination: destination, message: message }));
        sendCallCount++;
    }

    /// @notice Get the destination bytes for the n-th send() call
    function getSendDest(uint256 index) external view returns (string memory) {
        require(index < _sendCalls.length, "MockXcm: index out of bounds");
        return _toHexString(_sendCalls[index].destination);
    }

    /// @notice Get the message bytes for the n-th send() call
    function getSendMsg(uint256 index) external view returns (bytes memory) {
        require(index < _sendCalls.length, "MockXcm: index out of bounds");
        return _sendCalls[index].message;
    }

    // ── execute() recording ───────────────────────────────────────────────────

    struct ExecuteCall {
        bytes message;
        Weight weight;
    }

    ExecuteCall[] private _executeCalls;
    uint256 public executeCallCount;

    function execute(bytes calldata message, Weight calldata weight) external {
        _executeCalls.push(ExecuteCall({ message: message, weight: weight }));
        executeCallCount++;
    }

    /// @notice Get the message bytes for the n-th execute() call as hex string
    function getExecuteMsg(uint256 index) external view returns (string memory) {
        require(index < _executeCalls.length, "MockXcm: index out of bounds");
        return _toHexString(_executeCalls[index].message);
    }

    /// @notice Get the raw message bytes for the n-th execute() call
    function getExecuteMsgBytes(uint256 index) external view returns (bytes memory) {
        require(index < _executeCalls.length, "MockXcm: index out of bounds");
        return _executeCalls[index].message;
    }

    // ── weighMessage (unchanged) ──────────────────────────────────────────────

    function weighMessage(bytes calldata /*message*/) external pure returns (Weight memory) {
        return Weight({ refTime: 1_000_000_000, proofSize: 65536 });
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    function _toHexString(bytes memory data) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789ABCDEF";
        bytes memory result = new bytes(2 + data.length * 2);
        result[0] = "0";
        result[1] = "x";
        for (uint256 i = 0; i < data.length; i++) {
            result[2 + i * 2]     = hexChars[uint8(data[i]) >> 4];
            result[3 + i * 2]     = hexChars[uint8(data[i]) & 0x0f];
        }
        return string(result);
    }
}
