// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVaultFactory} from "./IVaultFactory.sol";
import {FactoryPolicy, VaultDataSchema} from "./IVaultSchemasV1.sol";

abstract contract VaultFactoryBaseV2 is IVaultFactory {
    error UnsupportedChain(uint256 chainId);

    event VaultCreated(address indexed creator, address indexed taxToken, address indexed quoteToken, address vault);

    function vaultDataSchema() public pure virtual returns (VaultDataSchema memory schema);

    function factorySpecVersion() public pure returns (string memory) {
        return "v2.1";
    }

    function tokenCreationPolicies() public pure virtual returns (FactoryPolicy[] memory policies) {
        return new FactoryPolicy[](0);
    }

    function _getVaultPortal() internal view returns (address vaultPortal) {
        if (block.chainid == 56) return 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
        if (block.chainid == 97) return 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;
        revert UnsupportedChain(block.chainid);
    }

    function _getGuardian() internal view returns (address guardian) {
        if (block.chainid == 56) return 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
        if (block.chainid == 97) return 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
        revert UnsupportedChain(block.chainid);
    }
}
