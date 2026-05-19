# NFTPVPVaultV1

Solidity 0.8.20 Hardhat project for `NFTPVPVaultV1`, `PvpEntryNFT`, and a Flap-compatible `NFTPVPVaultFactory`.

## Testnet-Only Status

**BSC Testnet only. Do not deploy this code to mainnet as-is.** The deployment script is restricted to BSC Testnet (`chainId 97`), and `getTokenPriceBnb` still uses a router spot quote that is not safe for mainnet quota accounting.

## Transfer-Tax Token Assumption

Flap Tax Token taxable transactions are bonding curve buys, DEX buys, and DEX sells. Ordinary ERC20 transfers are normally not taxed, so `mintNFT`, `enterQueue`, and `settleMatch` should not create Flap transaction tax.

`mintNFT` measures the actual token amount received by the Vault and mints based on `actualReceived / 100000 tokens`. `actualReceived` must be an exact multiple of the mint price.

The before/after balance accounting remains in place to support third-party fee-on-transfer tokens. `enterQueue` also measures actual received tokens and requires `actualReceived == betAmount`. If a third-party token charges tax on ordinary transfers, the Vault must be configured as a tax-exempt address before users enter queues. Otherwise `enterQueue` will revert because the Vault is underfunded and settlement would be unsafe.

Transfers to `DEAD` are treated as tokens sent to a burn/lock address. If the token taxes transfers to `DEAD`, `totalBurnedToken` tracks only the amount that actually arrives at the `DEAD` address.

For new Flap launches, use `TOKEN_TAXED_V3` and attach this custom Vault through `newTokenV6WithVault`.

This project does not use Flap's built-in holder dividend contract. The mechanism needs NFT holder dividends and LossVault dividends, so reward accounting lives in `NFTPVPVaultV1`.

## NFT Supply

The 8888 NFT cap is an active supply cap. `totalMintedEver` can exceed 8888 over time after burned loser NFTs reduce `activeSupply`; `activeSupply` must never exceed 8888.

## Buffer Conversion

`receive()` is the Flap tax BNB entry point. External BNB received by the Vault is split 50% to the NFT dividend path and 50% to the LossVault path.

Router BNB returned during `convertMintBuffers` is guarded by the Vault's internal converting flag and does not trigger the normal `receive()` 50/50 tax split. NFT mint buffer proceeds go 100% to the NFT dividend pool. Loss mint and PVP loss buffer proceeds go 100% to the LossVault path, or remain pending/reserved if there are no active loss points.

BNB received when no NFTs or no loss points exist is kept in `nftUndistributedBnb` or `lossUndistributedBnb`. Both are included in reserved accounting and cannot be removed by `rescueExcessBNB`.

## Price Quote Warning

`getTokenPriceBnb` currently uses a Pancake-compatible router spot quote. This is acceptable for BSC Testnet validation only. Before mainnet launch, replace it with TWAP, fixed valuation, or another manipulation-resistant pricing mechanism, otherwise LossVault 150% quota can be manipulated through price impact or oracle manipulation.

## Factory

`NFTPVPVaultFactory` is provided as a separate Flap Custom Vault factory so the main Vault bytecode is not expanded further. It exposes:

- `newVault(address taxToken, address quoteToken, address creator, bytes vaultData)`
- `createVault(address taxToken, address quoteToken, address creator, bytes vaultData)`
- `vaultDataSchema()`
- `factorySpecVersion()`

The factory expects `vaultData` to include the `NFTPVPVaultV1` creation code and deploys vaults with `CREATE`. It verifies the creation code against `vaultCreationCodeHash`, so it cannot deploy arbitrary unapproved creation code. This keeps Factory runtime bytecode below the EIP-170 limit instead of embedding the Vault creation code directly into Factory runtime or storing it in Factory storage.

## Replit BSC Testnet Deployment

Set these Replit Secrets before running deployment:

- `BSC_TESTNET_RPC_URL`
- `DEPLOYER_PRIVATE_KEY`
- `BSCSCAN_API_KEY`
- `TAX_TOKEN`
- `PANCAKE_ROUTER`
- `WBNB`
- `VRF_COORDINATOR`
- `VRF_SUB_ID`
- `VRF_KEY_HASH`
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

## Commands

```bash
npx hardhat compile
npm test
```
