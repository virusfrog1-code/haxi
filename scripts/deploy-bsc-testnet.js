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
  const vrfCoordinator = requireAddress("VRF_COORDINATOR");
  const vrfSubId = BigInt(requireEnv("VRF_SUB_ID"));
  const vrfKeyHash = requireEnv("VRF_KEY_HASH");
  const tokenPriceBnbPerToken = BigInt(process.env.TOKEN_PRICE_BNB_PER_TOKEN || "10000000000000");
  const guardian = process.env.GUARDIAN && process.env.GUARDIAN.trim() !== "" ? requireAddress("GUARDIAN") : hre.ethers.ZeroAddress;

  if (!/^0x[0-9a-fA-F]{64}$/.test(vrfKeyHash)) {
    throw new Error("VRF_KEY_HASH must be a bytes32 hex string");
  }

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
  const Factory = await hre.ethers.getContractFactory("NFTPVPVaultFactory");
  const vaultCreationCodeHash = hre.ethers.keccak256(Vault.bytecode);

  const vault = await Vault.deploy(
    taxToken,
    pancakeRouter,
    deployer.address,
    guardian,
    vrfCoordinator,
    vrfKeyHash,
    vrfSubId,
    tokenPriceBnbPerToken
  );
  await vault.waitForDeployment();
  const vaultAddress = await vault.getAddress();

  const factory = await Factory.deploy(
    deployer.address,
    pancakeRouter,
    guardian,
    vrfCoordinator,
    vrfKeyHash,
    vrfSubId,
    tokenPriceBnbPerToken,
    vaultCreationCodeHash
  );
  await factory.waitForDeployment();
  const factoryAddress = await factory.getAddress();

  const nftAddress = await vault.entryNft();
  const nft = await hre.ethers.getContractAt("PvpEntryNFT", nftAddress);

  const checks = {
    nftVault: await nft.vault(),
    vaultToken: await vault.token(),
    vaultNft: await vault.entryNft(),
    vaultRouter: await vault.router(),
    vaultOwner: await vault.owner(),
    vaultGuardian: await vault.guardianOverride(),
    vaultTokenPriceBnbPerToken: await vault.tokenPriceBnbPerToken()
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
    VRFCoordinator: vrfCoordinator,
    VRFSubId: vrfSubId.toString(),
    VRFKeyHash: vrfKeyHash,
    TokenPriceBnbPerToken: tokenPriceBnbPerToken.toString(),
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
