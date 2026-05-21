const fs = require("fs");
const path = require("path");
const hre = require("hardhat");

const ORACLE_TODO_TEXT = "getTokenPriceBnb";

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

  if (!combined.includes(ORACLE_TODO_TEXT) || !combined.includes("TWAP")) {
    throw new Error("Mainnet oracle TODO is missing from README/docs");
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
  const env = {
    rpcUrl: requireEnv("BSC_MAINNET_RPC_URL"),
    pancakeRouter: requireAddress("PANCAKE_ROUTER"),
    wbnb: requireAddress("WBNB"),
    vrfCoordinator: requireAddress("VRF_COORDINATOR"),
    vrfSubId: requireEnv("VRF_SUB_ID"),
    vrfKeyHash: requireBytes32("VRF_KEY_HASH")
  };

  if (BigInt(env.vrfSubId) < 0n || BigInt(env.vrfSubId) > 18446744073709551615n) {
    throw new Error("VRF_SUB_ID must fit uint64");
  }

  const sizes = await checkBytecodeSizes();
  checkOracleTodoDocs();

  if (process.env.MAINNET_ORACLE_CONFIRMED !== "true") {
    throw new Error(
      "MAINNET_ORACLE_CONFIRMED must be true before mainnet deployment. getTokenPriceBnb still uses a router spot quote and must be replaced with TWAP, fixed valuation, or another manipulation-resistant quote."
    );
  }

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
