const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

const BSC_PORTAL = "0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0";
const BSC_VAULT_PORTAL = "0x90497450f2a706f1951b5bdda52B4E5d16f34C06";
const TAX_TOKEN_V3_IMPL = "0x024f18294970B5c76c0691b87f138A0317156422";

function optionalAddress(name, fallback) {
  const value = process.env[name] && process.env[name].trim() !== "" ? process.env[name].trim() : fallback;
  if (!hre.ethers.isAddress(value)) {
    throw new Error(`${name} must be a valid address`);
  }
  return hre.ethers.getAddress(value);
}

function minimalProxyInitCode(implementation) {
  return `0x3d602d80600a3d3981f3${"363d3d373d3d3d363d73"}${implementation.slice(2).toLowerCase()}5af43d82803e903d91602b57fd5bf3`;
}

async function resolveCreate2Inputs() {
  const vaultPortalAddress = optionalAddress("FLAP_VAULT_PORTAL", BSC_VAULT_PORTAL);
  const fallbackPortal = optionalAddress("FLAP_TOKEN_CREATE2_DEPLOYER", BSC_PORTAL);
  const fallbackImplementation = optionalAddress("FLAP_TOKEN_IMPL_TAXED_V3", TAX_TOKEN_V3_IMPL);

  const vaultPortal = new hre.ethers.Contract(
    vaultPortalAddress,
    [
      "function PORTAL() view returns (address)",
      "function TOKEN_IMPL_TAXED_V3() view returns (address)",
      "function TAX_TOKEN_SUFFIX() view returns (uint256)",
    ],
    hre.ethers.provider
  );

  try {
    const [portal, implementation, suffixValue] = await Promise.all([
      vaultPortal.PORTAL(),
      vaultPortal.TOKEN_IMPL_TAXED_V3(),
      vaultPortal.TAX_TOKEN_SUFFIX(),
    ]);

    return {
      vaultPortal: vaultPortalAddress,
      deployer: hre.ethers.getAddress(portal),
      implementation: hre.ethers.getAddress(implementation),
      suffix: suffixValue === 0n ? "7777" : suffixValue.toString(16).padStart(4, "0"),
      source: "vaultPortal",
    };
  } catch (_) {
    return {
      vaultPortal: vaultPortalAddress,
      deployer: fallbackPortal,
      implementation: fallbackImplementation,
      suffix: "7777",
      source: "fallback",
    };
  }
}

async function main() {
  const inputs = await resolveCreate2Inputs();
  const deployer = inputs.deployer;
  const implementation = inputs.implementation;
  const suffix = (process.env.FLAP_TOKEN_ADDRESS_SUFFIX || inputs.suffix).toLowerCase();
  if (!/^[0-9a-f]+$/.test(suffix) || suffix.length > 40) {
    throw new Error("FLAP_TOKEN_ADDRESS_SUFFIX must be hex");
  }

  const initCodeHash = hre.ethers.keccak256(minimalProxyInitCode(implementation));
  const seedBase = hre.ethers.keccak256(
    hre.ethers.solidityPacked(
      ["address", "address", "string", "uint256"],
      [deployer, implementation, process.env.FLAP_TOKEN_SYMBOL || "NFTPVP", Date.now()]
    )
  );

  let salt;
  let predicted;
  let iterations = 0;
  for (let i = 0n; i < 5_000_000n; i++) {
    const candidate = hre.ethers.keccak256(hre.ethers.solidityPacked(["bytes32", "uint256"], [seedBase, i]));
    const address = hre.ethers.getCreate2Address(deployer, candidate, initCodeHash);
    iterations += 1;
    if (address.toLowerCase().endsWith(suffix)) {
      salt = candidate;
      predicted = address;
      break;
    }
  }

  if (!salt) {
    throw new Error("No salt found within iteration limit");
  }

  const outDir = path.join(__dirname, "..", "deployments");
  fs.mkdirSync(outDir, { recursive: true });
  const outPath = path.join(outDir, "flap-token-salt.json");
  fs.writeFileSync(
    outPath,
    `${JSON.stringify(
      {
        deployer,
        implementation,
        vaultPortal: inputs.vaultPortal,
        suffix,
        salt,
        predictedTokenAddress: predicted,
        endsWithSuffix: predicted.toLowerCase().endsWith(suffix),
        iterations,
        source: inputs.source,
      },
      null,
      2
    )}\n`
  );

  console.log("Wrote salt result:", outPath);
  console.log("source:", inputs.source);
  console.log("FLAP_VAULT_PORTAL:", inputs.vaultPortal);
  console.log("FLAP_TOKEN_CREATE2_DEPLOYER:", deployer);
  console.log("FLAP_TOKEN_IMPL_TAXED_V3:", implementation);
  console.log("FLAP_TOKEN_SALT:", salt);
  console.log("predicted token address:", predicted);
  console.log("ends with suffix:", predicted.toLowerCase().endsWith(suffix));
  console.log("iterations:", iterations);
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
