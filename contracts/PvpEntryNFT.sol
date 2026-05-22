// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface INftPvpVaultBalanceHook {
    function onNftBalanceChange(address from, address to, uint256 rewardWeight) external;
}

contract PvpEntryNFT is ERC721, Ownable {
    uint256 public constant MAX_SUPPLY = 8_888;
    uint8 public constant LEVEL_BASE = 0;
    uint8 public constant LEVEL_ADVANCED = 1;

    address public immutable vault;
    uint256 public totalMintedEver;
    uint256 public activeSupply;
    uint256 public totalBurnedNFT;
    uint256 public totalRewardWeight;

    mapping(uint256 => bool) public locked;
    mapping(uint256 => uint8) private _nftLevel;
    mapping(uint256 => uint8) private _baseUnits;
    mapping(uint256 => uint8) private _rewardWeight;

    error NotVault();
    error MaxSupplyExceeded();
    error LockedToken();
    error InvalidMerge();
    error NotTokenOwner();

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    constructor(string memory name_, string memory symbol_, address vault_, address initialOwner)
        ERC721(name_, symbol_)
        Ownable(initialOwner)
    {
        vault = vault_;
    }

    function mintByVault(address to) external onlyVault returns (uint256 tokenId) {
        if (activeSupply >= MAX_SUPPLY) revert MaxSupplyExceeded();
        tokenId = ++totalMintedEver;
        activeSupply += 1;
        _nftLevel[tokenId] = LEVEL_BASE;
        _baseUnits[tokenId] = 1;
        _rewardWeight[tokenId] = 1;
        totalRewardWeight += 1;
        _safeMint(to, tokenId);
    }

    function mergeBaseNFTsByVault(address owner_, uint256[] calldata tokenIds) external onlyVault returns (uint256 tokenId) {
        if (tokenIds.length != 10) revert InvalidMerge();
        if (activeSupply + 1 > MAX_SUPPLY) revert MaxSupplyExceeded();

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 burnId = tokenIds[i];
            if (_ownerOf(burnId) != owner_) revert NotTokenOwner();
            if (locked[burnId] || _baseUnits[burnId] != 1 || _nftLevel[burnId] != LEVEL_BASE) revert InvalidMerge();
            for (uint256 j = 0; j < i; j++) {
                if (tokenIds[j] == burnId) revert InvalidMerge();
            }
            _burnByVault(burnId);
        }

        tokenId = ++totalMintedEver;
        activeSupply += 1;
        _nftLevel[tokenId] = LEVEL_ADVANCED;
        _baseUnits[tokenId] = 10;
        _rewardWeight[tokenId] = 12;
        totalRewardWeight += 12;
        _safeMint(owner_, tokenId);
    }

    function totalMinted() external view returns (uint256) {
        return totalMintedEver;
    }

    function totalSupply() external view returns (uint256) {
        return activeSupply;
    }

    function lockByVault(uint256 tokenId) external onlyVault {
        _requireOwned(tokenId);
        locked[tokenId] = true;
    }

    function unlockByVault(uint256 tokenId) external onlyVault {
        _requireOwned(tokenId);
        locked[tokenId] = false;
    }

    function burnByVault(uint256 tokenId) external onlyVault {
        _burnByVault(tokenId);
    }

    function _burnByVault(uint256 tokenId) private {
        _requireOwned(tokenId);
        locked[tokenId] = false;
        activeSupply -= 1;
        totalBurnedNFT += 1;
        totalRewardWeight -= _rewardWeight[tokenId];
        _burn(tokenId);
        delete _nftLevel[tokenId];
        delete _baseUnits[tokenId];
        delete _rewardWeight[tokenId];
    }

    function transferByVault(address from, address to, uint256 tokenId) external onlyVault {
        _requireOwned(tokenId);
        locked[tokenId] = false;
        _safeTransfer(from, to, tokenId, "");
    }

    function nftLevel(uint256 tokenId) external view returns (uint8) {
        _requireOwned(tokenId);
        return _nftLevel[tokenId];
    }

    function nftType(uint256 tokenId) external view returns (uint8) {
        _requireOwned(tokenId);
        return _nftLevel[tokenId];
    }

    function nftBaseUnits(uint256 tokenId) external view returns (uint256) {
        _requireOwned(tokenId);
        return _baseUnits[tokenId];
    }

    function baseUnits(uint256 tokenId) external view returns (uint256) {
        _requireOwned(tokenId);
        return _baseUnits[tokenId];
    }

    function nftRewardWeight(uint256 tokenId) external view returns (uint256) {
        _requireOwned(tokenId);
        return _rewardWeight[tokenId];
    }

    function rewardWeight(uint256 tokenId) external view returns (uint256) {
        _requireOwned(tokenId);
        return _rewardWeight[tokenId];
    }

    function isVpnEligible(uint256 tokenId) external view returns (bool) {
        _requireOwned(tokenId);
        return _nftLevel[tokenId] == LEVEL_ADVANCED;
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0) && locked[tokenId]) revert LockedToken();
        INftPvpVaultBalanceHook(vault).onNftBalanceChange(from, to, _rewardWeight[tokenId]);
        return super._update(to, tokenId, auth);
    }
}
