// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultFactoryBaseV2} from "./flap/VaultFactoryBaseV2.sol";
import {FieldDescriptor, VaultDataSchema} from "./flap/IVaultSchemasV1.sol";
import {NFTPVPVaultV1SchemaHelper} from "./NFTPVPVaultV1SchemaHelper.sol";

contract NFTPVPVaultFactory is VaultFactoryBaseV2 {
    address public owner;
    address public router;
    address public guardianOverride;
    uint256 public tokenPriceBnbPerToken;
    address public vrfCoordinator;
    uint256 public vrfSubId;
    bytes32 public vrfKeyHash;
    uint32 public vrfCallbackGasLimit;
    uint16 public vrfRequestConfirmations;
    address public immutable schemaHelper;
    bytes32 public immutable vaultCreationCodeHash;

    event FactoryConfigUpdated(
        address indexed router,
        address indexed guardianOverride,
        uint256 tokenPriceBnbPerToken,
        address indexed vrfCoordinator,
        uint256 vrfSubId,
        bytes32 vrfKeyHash,
        uint32 vrfCallbackGasLimit,
        uint16 vrfRequestConfirmations
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
        uint256 tokenPriceBnbPerToken_,
        address vrfCoordinator_,
        uint256 vrfSubId_,
        bytes32 vrfKeyHash_,
        uint32 vrfCallbackGasLimit_,
        uint16 vrfRequestConfirmations_,
        bytes32 vaultCreationCodeHash_
    ) {
        if (owner_ == address(0) || router_ == address(0)) revert ZeroAddress();
        if (vaultCreationCodeHash_ == bytes32(0)) revert InvalidCreationCode();
        owner = owner_;
        schemaHelper = address(new NFTPVPVaultV1SchemaHelper());
        vaultCreationCodeHash = vaultCreationCodeHash_;
        _setConfig(router_, guardianOverride_, tokenPriceBnbPerToken_, vrfCoordinator_, vrfSubId_, vrfKeyHash_, vrfCallbackGasLimit_, vrfRequestConfirmations_);
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
        uint256 tokenPriceBnbPerToken_,
        address vrfCoordinator_,
        uint256 vrfSubId_,
        bytes32 vrfKeyHash_,
        uint32 vrfCallbackGasLimit_,
        uint16 vrfRequestConfirmations_
    ) external onlyOwnerOrGuardian {
        _setConfig(router_, guardianOverride_, tokenPriceBnbPerToken_, vrfCoordinator_, vrfSubId_, vrfKeyHash_, vrfCallbackGasLimit_, vrfRequestConfirmations_);
    }

    function transferFactoryOwner(address newOwner) external onlyOwnerOrGuardian {
        if (newOwner == address(0)) revert ZeroAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit FactoryOwnerUpdated(oldOwner, newOwner);
    }

    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description =
            unicode"创建 NFT PVP 分红金库。vaultData 使用 abi.encode(address router, address guardianOverride, uint256 tokenPriceBnbPerToken, address vrfCoordinator, uint256 vrfSubId, bytes32 vrfKeyHash, uint32 vrfCallbackGasLimit, uint16 vrfRequestConfirmations, bytes vaultCreationCode)。";
        schema.fields = new FieldDescriptor[](9);
        schema.fields[0] = FieldDescriptor("router", "address", unicode"Pancake 兼容 Router，用于把 Token buffer 兑换为 BNB。", 0);
        schema.fields[1] =
            FieldDescriptor("guardianOverride", "address", unicode"可选 Guardian 地址；填 0 地址时只使用 Flap Guardian。", 0);
        schema.fields[2] = FieldDescriptor("tokenPriceBnbPerToken", "uint256", unicode"每 1 Token 的固定 BNB 估值，18 位精度。主网上线前必须使用抗操纵报价。", 18);
        schema.fields[3] = FieldDescriptor("vrfCoordinator", "address", unicode"Chainlink VRF v2.5 Coordinator 地址。", 0);
        schema.fields[4] = FieldDescriptor("vrfSubId", "uint256", unicode"Chainlink VRF Subscription ID。", 0);
        schema.fields[5] = FieldDescriptor("vrfKeyHash", "bytes32", unicode"Chainlink VRF Key Hash / Gas Lane。", 0);
        schema.fields[6] = FieldDescriptor("vrfCallbackGasLimit", "uint32", unicode"VRF callback gas limit。", 0);
        schema.fields[7] = FieldDescriptor("vrfRequestConfirmations", "uint16", unicode"VRF 请求确认数。", 0);
        schema.fields[8] = FieldDescriptor("vaultCreationCode", "bytes", unicode"NFTPVPVaultV1 creation code。Factory 会校验 creationCodeHash。", 0);
        schema.isArray = false;
    }

    function _createVault(address taxToken, address quoteToken, address creator, bytes calldata vaultData)
        private
        returns (address vault)
    {
        if (taxToken == address(0) || creator == address(0)) revert ZeroAddress();

        (
            address router_,
            address guardian_,
            uint256 price_,
            address vrfCoordinator_,
            uint256 vrfSubId_,
            bytes32 vrfKeyHash_,
            uint32 vrfCallbackGasLimit_,
            uint16 vrfRequestConfirmations_,
            bytes memory creationCode
        ) =
            _decodeVaultData(vaultData);
        bytes memory initCode =
            abi.encodePacked(
                creationCode,
                abi.encode(
                    taxToken,
                    router_,
                    creator,
                    guardian_,
                    price_,
                    vrfCoordinator_,
                    vrfSubId_,
                    vrfKeyHash_,
                    vrfCallbackGasLimit_,
                    vrfRequestConfirmations_,
                    schemaHelper
                )
            );
        assembly {
            vault := create(0, add(initCode, 0x20), mload(initCode))
        }
        if (vault == address(0)) revert VaultDeploymentFailed();
        emit VaultCreated(creator, taxToken, quoteToken, vault);
    }

    function _decodeVaultData(bytes calldata vaultData)
        private
        view
        returns (
            address router_,
            address guardian_,
            uint256 price_,
            address vrfCoordinator_,
            uint256 vrfSubId_,
            bytes32 vrfKeyHash_,
            uint32 vrfCallbackGasLimit_,
            uint16 vrfRequestConfirmations_,
            bytes memory creationCode
        )
    {
        router_ = router;
        guardian_ = guardianOverride;
        price_ = tokenPriceBnbPerToken;
        vrfCoordinator_ = vrfCoordinator;
        vrfSubId_ = vrfSubId;
        vrfKeyHash_ = vrfKeyHash;
        vrfCallbackGasLimit_ = vrfCallbackGasLimit;
        vrfRequestConfirmations_ = vrfRequestConfirmations;

        if (vaultData.length == 0) revert InvalidCreationCode();
        (router_, guardian_, price_, vrfCoordinator_, vrfSubId_, vrfKeyHash_, vrfCallbackGasLimit_, vrfRequestConfirmations_, creationCode) =
            abi.decode(vaultData, (address, address, uint256, address, uint256, bytes32, uint32, uint16, bytes));
        if (router_ == address(0) || vrfCoordinator_ == address(0)) revert ZeroAddress();
        if (price_ == 0) revert InvalidCreationCode();
        if (creationCode.length == 0) revert InvalidCreationCode();
        if (keccak256(creationCode) != vaultCreationCodeHash) revert UnapprovedCreationCode();
    }

    function _setConfig(
        address router_,
        address guardianOverride_,
        uint256 tokenPriceBnbPerToken_,
        address vrfCoordinator_,
        uint256 vrfSubId_,
        bytes32 vrfKeyHash_,
        uint32 vrfCallbackGasLimit_,
        uint16 vrfRequestConfirmations_
    ) private {
        if (router_ == address(0) || vrfCoordinator_ == address(0)) revert ZeroAddress();
        if (tokenPriceBnbPerToken_ == 0) revert InvalidCreationCode();
        router = router_;
        guardianOverride = guardianOverride_;
        tokenPriceBnbPerToken = tokenPriceBnbPerToken_;
        vrfCoordinator = vrfCoordinator_;
        vrfSubId = vrfSubId_;
        vrfKeyHash = vrfKeyHash_;
        vrfCallbackGasLimit = vrfCallbackGasLimit_;
        vrfRequestConfirmations = vrfRequestConfirmations_;
        emit FactoryConfigUpdated(
            router_,
            guardianOverride_,
            tokenPriceBnbPerToken_,
            vrfCoordinator_,
            vrfSubId_,
            vrfKeyHash_,
            vrfCallbackGasLimit_,
            vrfRequestConfirmations_
        );
    }

    function _isGuardian(address account) private view returns (bool) {
        if (block.chainid != 56 && block.chainid != 97) return false;
        return account == _getGuardian();
    }
}
