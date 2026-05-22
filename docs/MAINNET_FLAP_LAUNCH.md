# Mainnet And Flap Launch Checklist

Do not reuse old test Vaults. Any mechanism change requires deploying a new `NFTPVPVaultFactory` and creating a new Flap token with fresh `vaultData`.

## Mechanism Snapshot

- Flap token tax target: 4%.
- Flap holder dividend: disabled (`FLAP_DIVIDEND_BPS=0`).
- Vault `receive()` splits tax BNB 50% to NFT holder rewards and 50% to LossVault.
- Base NFT mint price: 50,000 Token.
- 10 base NFTs merge into 1 advanced NFT.
- Advanced NFT: `baseUnits=10`, `rewardWeight=12`, permanent VPN eligibility.
- Token PVP: winner gets loser 70% Token, 15% burns, 15% goes to LossVault buffer.
- NFT PVP: winner gets loser NFTs; PVP never burns loser NFTs.
- Match randomness: Chainlink VRF v2.5. No `secretSeed`, `seedCommitment`, `revealSeed`, or owner-selected randomness.

## Price Model

`getTokenPriceBnb` uses a fixed valuation configured as `tokenPriceBnbPerToken`, scaled to 18 decimals. This avoids LossVault quota dependence on a manipulable Pancake spot quote.

Operational requirements:

- Choose `TOKEN_PRICE_BNB_PER_TOKEN` before launch.
- Keep the value aligned with intended token economics.
- Use owner or Flap Guardian to update it if launch economics change.

Do not reintroduce router spot quotes for quota accounting. If market-following pricing is required later, replace the fixed valuation with a reviewed TWAP or another manipulation-resistant oracle.

## Chainlink VRF Setup

Use Chainlink VRF v2.5.

Before Factory deployment and `vaultData` generation, set:

- `VRF_COORDINATOR`
- `VRF_SUB_ID`
- `VRF_KEY_HASH`
- `VRF_CALLBACK_GAS_LIMIT`
- `VRF_REQUEST_CONFIRMATIONS`

After the Vault is created by Flap, add the deployed `NFTPVPVaultV1` address as a consumer in the Chainlink VRF subscription. Until the Vault is added as a consumer and the subscription is funded, matched PVP games cannot receive VRF callbacks.

## Flap Flow

1. Set mainnet public parameters and VRF values.
2. Run:

```bash
npm run preflight:mainnet
npm run encode:flap-vault-data
```

3. Deploy the reviewed `NFTPVPVaultFactory` on BSC mainnet only after explicit approval.
4. Generate a fresh salt for the new token if vanity suffix is required.
5. Create the token with Flap `TOKEN_TAXED_V3` / `newTokenV6WithVault`.
6. Set buy and sell tax to 4%.
7. Disable Flap holder dividend.
8. Attach the custom Vault Factory and provide the generated `vaultData`.
9. After creation, add the Vault address to the Chainlink VRF subscription consumers.
10. Confirm Flap renders `vaultUISchema()` actions.

## Website Flow

The website should connect directly to the same deployed `NFTPVPVaultV1` that Flap creates.

- Mint through `mintNFTByCount`.
- Merge through `mergeBaseNFTs`.
- Token PVP through `enterTokenQueue`.
- NFT PVP through `enterNftQueue`.
- Wait for VRF fulfillment, then call or prompt `settleMatch`.
- Offer `emergencyCancelMatch` only after VRF timeout.

See `docs/WEBSITE_INTEGRATION.md` for frontend call details.
