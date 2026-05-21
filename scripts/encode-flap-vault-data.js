const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

function requireEnv(name) {
  const value = process.env[name];
  if (!value || value.trim() === "") {
    throw new Error(`${name} is required`);
  }
  return value.trim();
}

function requireEnvs(names) {
  const missing = names.filter((name) => !process.env[name] || process.env[name].trim() === "");
  if (missing.length > 0) {
    throw new Error(`Missing required env: ${missing.join(", ")}`);
  }
}

function requireAddress(name) {
  const value = requireEnv(name);
  if (hre.ethers.isAddress(value)) {
    return hre.ethers.getAddress(value);
  }
  if (/^0x[0-9a-fA-F]{40}$/.test(value)) {
    return hre.ethers.getAddress(value.toLowerCase());
  }
  if (!hre.ethers.isAddress(value)) {
    throw new Error(`${name} must be a valid address`);
  }
  return hre.ethers.getAddress(value);
}

async function main() {
  requireEnvs(["PANCAKE_ROUTER", "TOKEN_PRICE_BNB_PER_TOKEN"]);
  const router = requireAddress("PANCAKE_ROUTER");
  const guardian =
    process.env.GUARDIAN && process.env.GUARDIAN.trim() !== ""
      ? requireAddress("GUARDIAN")
      : hre.ethers.ZeroAddress;
  const tokenPriceBnbPerToken = BigInt(requireEnv("TOKEN_PRICE_BNB_PER_TOKEN"));

  if (tokenPriceBnbPerToken <= 0n) {
    throw new Error("TOKEN_PRICE_BNB_PER_TOKEN must be greater than zero");
  }

  const artifact = await hre.artifacts.readArtifact("NFTPVPVaultV1");
  const vaultCreationCodeHash = hre.ethers.keccak256(artifact.bytecode);
  const vaultData = hre.ethers.AbiCoder.defaultAbiCoder().encode(
    ["address", "address", "uint256", "bytes"],
    [router, guardian, tokenPriceBnbPerToken, artifact.bytecode]
  );

  console.log("vaultCreationCodeHash:", vaultCreationCodeHash);
  console.log("vaultData:", vaultData);

  const outDir = path.join(__dirname, "..", "deployments");
  fs.mkdirSync(outDir, { recursive: true });
  const outPath = path.join(outDir, "flap-vault-data-mainnet.txt");
  fs.writeFileSync(outPath, `vaultCreationCodeHash: ${vaultCreationCodeHash}\nvaultData: ${vaultData}\n`);
  console.log("wrote:", outPath);
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
