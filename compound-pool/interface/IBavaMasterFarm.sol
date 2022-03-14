// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IBAVAMasterFarm {
    function updatePool(uint256 _pid) external;

    function poolInfo(uint256 _pid) external view returns (
        address lpToken,
        address poolContract,
        uint256 allocPoint,
        uint256 lastRewardBlock,
        uint256 accBavaPerShare
    );

    function getPoolReward(uint256 _from, uint256 _to, uint256 _allocPoint) external view returns (
        uint256 forDev, 
        uint256 forFarmer, 
        uint256 forFT, 
        uint256 forAdr, 
        uint256 forFounders
    );
}