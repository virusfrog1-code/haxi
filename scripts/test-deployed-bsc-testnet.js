const fs = require("fs");
const path = require("path");
const hre = require("hardhat");

function requireEnv(name) {
  const value = process.env[name];
  if (!value || value.trim() === "") {
    throw new Error(`${name} is required`);
  }
  return value.trim();
}

async function main() {
  requireEnv("BSC_TESTNET_RPC_URL");

  const network = await hre.ethers.provider.getNetwork();
  if (network.chainId !== 97n) {
    throw new Error(`BSC testnet deployment check must run on chainId 97, got ${network.chainId.toString()}`);
  }

  const deploymentPath = path.join(__dirname, "..", "deployments", "bsc-testnet.json");
  if (!fs.existsSync(deploymentPath)) {
    throw new Error("deployments/bsc-testnet.json not found");
  }

  const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf8"));
  const vault = await hre.ethers.getContractAt("NFTPVPVaultV1", deployment.NFTPVPVaultV1);
  const nft = await hre.ethers.getContractAt("PvpEntryNFT", deployment.PvpEntryNFT);

  const checks = {
    nftVault: await nft.vault(),
    vaultToken: await vault.token(),
    vaultNft: await vault.entryNft(),
    vaultRouter: await vault.router(),
    vaultOwner: await vault.owner(),
    vaultGuardian: await vault.guardianOverride()
  };

  if (checks.nftVault.toLowerCase() !== deployment.NFTPVPVaultV1.toLowerCase()) {
    throw new Error("NFT vault mismatch");
  }
  if (checks.vaultToken.toLowerCase() !== deployment.TaxToken.toLowerCase()) {
    throw new Error("Vault token mismatch");
  }
  if (checks.vaultNft.toLowerCase() !== deployment.PvpEntryNFT.toLowerCase()) {
    throw new Error("Vault NFT mismatch");
  }
  if (checks.vaultRouter.toLowerCase() !== deployment.PancakeRouter.toLowerCase()) {
    throw new Error("Vault router mismatch");
  }
  if (checks.vaultOwner.toLowerCase() !== deployment.deployer.toLowerCase()) {
    throw new Error("Vault owner mismatch");
  }
  if (checks.vaultGuardian.toLowerCase() !== deployment.Guardian.toLowerCase()) {
    throw new Error("Vault guardian mismatch");
  }

  console.log("BSC testnet deployment checks passed");
  console.log("NFTPVPVaultV1:", deployment.NFTPVPVaultV1);
  console.log("PvpEntryNFT:", deployment.PvpEntryNFT);
  console.log("NFTPVPVaultFactory:", deployment.NFTPVPVaultFactory);
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
