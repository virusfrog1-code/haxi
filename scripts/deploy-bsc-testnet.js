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

function requireAddress(name) {
  const value = requireEnv(name);
  if (!hre.ethers.isAddress(value)) {
    throw new Error(`${name} must be a valid address`);
  }
  return value;
}

async function main() {
  const network = await hre.ethers.provider.getNetwork();
  if (network.chainId !== 97n) {
    throw new Error("BSC Testnet deployment is restricted to chainId 97");
  }

  requireEnv("BSC_TESTNET_RPC_URL");
  requireEnv("DEPLOYER_PRIVATE_KEY");
  requireEnv("BSCSCAN_API_KEY");

  const taxToken = requireAddress("TAX_TOKEN");
  const pancakeRouter = requireAddress("PANCAKE_ROUTER");
  const wbnb = requireAddress("WBNB");
  const tokenPriceBnbPerToken = BigInt(process.env.TOKEN_PRICE_BNB_PER_TOKEN || "10000000000000");
  const guardian = process.env.GUARDIAN && process.env.GUARDIAN.trim() !== "" ? requireAddress("GUARDIAN") : hre.ethers.ZeroAddress;
  const vrfCoordinator = requireAddress("VRF_COORDINATOR");
  const vrfSubId = BigInt(requireEnv("VRF_SUB_ID"));
  const vrfKeyHash = requireEnv("VRF_KEY_HASH");
  const vrfCallbackGasLimit = Number(requireEnv("VRF_CALLBACK_GAS_LIMIT"));
  const vrfRequestConfirmations = Number(requireEnv("VRF_REQUEST_CONFIRMATIONS"));

  const [deployer] = await hre.ethers.getSigners();
  const router = await hre.ethers.getContractAt(
    ["function WETH() external view returns (address)"],
    pancakeRouter
  );
  const routerWbnb = await router.WETH();
  if (routerWbnb.toLowerCase() !== wbnb.toLowerCase()) {
    throw new Error("PANCAKE_ROUTER WETH() does not match WBNB");
  }

  const Vault = await hre.ethers.getContractFactory("NFTPVPVaultV1");
  const SchemaHelper = await hre.ethers.getContractFactory("NFTPVPVaultV1SchemaHelper");
  const Factory = await hre.ethers.getContractFactory("NFTPVPVaultFactory");
  const vaultCreationCodeHash = hre.ethers.keccak256(Vault.bytecode);
  const schemaHelper = await SchemaHelper.deploy();
  await schemaHelper.waitForDeployment();

  const vault = await Vault.deploy(
    taxToken,
    pancakeRouter,
    deployer.address,
    guardian,
    tokenPriceBnbPerToken,
    vrfCoordinator,
    vrfSubId,
    vrfKeyHash,
    vrfCallbackGasLimit,
    vrfRequestConfirmations,
    await schemaHelper.getAddress()
  );
  await vault.waitForDeployment();
  const vaultAddress = await vault.getAddress();

  const factory = await Factory.deploy(
    deployer.address,
    pancakeRouter,
    guardian,
    tokenPriceBnbPerToken,
    vrfCoordinator,
    vrfSubId,
    vrfKeyHash,
    vrfCallbackGasLimit,
    vrfRequestConfirmations,
    vaultCreationCodeHash
  );
  await factory.waitForDeployment();
  const factoryAddress = await factory.getAddress();

  const vaultStats = await vault.getStats();
  const nftAddress = vaultStats.nftAddress;
  const nft = await hre.ethers.getContractAt("PvpEntryNFT", nftAddress);

  const checks = {
    nftVault: await nft.vault(),
    vaultToken: vaultStats.tokenAddress,
    vaultNft: vaultStats.nftAddress,
    vaultRouter: pancakeRouter,
    vaultOwner: await vault.owner(),
    vaultGuardian: guardian,
    vaultTokenPriceBnbPerToken: tokenPriceBnbPerToken,
    vaultVrfCoordinator: vrfCoordinator
  };

  if (checks.nftVault.toLowerCase() !== vaultAddress.toLowerCase()) {
    throw new Error("Deployment check failed: NFT vault mismatch");
  }
  if (checks.vaultToken.toLowerCase() !== taxToken.toLowerCase()) {
    throw new Error("Deployment check failed: Vault token mismatch");
  }
  if (checks.vaultNft.toLowerCase() !== nftAddress.toLowerCase()) {
    throw new Error("Deployment check failed: Vault NFT mismatch");
  }
  if (checks.vaultRouter.toLowerCase() !== pancakeRouter.toLowerCase()) {
    throw new Error("Deployment check failed: Vault router mismatch");
  }
  if (checks.vaultOwner.toLowerCase() !== deployer.address.toLowerCase()) {
    throw new Error("Deployment check failed: Vault owner mismatch");
  }
  if (checks.vaultGuardian.toLowerCase() !== guardian.toLowerCase()) {
    throw new Error("Deployment check failed: Vault guardian mismatch");
  }
  if (checks.vaultTokenPriceBnbPerToken !== tokenPriceBnbPerToken) {
    throw new Error("Deployment check failed: Vault token price mismatch");
  }
  if (checks.vaultVrfCoordinator.toLowerCase() !== vrfCoordinator.toLowerCase()) {
    throw new Error("Deployment check failed: Vault VRF coordinator mismatch");
  }

  const deployment = {
    network: "bscTestnet",
    chainId: Number(network.chainId),
    deployedAt: new Date().toISOString(),
    deployer: deployer.address,
    TaxToken: taxToken,
    PvpEntryNFT: nftAddress,
    NFTPVPVaultV1: vaultAddress,
    NFTPVPVaultFactory: factoryAddress,
    PancakeRouter: pancakeRouter,
    WBNB: wbnb,
    TokenPriceBnbPerToken: tokenPriceBnbPerToken.toString(),
    VRFCoordinator: vrfCoordinator,
    VRFSubId: vrfSubId.toString(),
    VRFKeyHash: vrfKeyHash,
    VRFCallbackGasLimit: vrfCallbackGasLimit,
    VRFRequestConfirmations: vrfRequestConfirmations,
    Guardian: guardian,
    vaultCreationCodeHash,
    checks
  };

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  fs.mkdirSync(deploymentsDir, { recursive: true });
  fs.writeFileSync(path.join(deploymentsDir, "bsc-testnet.json"), `${JSON.stringify(deployment, null, 2)}\n`);

  console.log("TaxToken:", taxToken);
  console.log("PvpEntryNFT:", nftAddress);
  console.log("NFTPVPVaultV1:", vaultAddress);
  console.log("NFTPVPVaultFactory:", factoryAddress);
  console.log("Deployment file: deployments/bsc-testnet.json");
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
