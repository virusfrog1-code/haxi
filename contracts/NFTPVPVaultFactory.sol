// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultFactoryBaseV2} from "./flap/VaultFactoryBaseV2.sol";
import {FieldDescriptor, VaultDataSchema} from "./flap/IVaultSchemasV1.sol";

contract NFTPVPVaultFactory is VaultFactoryBaseV2 {
    address public owner;
    address public router;
    address public guardianOverride;
    address public vrfCoordinator;
    bytes32 public vrfKeyHash;
    uint64 public vrfSubId;
    bytes32 public immutable vaultCreationCodeHash;

    event FactoryConfigUpdated(
        address indexed router,
        address indexed guardianOverride,
        address indexed vrfCoordinator,
        bytes32 vrfKeyHash,
        uint64 vrfSubId
    );
    event FactoryOwnerUpdated(address indexed oldOwner, address indexed newOwner);

    error NotOwnerOrGuardian();
    error InvalidCreationCode();
    error UnapprovedCreationCode();
    error VaultDeploymentFailed();

    modifier onlyOwnerOrGuardian() {
        if (msg.sender != owner && !_isGuardian(msg.sender)) revert NotOwnerOrGuardian();
        _;
    }

    constructor(
        address owner_,
        address router_,
        address guardianOverride_,
        address vrfCoordinator_,
        bytes32 vrfKeyHash_,
        uint64 vrfSubId_,
        bytes32 vaultCreationCodeHash_
    ) {
        if (owner_ == address(0) || router_ == address(0)) revert ZeroAddress();
        if (vaultCreationCodeHash_ == bytes32(0)) revert InvalidCreationCode();
        owner = owner_;
        vaultCreationCodeHash = vaultCreationCodeHash_;
        _setConfig(router_, guardianOverride_, vrfCoordinator_, vrfKeyHash_, vrfSubId_);
    }

    function newVault(address taxToken, address quoteToken, address creator, bytes calldata vaultData)
        external
        override
        returns (address vault)
    {
        if (block.chainid == 56 || block.chainid == 97) {
            if (msg.sender != _getVaultPortal()) revert OnlyVaultPortal();
        }
        vault = _createVault(taxToken, quoteToken, creator, vaultData);
    }

    function createVault(address taxToken, address quoteToken, address creator, bytes calldata vaultData)
        external
        returns (address vault)
    {
        vault = _createVault(taxToken, quoteToken, creator, vaultData);
    }

    function isQuoteTokenSupported(address) external pure override returns (bool supported) {
        return true;
    }

    function updateFactoryConfig(
        address router_,
        address guardianOverride_,
        address vrfCoordinator_,
        bytes32 vrfKeyHash_,
        uint64 vrfSubId_
    ) external onlyOwnerOrGuardian {
        _setConfig(router_, guardianOverride_, vrfCoordinator_, vrfKeyHash_, vrfSubId_);
    }

    function transferFactoryOwner(address newOwner) external onlyOwnerOrGuardian {
        if (newOwner == address(0)) revert ZeroAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit FactoryOwnerUpdated(oldOwner, newOwner);
    }

    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description =
            "Creates an NFTPVPVaultV1. vaultData is abi.encode(address router, address guardianOverride, address vrfCoordinator, bytes32 vrfKeyHash, uint64 vrfSubId, bytes vaultCreationCode).";
        schema.fields = new FieldDescriptor[](6);
        schema.fields[0] = FieldDescriptor("router", "address", "Pancake-compatible router used for token-to-BNB swaps.", 0);
        schema.fields[1] =
            FieldDescriptor("guardianOverride", "address", "Optional testnet/project guardian; zero uses Flap Guardian only.", 0);
        schema.fields[2] = FieldDescriptor("vrfCoordinator", "address", "VRF coordinator; zero disables automatic VRF requests.", 0);
        schema.fields[3] = FieldDescriptor("vrfKeyHash", "bytes32", "VRF key hash.", 0);
        schema.fields[4] = FieldDescriptor("vrfSubId", "uint256", "VRF subscription id, encoded as uint64.", 0);
        schema.fields[5] = FieldDescriptor("vaultCreationCode", "bytes", "NFTPVPVaultV1 creation code.", 0);
        schema.isArray = false;
    }

    function _createVault(address taxToken, address quoteToken, address creator, bytes calldata vaultData)
        private
        returns (address vault)
    {
        if (taxToken == address(0) || creator == address(0)) revert ZeroAddress();

        (address router_, address guardian_, address coordinator_, bytes32 keyHash_, uint64 subId_, bytes memory creationCode) =
            _decodeVaultData(vaultData);
        bytes memory initCode =
            abi.encodePacked(creationCode, abi.encode(taxToken, router_, creator, guardian_, coordinator_, keyHash_, subId_));
        assembly {
            vault := create(0, add(initCode, 0x20), mload(initCode))
        }
        if (vault == address(0)) revert VaultDeploymentFailed();
        emit VaultCreated(creator, taxToken, quoteToken, vault);
    }

    function _decodeVaultData(bytes calldata vaultData)
        private
        view
        returns (address router_, address guardian_, address coordinator_, bytes32 keyHash_, uint64 subId_, bytes memory creationCode)
    {
        router_ = router;
        guardian_ = guardianOverride;
        coordinator_ = vrfCoordinator;
        keyHash_ = vrfKeyHash;
        subId_ = vrfSubId;

        if (vaultData.length == 0) revert InvalidCreationCode();
        (router_, guardian_, coordinator_, keyHash_, subId_, creationCode) =
            abi.decode(vaultData, (address, address, address, bytes32, uint64, bytes));
        if (router_ == address(0)) revert ZeroAddress();
        if (creationCode.length == 0) revert InvalidCreationCode();
        if (keccak256(creationCode) != vaultCreationCodeHash) revert UnapprovedCreationCode();
    }

    function _setConfig(
        address router_,
        address guardianOverride_,
        address vrfCoordinator_,
        bytes32 vrfKeyHash_,
        uint64 vrfSubId_
    ) private {
        if (router_ == address(0)) revert ZeroAddress();
        router = router_;
        guardianOverride = guardianOverride_;
        vrfCoordinator = vrfCoordinator_;
        vrfKeyHash = vrfKeyHash_;
        vrfSubId = vrfSubId_;
        emit FactoryConfigUpdated(router_, guardianOverride_, vrfCoordinator_, vrfKeyHash_, vrfSubId_);
    }

    function _isGuardian(address account) private view returns (bool) {
        if (block.chainid != 56 && block.chainid != 97) return false;
        return account == _getGuardian();
    }
}
