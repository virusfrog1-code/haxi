# Mainnet And Flap Launch Checklist

## Current BSC Testnet State

The current BSC Testnet deployment used mock infrastructure for end-to-end validation:

- `TaxToken` is a test `MockERC20`.
- Match settlement now uses hash commit-reveal instead of VRF.
- `NFTPVPVaultV1`, `PvpEntryNFT`, and `NFTPVPVaultFactory` were deployed on chain `97`.
- The deployed test flow covered minting, queue entry/exit, matching, settlement, NFT burn, LossVault quota, BNB receipt split, and dividend claims.

These mock contracts are not mainnet components and must not be reused for production.

## Price Model

`getTokenPriceBnb` now uses a fixed valuation configured as `tokenPriceBnbPerToken`, scaled to 18 decimals. This is the mainnet-safe alternative selected for the first Flap launch because LossVault quota no longer depends on a manipulable Pancake spot quote.

Operational requirements:

- Choose `TOKEN_PRICE_BNB_PER_TOKEN` before launch.
- Keep the value aligned with the intended token economics.
- Use owner or Flap Guardian to update it if launch economics change.

Do not reintroduce router spot quotes for quota accounting. If market-following pricing is required later, replace the fixed valuation with a reviewed TWAP or another manipulation-resistant oracle.

## Real Mainnet Inputs

Production launch requires real BSC mainnet infrastructure:

- A real Flap Tax Token created through the Flap flow.
- Real PancakeSwap router and WBNB addresses.
- A fixed `TOKEN_PRICE_BNB_PER_TOKEN` value.
- An audited `NFTPVPVaultFactory` deployment.
- Flap `vaultData` generated from the reviewed Vault creation code.

The testnet `MockERC20` must not be used on mainnet.

## Flap Flow

1. Choose and review the fixed `TOKEN_PRICE_BNB_PER_TOKEN`, then pass mainnet preflight.
2. Deploy the reviewed `NFTPVPVaultFactory` on BSC mainnet.
3. Generate `vaultData`:

```bash
npm run encode:flap-vault-data
```

4. In Flap, create the token with the recommended `TOKEN_TAXED_V3` / `newTokenV6WithVault` flow.
5. Attach the custom Vault Factory and provide the generated `vaultData`.
6. Flap creates the Vault through the Factory. The Factory verifies `vaultCreationCodeHash` before deploying `NFTPVPVaultV1`.
7. Flap UI reads `vaultUISchema()` from the deployed Vault and renders `mintNFT`, `enterQueue`, `leaveQueue`, claims, and admin actions.

## Website Flow

The website should connect directly to the same deployed `NFTPVPVaultV1` that Flap creates.

- Use the deployed Vault ABI for reads and writes.
- Read the deployed `PvpEntryNFT` address from `entryNft()`.
- Use ERC20 approvals only for `mintNFT(tokenAmount)` and `enterQueue(tierId,nftId,betAmount,seedCommitment)`.
- Build `seedCommitment` as `keccak256(abi.encodePacked(user, secretSeed))`, then call `revealSeed(matchId, secretSeed)` after matching.
- Do not ask users for ERC721 approval. The Vault locks and burns NFTs through `lockByVault` and `burnByVault`.
- Show Flap and website users the same on-chain state because both frontends call the same Vault.

See `docs/WEBSITE_INTEGRATION.md` for frontend call details.
