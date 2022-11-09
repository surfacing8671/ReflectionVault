// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../lib/token/ERC20/IERC20.sol";
import "./IStrategy.sol";

interface IVaultLean is IERC20 {
    function deposit(uint256) external;
    function depositAll() external;
    function withdraw(uint256) external;
    function withdrawAll() external;
    function getPricePerFullShare() external view returns (uint256);
    function balance() external view returns (uint256);
    function want() external view returns (IERC20);
}