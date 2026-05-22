# Website Integration

The website should use the same deployed `NFTPVPVaultV1` instance that Flap creates through the custom Factory. Flap is the transparent on-chain panel; the website should be the normal user entry point.

## Addresses

Load contract addresses from the deployment record or Flap launch output:

- `NFTPVPVaultV1`
- `PvpEntryNFT`, or read it from `vault.entryNft()`
- `TaxToken`, or read it from `vault.token()`

## Wallet Flow

1. Connect the user's wallet on the target BSC network.
2. Read Vault state through `getStats()`, `getMyInfo(address)`, `pendingNftDividends(address)`, and `pendingLossDividends(address)`.
3. Mint base NFTs through `mintNFTByCount(quantity)`. The website approves `quantity * 50,000 Token` first.
4. Merge 10 base NFTs through `mergeBaseNFTs(tokenIds)`. No ERC20 or ERC721 approval is required.
5. Token PVP: user selects a tier, the website approves that tier's token amount, then calls `enterTokenQueue(tierId, tokenAmount)`.
6. NFT PVP: user selects NFT IDs, the website checks their `nftBaseUnits`, then calls `enterNftQueue(tierId, nftIds)`.
7. After `MatchRequested`, wait for Chainlink VRF. When `RandomnessFulfilled` appears, call or prompt `settleMatch(matchId)`.
8. If VRF does not return before timeout, show `emergencyCancelMatch(matchId)` to participants.
9. Claim BNB rewards through `claimNftDividends()` and `claimLossDividends()`.

Users do not need to generate `secretSeed`, submit `seedCommitment`, or call `revealSeed`; the current mechanism uses Chainlink VRF v2.5.

## NFT Rules

- Base NFT: `nftBaseUnits=1`, `nftRewardWeight=1`, `isVpnEligible=false`.
- Advanced NFT: created by merging 10 base NFTs. It has `nftBaseUnits=10`, `nftRewardWeight=12`, and `isVpnEligible=true`.
- NFT dividend accounting uses `nftRewardWeight`.
- NFT PVP value uses `nftBaseUnits`.
- Locked NFTs cannot transfer.

## Fee-On-Transfer Token Note

Flap Tax Token taxable transactions are bonding curve buys, DEX buys, and DEX sells. Ordinary transfers used by `mintNFTByCount`, `mintNFT`, `enterTokenQueue`, and settlement should not trigger Flap transaction tax.

The Vault still uses before/after balance checks for compatibility with third-party fee-on-transfer tokens. If a third-party token taxes ordinary transfers, `enterTokenQueue` can revert because `actualReceived` is lower than `tokenAmount`. In that case, the Vault must be configured as transfer-tax exempt before users enter token queues.

## Flap UI Compatibility

Flap should render the Vault actions from `vaultUISchema()`:

- `mintNFTByCount(uint256 quantity)`
- `mergeBaseNFTs(uint256[] tokenIds)`
- `enterTokenQueue(uint256 tierId, uint256 tokenAmount)` with ERC20 approval for `tokenAmount`
- `enterNftQueue(uint256 tierId, uint256[] nftIds)`
- `leaveQueue(uint256 tierId)`
- `settleMatch(uint256 matchId)`
- `emergencyCancelMatch(uint256 matchId)`
- `claimNftDividends()`
- `claimLossDividends()`

The NFT itself does not need ERC721 approval for queue entry. `PvpEntryNFT` only allows the Vault to lock, unlock, merge, and transfer NFTs for protocol flows.
