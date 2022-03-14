// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IRewarder {
    function onReward(uint256 pid, address user, address recipient, uint256 rewardAmount, uint256 newLpAmount) external;
    function pendingTokens(uint256 pid, address user, uint256 rewardAmount) external view returns (address[] memory, uint256[] memory);
}