// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface INftPvpVaultBalanceHook {
    function onNftBalanceChange(address from, address to) external;
}

contract PvpEntryNFT is ERC721, Ownable {
    uint256 public constant MAX_SUPPLY = 8_888;

    address public immutable vault;
    uint256 public totalMintedEver;
    uint256 public activeSupply;
    uint256 public totalBurnedNFT;

    mapping(uint256 => bool) public locked;

    error NotVault();
    error MaxSupplyExceeded();
    error LockedToken();

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
        _safeMint(to, tokenId);
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
        _requireOwned(tokenId);
        locked[tokenId] = false;
        activeSupply -= 1;
        totalBurnedNFT += 1;
        _burn(tokenId);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0) && locked[tokenId]) revert LockedToken();
        INftPvpVaultBalanceHook(vault).onNftBalanceChange(from, to);
        return super._update(to, tokenId, auth);
    }
}
