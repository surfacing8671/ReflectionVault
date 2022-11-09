pragma solidity ^0.8.0;

import "../lib/token/ERC20/IERC20.sol";

interface IERC20Burnable is IERC20 {
    function burn(uint256) external;
    function burnFrom(address, uint256) external;
}