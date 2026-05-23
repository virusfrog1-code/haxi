# Website Integration

The website should use the same deployed `NFTPVPVaultV1` instance that Flap creates through the custom Factory. Flap is the transparent on-chain panel; the website should be the normal user entry point.

## Addresses

Load contract addresses from the deployment record or Flap launch output:

- `NFTPVPVaultV1`
- `PvpEntryNFT`, read it from `vault.getStats().nftAddress`
- `TaxToken`, read it from `vault.getStats().tokenAddress`

## Wallet Flow

1. Connect the user's wallet on the target BSC network.
2. Read Vault state through `getStats()`, `getMyInfo(address)`, `pendingNftDividends(address)`, and `pendingLossDividends(address)`.
3. Mint NFTs through `mintNFTByCount(quantity)` or fixed shortcuts. The website approves `quantity * 100,000 Token` first.
4. PVP: user selects a tier and one NFT ID, the website approves that tier's token amount, then calls `enterQueue(tierId, nftId)`.
5. The first user creates a tier Round with a 5 minute join window. Other users can join the same Round before the deadline.
6. After the deadline, call or prompt `requestRoundRandomness(roundId)`. When VRF returns, call or prompt `settleRound(roundId)`.
7. If the Round has one participant after the deadline, or if VRF does not return before timeout, show `emergencyCancelRound(roundId)` to eligible users.
8. Claim BNB rewards through `claimNftDividends()` and `claimLossDividends()`.

Users do not need to generate or reveal local seeds; the current mechanism uses Chainlink VRF v2.5.

## NFT Rules

- Each NFT costs 100,000 Token to mint.
- Every effective NFT has the same BNB dividend weight.
- PVP entry locks one NFT plus the selected tier Token amount.
- NFTs in active Rounds temporarily stop receiving NFT holder dividends.
- Each Round has one winner. The winner keeps their NFT, and all loser NFTs are burned.
- Locked NFTs cannot transfer.

## Fee-On-Transfer Token Note

Flap Tax Token taxable transactions are bonding curve buys, DEX buys, and DEX sells. Ordinary transfers used by minting, `enterQueue`, and settlement should not trigger Flap transaction tax.

The Vault still uses before/after balance checks for compatibility with third-party fee-on-transfer tokens. If a third-party token taxes ordinary transfers, `enterQueue` can revert because `actualReceived` is lower than `tokenAmount`. In that case, the Vault must be configured as transfer-tax exempt before users enter queues.

## Flap UI Compatibility

Flap should render the Vault actions from `vaultUISchema()`:

- `mint1NFT()`, `mint2NFT()`, `mint5NFT()`, `mint10NFT()`
- `mintNFTByCount(uint256 quantity)` for website-driven approvals
- `enterQueue(uint256 tierId, uint256 nftId)`
- `leaveQueue(uint256 tierId)`
- `requestRoundRandomness(uint256 roundId)`
- `settleRound(uint256 roundId)`
- `emergencyCancelRound(uint256 roundId)`
- `claimNftDividends()`
- `claimLossDividends()`

The NFT itself does not need ERC721 approval for queue entry. `PvpEntryNFT` only allows the Vault to lock, unlock, and burn NFTs for protocol flows.
