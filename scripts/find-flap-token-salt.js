const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

const BSC_PORTAL = "0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0";
const TAX_TOKEN_V3_IMPL = "0xe95ba8270c7956eba2575e57e97c102ee046e6bc";

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

async function main() {
  const deployer = optionalAddress("FLAP_TOKEN_CREATE2_DEPLOYER", BSC_PORTAL);
  const implementation = optionalAddress("FLAP_TOKEN_IMPL_TAXED_V3", TAX_TOKEN_V3_IMPL);
  const suffix = (process.env.FLAP_TOKEN_ADDRESS_SUFFIX || "7777").toLowerCase();
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
        suffix,
        salt,
        predictedTokenAddress: predicted,
        endsWithSuffix: predicted.toLowerCase().endsWith(suffix),
        iterations,
      },
      null,
      2
    )}\n`
  );

  console.log("Wrote salt result:", outPath);
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
