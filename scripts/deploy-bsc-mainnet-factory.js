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
  requireEnvs([
    "DEPLOYER_PRIVATE_KEY",
    "BSC_MAINNET_RPC_URL",
    "PANCAKE_ROUTER",
    "WBNB",
    "TOKEN_PRICE_BNB_PER_TOKEN",
    "VRF_COORDINATOR",
    "VRF_SUB_ID",
    "VRF_KEY_HASH",
    "VRF_CALLBACK_GAS_LIMIT",
    "VRF_REQUEST_CONFIRMATIONS"
  ]);
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
    BigInt(preflight.tokenPriceBnbPerToken),
    preflight.vrfCoordinator,
    BigInt(preflight.vrfSubId),
    preflight.vrfKeyHash,
    Number(preflight.vrfCallbackGasLimit),
    Number(preflight.vrfRequestConfirmations),
    vaultCreationCodeHash
  );
  const txHash = factory.deploymentTransaction().hash;
  await factory.waitForDeployment();
  const factoryAddress = await factory.getAddress();

  const deployment = {
    network: "bscMainnet",
    chainId: Number(network.chainId),
    deployedAt: new Date().toISOString(),
    deployer: deployer.address,
    txHash,
    NFTPVPVaultFactory: factoryAddress,
    PancakeRouter: preflight.pancakeRouter,
    WBNB: preflight.wbnb,
    TokenPriceBnbPerToken: preflight.tokenPriceBnbPerToken.toString(),
    VRFCoordinator: preflight.vrfCoordinator,
    VRFSubId: preflight.vrfSubId.toString(),
    VRFKeyHash: preflight.vrfKeyHash,
    VRFCallbackGasLimit: preflight.vrfCallbackGasLimit.toString(),
    VRFRequestConfirmations: preflight.vrfRequestConfirmations.toString(),
    Guardian: guardian,
    vaultCreationCodeHash,
    bytecodeSizes: {
      NFTPVPVaultV1: preflight.vaultSize,
      NFTPVPVaultFactory: preflight.factorySize,
      NFTPVPVaultV1SchemaHelper: preflight.schemaHelperSize
    }
  };

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  fs.mkdirSync(deploymentsDir, { recursive: true });
  fs.writeFileSync(path.join(deploymentsDir, "bsc-mainnet-factory.json"), `${JSON.stringify(deployment, null, 2)}\n`);

  console.log("Transaction hash:", txHash);
  console.log("NFTPVPVaultFactory:", factoryAddress);
  console.log("Deployment file: deployments/bsc-mainnet-factory.json");
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
