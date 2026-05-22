// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultBase} from "./VaultBase.sol";
import {VaultUISchema} from "./IVaultSchemasV1.sol";

abstract contract VaultBaseV2 is VaultBase {
    function vaultUISchema() public view virtual returns (VaultUISchema memory schema);
}
