# NFTPVPVaultV1

Solidity 0.8.20 Hardhat project for `NFTPVPVaultV1`, `PvpEntryNFT`, and a Flap-compatible `NFTPVPVaultFactory`.

## Testnet-Only Status

**BSC Testnet deployment has been validated. Mainnet deployment should still be treated as a staged launch and run the preflight scripts first.** The default deployment script is restricted to BSC Testnet (`chainId 97`).

## Transfer-Tax Token Assumption

Flap Tax Token taxable transactions are bonding curve buys, DEX buys, and DEX sells. Ordinary ERC20 transfers are normally not taxed, so `mintNFTByCount`, `mintNFT`, `enterQueue`, and `settleMatch` should not create Flap transaction tax. Configure the Flap token with 4% tax, `FLAP_DIVIDEND_BPS=0`, and route tax BNB to this Vault.

`mintNFT` measures the actual token amount received by the Vault and mints based on `actualReceived / 100000 tokens`. `actualReceived` must be an exact multiple of the mint price.

The before/after balance accounting remains in place to support third-party fee-on-transfer tokens. `enterQueue` also measures actual received tokens and requires `actualReceived == tokenAmount`. If a third-party token charges tax on ordinary transfers, the Vault must be configured as a tax-exempt address before users enter queues. Otherwise `enterQueue` will revert because the Vault is underfunded and settlement would be unsafe.

Transfers to `DEAD` are treated as tokens sent to a burn/lock address. If the token taxes transfers to `DEAD`, `totalBurnedToken` tracks only the amount that actually arrives at the `DEAD` address.

For new Flap launches, use `TOKEN_TAXED_V3` and attach this custom Vault through `newTokenV6WithVault`.

This project does not use Flap's built-in holder dividend contract. The mechanism needs NFT holder dividends and LossVault dividends, so reward accounting lives in `NFTPVPVaultV1`.

## NFT Supply

The 8888 NFT cap is an active supply cap. `totalMintedEver` can exceed 8888 over time after NFTs are burned by approved Vault flows, but `activeSupply` must never exceed 8888.

Each NFT costs 100,000 Token. Every effective NFT has the same BNB dividend weight. There is no merge or NFT array staking flow in the simplified final mechanism.

## PVP And Chainlink VRF

PVP uses one simplified queue flow: `enterQueue(tierId, nftId, tokenAmount)` locks the tier Token amount plus one NFT. The winner receives their own Token/NFT back and 70% of the loser's Token stake. 15% of the loser Token stake goes to the `DEAD` address, 15% goes to `pvpLossTokenBuffer`, and the loser's NFT is burned.

Matching immediately requests Chainlink VRF v2.5 randomness. The callback records the random word, and `settleMatch(matchId)` completes settlement. If VRF does not return before `vrfTimeout`, participants or owner/Flap Guardian can call `emergencyCancelMatch(matchId)` to refund/unlock both sides with no winner and no LossVault quota.

## Buffer Conversion

`receive()` is the Flap tax BNB entry point. External BNB received by the Vault is split 50% to the NFT dividend path and 50% to the LossVault path.

Router BNB returned during `convertMintBuffers` is guarded by the Vault's internal converting flag and does not trigger the normal `receive()` 50/50 tax split. NFT mint buffer proceeds go 100% to the NFT dividend pool. Loss mint and PVP loss buffer proceeds go 100% to the LossVault path, or remain pending/reserved if there are no active loss points.

BNB received when no NFTs or no loss points exist is kept in `nftUndistributedBnb` or `lossUndistributedBnb`. Both are included in reserved accounting and cannot be removed by `rescueExcessBNB`.

## Price Quote Model

`getTokenPriceBnb` uses a fixed valuation configured as `tokenPriceBnbPerToken`, scaled to 18 decimals. This removes the router spot-quote manipulation risk for LossVault 150% quota accounting. The tradeoff is operational: owner or Flap Guardian must keep the fixed valuation aligned with the intended launch economics.

Do not use Pancake router spot quotes for quota accounting on mainnet. If the project later needs market-following prices, replace the fixed valuation with a reviewed TWAP or another manipulation-resistant oracle.

## Factory

`NFTPVPVaultFactory` is provided as a separate Flap Custom Vault factory so the main Vault bytecode is not expanded further. It exposes:

- `newVault(address taxToken, address quoteToken, address creator, bytes vaultData)`
- `createVault(address taxToken, address quoteToken, address creator, bytes vaultData)`
- `vaultDataSchema()`
- `factorySpecVersion()`

The factory expects `vaultData` to include the fixed token valuation and the `NFTPVPVaultV1` creation code, then deploys vaults with `CREATE`. It verifies the creation code against `vaultCreationCodeHash`, so it cannot deploy arbitrary unapproved creation code. This keeps Factory runtime bytecode below the EIP-170 limit instead of embedding the Vault creation code directly into Factory runtime or storing it in Factory storage.

## Replit BSC Testnet Deployment

Set these Replit Secrets before running deployment:

- `BSC_TESTNET_RPC_URL`
- `DEPLOYER_PRIVATE_KEY`
- `BSCSCAN_API_KEY`
- `TAX_TOKEN`
- `PANCAKE_ROUTER`
- `WBNB`
- `TOKEN_PRICE_BNB_PER_TOKEN` optional on testnet, defaults to `10000000000000` (`0.00001 BNB` per token)
- `VRF_COORDINATOR`
- `VRF_SUB_ID`
- `VRF_KEY_HASH`
- `VRF_CALLBACK_GAS_LIMIT`
- `VRF_REQUEST_CONFIRMATIONS`
- `GUARDIAN` optional, defaults to zero address

The deployment script never prints the private key. It deploys `NFTPVPVaultV1` and `NFTPVPVaultFactory`, checks that `PvpEntryNFT.vault()` points to the deployed Vault, checks Vault token/NFT/router/owner/guardian values, then writes `deployments/bsc-testnet.json`.

```bash
npm install
npx hardhat compile
npm test
npm run deploy:bsc-testnet
```

Expected deployment output includes only public addresses:

- `TaxToken`
- `PvpEntryNFT`
- `NFTPVPVaultV1`
- `NFTPVPVaultFactory`
- `deployments/bsc-testnet.json`

## Mainnet / Flap / Website Preparation

Mainnet deployment is not part of the default flow. The repository includes guardrail scripts and launch docs only:

- `docs/MAINNET_FLAP_LAUNCH.md`
- `docs/WEBSITE_INTEGRATION.md`
- `scripts/encode-flap-vault-data.js`
- `scripts/preflight-bsc-mainnet.js`
- `scripts/deploy-bsc-mainnet-factory.js`

Generate Flap `vaultData` after setting the public router and fixed valuation environment values:

```bash
npm run encode:flap-vault-data
```

Run mainnet preflight before any Factory deployment. It requires `TOKEN_PRICE_BNB_PER_TOKEN` and Chainlink VRF v2.5 values, and checks chain `56`, router/WBNB consistency, bytecode size, and fixed valuation docs:

```bash
npm run preflight:mainnet
```

Expected behavior: preflight passes only when all mainnet environment values and the fixed valuation are explicitly set.

## Commands

```bash
npx hardhat compile
npm test
npm run test:deployed:bsc-testnet
```
