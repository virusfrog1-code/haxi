const fs = require("fs");
const path = require("path");
const hre = require("hardhat");
const { runPreflight } = require("./preflight-bsc-mainnet");

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

async function main() {
  requireEnv("DEPLOYER_PRIVATE_KEY");
  const preflight = await runPreflight();

  const network = await hre.ethers.provider.getNetwork();
  if (network.chainId !== 56n) {
    throw new Error("BSC mainnet Factory deployment is restricted to chainId 56");
  }

  const guardian =
    process.env.GUARDIAN && process.env.GUARDIAN.trim() !== ""
      ? requireAddress("GUARDIAN")
      : hre.ethers.ZeroAddress;
  const [deployer] = await hre.ethers.getSigners();

  const Vault = await hre.ethers.getContractFactory("NFTPVPVaultV1");
  const Factory = await hre.ethers.getContractFactory("NFTPVPVaultFactory");
  const vaultCreationCodeHash = hre.ethers.keccak256(Vault.bytecode);

  const factory = await Factory.deploy(
    deployer.address,
    preflight.pancakeRouter,
    guardian,
    preflight.vrfCoordinator,
    preflight.vrfKeyHash,
    BigInt(preflight.vrfSubId),
    BigInt(preflight.tokenPriceBnbPerToken),
    vaultCreationCodeHash
  );
  await factory.waitForDeployment();
  const factoryAddress = await factory.getAddress();

  const deployment = {
    network: "bscMainnet",
    chainId: Number(network.chainId),
    deployedAt: new Date().toISOString(),
    deployer: deployer.address,
    NFTPVPVaultFactory: factoryAddress,
    PancakeRouter: preflight.pancakeRouter,
    WBNB: preflight.wbnb,
    VRFCoordinator: preflight.vrfCoordinator,
    VRFSubId: preflight.vrfSubId.toString(),
    VRFKeyHash: preflight.vrfKeyHash,
    TokenPriceBnbPerToken: preflight.tokenPriceBnbPerToken.toString(),
    Guardian: guardian,
    vaultCreationCodeHash,
    bytecodeSizes: {
      NFTPVPVaultV1: preflight.vaultSize,
      NFTPVPVaultFactory: preflight.factorySize
    }
  };

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  fs.mkdirSync(deploymentsDir, { recursive: true });
  fs.writeFileSync(path.join(deploymentsDir, "bsc-mainnet-factory.json"), `${JSON.stringify(deployment, null, 2)}\n`);

  console.log("NFTPVPVaultFactory:", factoryAddress);
  console.log("Deployment file: deployments/bsc-mainnet-factory.json");
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
