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

function optionalEnv(name, fallback) {
  const value = process.env[name];
  return value && value.trim() !== "" ? value.trim() : fallback;
}

function requireAddress(name) {
  const value = requireEnv(name);
  if (!hre.ethers.isAddress(value)) {
    throw new Error(`${name} must be a valid address`);
  }
  return hre.ethers.getAddress(value);
}

function parseUint(name, fallback) {
  const value = fallback === undefined ? requireEnv(name) : optionalEnv(name, String(fallback));
  if (!/^\d+$/.test(value)) {
    throw new Error(`${name} must be an unsigned integer`);
  }
  return BigInt(value);
}

function parseUint16(name, fallback) {
  const value = parseUint(name, fallback);
  if (value > 65535n) {
    throw new Error(`${name} must fit uint16`);
  }
  return Number(value);
}

function parseUint64(name, fallback) {
  const value = parseUint(name, fallback);
  if (value > 18446744073709551615n) {
    throw new Error(`${name} must fit uint64`);
  }
  return value;
}

function readVaultData() {
  if (process.env.FLAP_VAULT_DATA && process.env.FLAP_VAULT_DATA.trim() !== "") {
    return process.env.FLAP_VAULT_DATA.trim();
  }
  const file = optionalEnv(
    "FLAP_VAULT_DATA_FILE",
    path.join(__dirname, "..", "deployments", "flap-vault-data-mainnet.txt")
  );
  const raw = fs.readFileSync(file, "utf8").trim();
  const labeled = raw.match(/vaultData:\s*(0x[0-9a-fA-F]+)/);
  const allHex = raw.match(/0x[0-9a-fA-F]+/g);
  const match = labeled ? [labeled[1]] : allHex && allHex.length > 0 ? [allHex[allHex.length - 1]] : null;
  if (!match) {
    throw new Error(`${file} does not contain hex vaultData`);
  }
  return match[0];
}

function readMeta() {
  if (process.env.FLAP_TOKEN_META && process.env.FLAP_TOKEN_META.trim() !== "") {
    return process.env.FLAP_TOKEN_META.trim();
  }
  const placeholder = "ipfs://REPLACE_WITH_TOKEN_METADATA_CID";
  if (process.env.CONFIRM_CREATE_FLAP_TOKEN === "YES") {
    throw new Error("FLAP_TOKEN_META is required for real token creation; placeholder metadata is dry-run only");
  }
  return placeholder;
}

async function main() {
  const network = await hre.ethers.provider.getNetwork();
  if (network.chainId !== 56n) {
    throw new Error(`Wrong chainId ${network.chainId}; expected BSC mainnet chainId 56`);
  }

  const confirmed = process.env.CONFIRM_CREATE_FLAP_TOKEN === "YES";
  const [deployer] = confirmed ? await hre.ethers.getSigners() : [];
  const vaultPortal = requireAddress("FLAP_VAULT_PORTAL");
  const vaultFactory = requireAddress("FLAP_VAULT_FACTORY");
  const quoteToken = optionalEnv("FLAP_QUOTE_TOKEN", hre.ethers.ZeroAddress);
  if (!hre.ethers.isAddress(quoteToken)) {
    throw new Error("FLAP_QUOTE_TOKEN must be a valid address");
  }
  const dividendToken = optionalEnv("FLAP_DIVIDEND_TOKEN", hre.ethers.ZeroAddress);
  if (!hre.ethers.isAddress(dividendToken)) {
    throw new Error("FLAP_DIVIDEND_TOKEN must be a valid address");
  }
  const commissionReceiver = optionalEnv("FLAP_COMMISSION_RECEIVER", hre.ethers.ZeroAddress);
  if (!hre.ethers.isAddress(commissionReceiver)) {
    throw new Error("FLAP_COMMISSION_RECEIVER must be a valid address");
  }

  const name = requireEnv("FLAP_TOKEN_NAME");
  const symbol = requireEnv("FLAP_TOKEN_SYMBOL");
  const meta = readMeta();
  const salt = requireEnv("FLAP_TOKEN_SALT");
  if (!/^0x[0-9a-fA-F]{64}$/.test(salt)) {
    throw new Error("FLAP_TOKEN_SALT must be bytes32 hex and must produce a 7777 tax-token vanity address");
  }

  const vaultData = readVaultData();
  const quoteAmt = hre.ethers.parseEther(requireEnv("FLAP_QUOTE_AMT_BNB"));
  const value = parseUint("FLAP_MSG_VALUE_WEI", quoteAmt.toString());

  const buyTaxRate = parseUint16("FLAP_BUY_TAX_RATE_BPS", 500);
  const sellTaxRate = parseUint16("FLAP_SELL_TAX_RATE_BPS", 500);
  const taxDuration = parseUint64("FLAP_TAX_DURATION_SECONDS", 31536000);
  const antiFarmerDuration = parseUint64("FLAP_ANTI_FARMER_DURATION_SECONDS", 259200);

  const mktBps = parseUint16("FLAP_MKT_BPS", 10000);
  const deflationBps = parseUint16("FLAP_DEFLATION_BPS", 0);
  const dividendBps = parseUint16("FLAP_DIVIDEND_BPS", 0);
  const lpBps = parseUint16("FLAP_LP_BPS", 0);
  if (mktBps + deflationBps + dividendBps + lpBps !== 10000) {
    throw new Error("FLAP_MKT_BPS + FLAP_DEFLATION_BPS + FLAP_DIVIDEND_BPS + FLAP_LP_BPS must equal 10000");
  }
  if (dividendBps !== 0) {
    throw new Error("FLAP_DIVIDEND_BPS must be 0 because this project uses NFT dividends, not Flap holder dividends");
  }

  const params = {
    name,
    symbol,
    meta,
    dexThresh: Number(parseUint("FLAP_DEX_THRESH", 0)),
    salt,
    migratorType: Number(parseUint("FLAP_MIGRATOR_TYPE", 1)),
    quoteToken: hre.ethers.getAddress(quoteToken),
    quoteAmt,
    permitData: optionalEnv("FLAP_PERMIT_DATA", "0x"),
    extensionID: optionalEnv("FLAP_EXTENSION_ID", hre.ethers.ZeroHash),
    extensionData: optionalEnv("FLAP_EXTENSION_DATA", "0x"),
    dexId: Number(parseUint("FLAP_DEX_ID", 0)),
    lpFeeProfile: Number(parseUint("FLAP_LP_FEE_PROFILE", 0)),
    buyTaxRate,
    sellTaxRate,
    taxDuration,
    antiFarmerDuration,
    mktBps,
    deflationBps,
    dividendBps,
    lpBps,
    minimumShareBalance: parseUint("FLAP_MINIMUM_SHARE_BALANCE", 0),
    dividendToken: hre.ethers.getAddress(dividendToken),
    commissionReceiver: hre.ethers.getAddress(commissionReceiver),
    tokenVersion: 6,
    vaultFactory,
    vaultData,
  };

  const vaultCreationCodeHash =
    fs.existsSync(path.join(__dirname, "..", "deployments", "bsc-mainnet-factory.json"))
      ? JSON.parse(fs.readFileSync(path.join(__dirname, "..", "deployments", "bsc-mainnet-factory.json"), "utf8"))
          .vaultCreationCodeHash
      : "(deployment file missing)";

  console.log("Prepared Flap Vault token creation parameters:");
  console.log("deployer:", deployer ? deployer.address : "(not required for dry-run)");
  console.log("chainId:", network.chainId.toString());
  console.log("vaultPortal:", vaultPortal);
  console.log("vaultFactory:", vaultFactory);
  console.log("vaultCreationCodeHash:", vaultCreationCodeHash);
  console.log("token name:", name);
  console.log("token symbol:", symbol);
  console.log("meta:", meta);
  console.log("buyTaxRateBps:", buyTaxRate);
  console.log("sellTaxRateBps:", sellTaxRate);
  console.log("tax rate:", "5% buy / 5% sell");
  console.log("tax allocation bps:", { mktBps, deflationBps, dividendBps, lpBps });
  console.log("holder dividend disabled:", dividendBps === 0);
  console.log("tokenVersion:", "TOKEN_TAXED_V3 (6)");
  console.log("quoteToken:", params.quoteToken);
  console.log("quoteAmtWei:", quoteAmt.toString());
  console.log("msgValueWei:", value.toString());
  console.log("salt:", salt);
  console.log("vaultData length:", vaultData.length);
  console.log("vaultData prefix:", vaultData.slice(0, 22));
  console.log("vaultData suffix:", vaultData.slice(-20));

  if (!confirmed) {
    console.log("DRY RUN ONLY: set CONFIRM_CREATE_FLAP_TOKEN=YES only after explicit approval to send the transaction.");
    return;
  }

  if (!deployer) {
    throw new Error("A signer is required for real token creation");
  }

  const abi = [
    "function newTokenV6WithVault((string name,string symbol,string meta,uint8 dexThresh,bytes32 salt,uint8 migratorType,address quoteToken,uint256 quoteAmt,bytes permitData,bytes32 extensionID,bytes extensionData,uint8 dexId,uint8 lpFeeProfile,uint16 buyTaxRate,uint16 sellTaxRate,uint64 taxDuration,uint64 antiFarmerDuration,uint16 mktBps,uint16 deflationBps,uint16 dividendBps,uint16 lpBps,uint256 minimumShareBalance,address dividendToken,address commissionReceiver,uint8 tokenVersion,address vaultFactory,bytes vaultData) params) external payable returns (address token)",
    "event FlapTaxVaultTokenCreated(address indexed token,address indexed vault,address indexed vaultFactory)",
  ];
  const portal = new hre.ethers.Contract(vaultPortal, abi, deployer);
  const gas = await portal.newTokenV6WithVault.estimateGas(params, { value });
  console.log("estimatedGas:", gas.toString());
  const tx = await portal.newTokenV6WithVault(params, { value });
  console.log("txHash:", tx.hash);
  const receipt = await tx.wait();
  console.log("status:", receipt.status);
  for (const log of receipt.logs) {
    try {
      const parsed = portal.interface.parseLog(log);
      if (parsed && parsed.name === "FlapTaxVaultTokenCreated") {
        console.log("token:", parsed.args.token);
        console.log("vault:", parsed.args.vault);
        console.log("vaultFactory:", parsed.args.vaultFactory);
      }
    } catch (_) {}
  }
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
