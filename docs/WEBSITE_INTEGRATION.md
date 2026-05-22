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
3. Mint NFTs through `mintNFTByCount(quantity)`. The website approves `quantity * 100,000 Token` first.
4. PVP: user selects a tier and one NFT ID, the website approves that tier's token amount, then calls `enterQueue(tierId, nftId, tokenAmount)`.
5. After `MatchRequested`, wait for Chainlink VRF. When `RandomnessFulfilled` appears, call or prompt `settleMatch(matchId)`.
6. If VRF does not return before timeout, show `emergencyCancelMatch(matchId)` to participants.
7. Claim BNB rewards through `claimNftDividends()` and `claimLossDividends()`.

Users do not need to generate or reveal local seeds; the current mechanism uses Chainlink VRF v2.5.

## NFT Rules

- Each NFT costs 100,000 Token to mint.
- Every effective NFT has the same BNB dividend weight.
- PVP entry locks one NFT plus the selected tier Token amount.
- The winner keeps their NFT, and the loser NFT is burned.
- Locked NFTs cannot transfer.

## Fee-On-Transfer Token Note

Flap Tax Token taxable transactions are bonding curve buys, DEX buys, and DEX sells. Ordinary transfers used by `mintNFTByCount`, `mintNFT`, `enterQueue`, and settlement should not trigger Flap transaction tax.

The Vault still uses before/after balance checks for compatibility with third-party fee-on-transfer tokens. If a third-party token taxes ordinary transfers, `enterQueue` can revert because `actualReceived` is lower than `tokenAmount`. In that case, the Vault must be configured as transfer-tax exempt before users enter queues.

## Flap UI Compatibility

Flap should render the Vault actions from `vaultUISchema()`:

- `mintNFTByCount(uint256 quantity)`
- `enterQueue(uint256 tierId, uint256 nftId, uint256 tokenAmount)` with ERC20 approval for `tokenAmount`
- `leaveQueue(uint256 tierId)`
- `settleMatch(uint256 matchId)`
- `emergencyCancelMatch(uint256 matchId)`
- `claimNftDividends()`
- `claimLossDividends()`

The NFT itself does not need ERC721 approval for queue entry. `PvpEntryNFT` only allows the Vault to lock, unlock, and burn NFTs for protocol flows.
