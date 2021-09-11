// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;


interface rStrategy {

    function deposit(uint256[3] calldata) external;
    function withdraw(uint256[3] calldata) external;
    function withdrawAll()  external returns(uint256[3] memory);
    
}
