const hre = require("hardhat");

function requireEnv(name) {
  const value = process.env[name];
  if (!value || value.trim() === "") {
    throw new Error(`${name} is required`);
  }
  return value.trim();
}

function requireAddress(name) {
  const value = requireEnv(name);
  if (!hre.ethers.isAddress(value)) {
    throw new Error(`${name} must be a valid address`);
  }
  return value;
}

function requireBytes32(name) {
  const value = requireEnv(name);
  if (!/^0x[0-9a-fA-F]{64}$/.test(value)) {
    throw new Error(`${name} must be a bytes32 hex string`);
  }
  return value;
}

async function main() {
  const router = requireAddress("PANCAKE_ROUTER");
  const guardian =
    process.env.GUARDIAN && process.env.GUARDIAN.trim() !== ""
      ? requireAddress("GUARDIAN")
      : hre.ethers.ZeroAddress;
  const coordinator = requireAddress("VRF_COORDINATOR");
  const keyHash = requireBytes32("VRF_KEY_HASH");
  const subId = BigInt(requireEnv("VRF_SUB_ID"));

  if (subId < 0n || subId > 18446744073709551615n) {
    throw new Error("VRF_SUB_ID must fit uint64");
  }

  const artifact = await hre.artifacts.readArtifact("NFTPVPVaultV1");
  const vaultCreationCodeHash = hre.ethers.keccak256(artifact.bytecode);
  const vaultData = hre.ethers.AbiCoder.defaultAbiCoder().encode(
    ["address", "address", "address", "bytes32", "uint64", "bytes"],
    [router, guardian, coordinator, keyHash, subId, artifact.bytecode]
  );

  console.log("vaultCreationCodeHash:", vaultCreationCodeHash);
  console.log("vaultData:", vaultData);
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
