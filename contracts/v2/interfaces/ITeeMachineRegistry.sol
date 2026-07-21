// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ITeeMachineRegistry {
    function getRandomTeeIds(uint256 extensionId, uint256 count) external view returns (address[] memory);
    function isTeeRegistered(uint256 extensionId, address teeAddress) external view returns (bool);
}
