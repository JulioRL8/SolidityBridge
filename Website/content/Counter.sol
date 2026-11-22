// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

contract Counter {
    error TooHigh(uint256 attempted);
    event Updated(address indexed sender, string indexed label, uint256 value);

    uint256 public value;

    function set(uint256 next) external {
        if (next > 100) revert TooHigh(next);
        value = next;
        emit Updated(msg.sender, "checkpoint", next);
    }
}
