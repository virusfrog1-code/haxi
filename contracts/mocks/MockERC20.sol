// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint16 public transferFeeBps;
    address public feeRecipient;

    constructor() ERC20("Mock Token", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTransferFee(uint16 transferFeeBps_, address feeRecipient_) external {
        transferFeeBps = transferFeeBps_;
        feeRecipient = feeRecipient_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && transferFeeBps != 0) {
            uint256 fee = value * transferFeeBps / 10_000;
            uint256 remainder = value - fee;
            if (fee != 0) {
                super._update(from, feeRecipient, fee);
            }
            super._update(from, to, remainder);
            return;
        }

        super._update(from, to, value);
    }
}
