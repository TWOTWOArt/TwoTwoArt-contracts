// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
contract X22 is ERC20 {
   constructor() public ERC20("X22", "x22") {
       
        _mint(msg.sender, 20000000 * 10 ** uint(decimals()));
    }
}
