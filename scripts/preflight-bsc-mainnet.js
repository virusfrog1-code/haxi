const fs = require("fs");
const path = require("path");
const hre = require("hardhat");

const PRICE_DOC_TEXT = "fixed valuation";

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

function requireBytes32(name) {
  const value = requireEnv(name);
  if (!/^0x[0-9a-fA-F]{64}$/.test(value)) {
    throw new Error(`${name} must be a bytes32 hex string`);
  }
  return value;
}

function bytecodeSize(hex) {
  return (hex.length - 2) / 2;
}

async function checkBytecodeSizes() {
  const vaultArtifact = await hre.artifacts.readArtifact("NFTPVPVaultV1");
  const factoryArtifact = await hre.artifacts.readArtifact("NFTPVPVaultFactory");
  const vaultSize = bytecodeSize(vaultArtifact.deployedBytecode);
  const factorySize = bytecodeSize(factoryArtifact.deployedBytecode);

  if (vaultSize >= 24576) {
    throw new Error(`NFTPVPVaultV1 deployed bytecode is ${vaultSize} bytes, exceeding EIP-170 limit`);
  }

  return { vaultSize, factorySize };
}

function checkOracleTodoDocs() {
  const readme = fs.readFileSync(path.join(__dirname, "..", "README.md"), "utf8");
  const launchDocPath = path.join(__dirname, "..", "docs", "MAINNET_FLAP_LAUNCH.md");
  const launchDoc = fs.existsSync(launchDocPath) ? fs.readFileSync(launchDocPath, "utf8") : "";
  const combined = `${readme}\n${launchDoc}`;

  if (!combined.includes("getTokenPriceBnb") || !combined.toLowerCase().includes(PRICE_DOC_TEXT)) {
    throw new Error("Mainnet fixed valuation warning is missing from README/docs");
  }
}

async function checkNetworkAndRouter({ rpcUrl, pancakeRouter, wbnb }) {
  const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
  const network = await provider.getNetwork();
  if (network.chainId !== 56n) {
    throw new Error(`BSC mainnet preflight must run on chainId 56, got ${network.chainId.toString()}`);
  }

  const router = new hre.ethers.Contract(pancakeRouter, ["function WETH() external view returns (address)"], provider);
  const routerWbnb = await router.WETH();
  if (routerWbnb.toLowerCase() !== wbnb.toLowerCase()) {
    throw new Error("PANCAKE_ROUTER WETH() does not match WBNB");
  }
}

async function runPreflight() {
  requireEnvs(["BSC_MAINNET_RPC_URL", "PANCAKE_ROUTER", "WBNB", "TOKEN_PRICE_BNB_PER_TOKEN"]);
  const env = {
    rpcUrl: requireEnv("BSC_MAINNET_RPC_URL"),
    pancakeRouter: requireAddress("PANCAKE_ROUTER"),
    wbnb: requireAddress("WBNB"),
    tokenPriceBnbPerToken: requireEnv("TOKEN_PRICE_BNB_PER_TOKEN")
  };

  if (BigInt(env.tokenPriceBnbPerToken) <= 0n) {
    throw new Error("TOKEN_PRICE_BNB_PER_TOKEN must be greater than zero");
  }

  const sizes = await checkBytecodeSizes();
  checkOracleTodoDocs();

  await checkNetworkAndRouter(env);

  console.log("BSC mainnet preflight passed");
  console.log("NFTPVPVaultV1 bytecode size:", sizes.vaultSize);
  console.log("NFTPVPVaultFactory bytecode size:", sizes.factorySize);

  return { ...env, ...sizes };
}

if (require.main === module) {
  runPreflight().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}

module.exports = { runPreflight };
