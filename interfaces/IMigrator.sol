// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IMigrator {
    function migrate(uint) external; // migrate from (minrecieved)
}