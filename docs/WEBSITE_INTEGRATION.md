# Website Integration

The website should use the same deployed `NFTPVPVaultV1` instance that Flap creates through the custom Factory.

## Inputs

Load contract addresses from the deployment record or Flap launch output:

- `NFTPVPVaultV1`
- `PvpEntryNFT`, or read it from `vault.entryNft()`
- `TaxToken`, or read it from `vault.token()`

## Wallet Flow

1. Connect the user's wallet on the target BSC network.
2. Read Vault state through `getStats()`, `getMyInfo(address)`, `pendingNftDividends(address)`, and `pendingLossDividends(address)`.
3. For `mintNFT(tokenAmount)`, call `TaxToken.approve(vault, tokenAmount)` first.
4. For `enterQueue(tierId, nftId, betAmount)`, call `TaxToken.approve(vault, betAmount)` first.
5. Call `leaveQueue(tierId, nftId)`, `claimNftDividends()`, and `claimLossDividends()` directly.

The NFT itself does not need ERC721 approval for queue entry. `PvpEntryNFT` only allows the Vault to call `lockByVault`, `unlockByVault`, and `burnByVault`, and locked NFTs cannot be transferred.

## Fee-On-Transfer Token Note

Flap Tax Token taxable transactions are bonding curve buys, DEX buys, and DEX sells. Ordinary transfers used by `mintNFT`, `enterQueue`, and settlement should not trigger Flap transaction tax.

The Vault still uses before/after balance checks for compatibility with third-party fee-on-transfer tokens. If a third-party token taxes ordinary transfers, `enterQueue` can revert because `actualReceived` is lower than `betAmount`. In that case, the Vault must be configured as transfer-tax exempt before users enter queues.

## Flap UI Compatibility

Flap should render the Vault actions from `vaultUISchema()`:

- `mintNFT(uint256 tokenAmount)` uses ERC20 approval for `tokenAmount`.
- `enterQueue(uint256 tierId, uint256 nftId, uint256 betAmount)` uses ERC20 approval for `betAmount`.
- NFT locking is handled by the Vault/NFT contracts and does not require ERC721 approval.
