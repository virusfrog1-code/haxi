# Mainnet And Flap Launch Checklist

## Current BSC Testnet State

The current BSC Testnet deployment used mock infrastructure for end-to-end validation:

- `TaxToken` is a test `MockERC20`.
- `MockVRFCoordinator` is a local test coordinator replacement.
- `NFTPVPVaultV1`, `PvpEntryNFT`, and `NFTPVPVaultFactory` were deployed on chain `97`.
- The deployed test flow covered minting, queue entry/exit, matching, mock VRF settlement, NFT burn, LossVault quota, BNB receipt split, and dividend claims.

These mock contracts are not mainnet components and must not be reused for production.

## Mainnet Blocker

**Do not deploy or enable this system on BSC mainnet until the pricing TODO is resolved.**

`getTokenPriceBnb` currently uses a Pancake-compatible router spot quote. That is acceptable for testnet validation, but it is not safe for mainnet LossVault quota accounting. Before launch, replace it with one of:

- TWAP pricing.
- Fixed valuation controlled by audited governance.
- Another manipulation-resistant oracle or quote mechanism.

Until this is complete, `scripts/preflight-bsc-mainnet.js` and `scripts/deploy-bsc-mainnet-factory.js` intentionally block mainnet deployment unless `MAINNET_ORACLE_CONFIRMED=true` is set.

## Real Mainnet Inputs

Production launch requires real BSC mainnet infrastructure:

- A real Flap Tax Token created through the Flap flow.
- Real PancakeSwap router and WBNB addresses.
- A real Chainlink VRF coordinator, key hash, and funded subscription.
- An audited `NFTPVPVaultFactory` deployment.
- Flap `vaultData` generated from the reviewed Vault creation code.

The testnet `MockERC20` and `MockVRFCoordinator` must not be used on mainnet.

## Flap Flow

1. Resolve the mainnet pricing TODO and pass mainnet preflight.
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
- Use ERC20 approvals only for `mintNFT(tokenAmount)` and `enterQueue(tierId,nftId,betAmount)`.
- Do not ask users for ERC721 approval. The Vault locks and burns NFTs through `lockByVault` and `burnByVault`.
- Show Flap and website users the same on-chain state because both frontends call the same Vault.

See `docs/WEBSITE_INTEGRATION.md` for frontend call details.
