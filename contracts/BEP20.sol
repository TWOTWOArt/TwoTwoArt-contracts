// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract BEP20 is ERC20 {
   constructor() public ERC20("BEP20", "BEP") {

        _mint(msg.sender, 2000022 * 10 ** uint(decimals()));
    }
}