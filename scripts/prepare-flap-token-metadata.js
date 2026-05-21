const fs = require("fs");
const path = require("path");

function requireEnv(name) {
  const value = process.env[name];
  if (!value || value.trim() === "") {
    throw new Error(`${name} is required`);
  }
  return value.trim();
}

async function main() {
  const name = requireEnv("FLAP_TOKEN_NAME");
  const symbol = requireEnv("FLAP_TOKEN_SYMBOL");
  const image = process.env.FLAP_TOKEN_IMAGE && process.env.FLAP_TOKEN_IMAGE.trim() !== ""
    ? process.env.FLAP_TOKEN_IMAGE.trim()
    : "ipfs://REPLACE_WITH_LOGO_CID";
  const description = process.env.FLAP_TOKEN_DESCRIPTION && process.env.FLAP_TOKEN_DESCRIPTION.trim() !== ""
    ? process.env.FLAP_TOKEN_DESCRIPTION.trim()
    : `${name} (${symbol}) is a Flap TOKEN_TAXED_V3 launch connected to NFTPVPVaultV1 for NFT-holder dividends, PvP queue play, and LossVault rewards.`;

  const metadata = {
    name,
    symbol,
    description,
    image,
  };

  const outDir = path.join(__dirname, "..", "deployments");
  fs.mkdirSync(outDir, { recursive: true });
  const outPath = path.join(outDir, "token-metadata.json");
  fs.writeFileSync(outPath, `${JSON.stringify(metadata, null, 2)}\n`);

  console.log("Wrote metadata draft:", outPath);
  console.log(JSON.stringify(metadata, null, 2));
  console.log("Dry-run FLAP_TOKEN_META placeholder: ipfs://REPLACE_WITH_TOKEN_METADATA_CID");
  console.log("Before real token creation, upload this JSON and set FLAP_TOKEN_META to the final metadata URI.");
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
