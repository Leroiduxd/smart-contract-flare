// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ITeeExtensionRegistry {
    struct TeeInstructionParams {
        bytes32 opType;
        bytes32 opCommand;
        bytes message;
        address[] cosigners;
        uint256 cosignersThreshold;
        address claimBackAddress;
    }

    function sendInstructions(
        address[] calldata teeIds,
        TeeInstructionParams calldata params
    ) external payable;

    function getTeeExtensionInstructionsSender(uint256 extensionId) external view returns (address);
    function nextPublicExtensionId() external view returns (uint256);
}
