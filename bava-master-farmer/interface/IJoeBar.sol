// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IJoeBar {
    function enter(uint256 _amount) external;
    function leave(uint256 _share) external;
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}