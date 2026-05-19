// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

abstract contract VaultBase {
    error UnsupportedChain(uint256 chainId);

    function _getPortal() internal view returns (address portal) {
        if (block.chainid == 56) return 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
        if (block.chainid == 97) return 0x5bEacaF7ABCbB3aB280e80D007FD31fcE26510e9;
        revert UnsupportedChain(block.chainid);
    }

    function _getGuardian() internal view returns (address guardian) {
        if (block.chainid == 56) return 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
        if (block.chainid == 97) return 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
        revert UnsupportedChain(block.chainid);
    }

    function description() public view virtual returns (string memory);
}
