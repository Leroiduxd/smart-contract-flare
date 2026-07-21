// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ITeeMachineRegistry {
    function getRandomTeeIds(uint256 extensionId, uint256 count) external view returns (address[] memory);
}
