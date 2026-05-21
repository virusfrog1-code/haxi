#!/usr/bin/env bash
set -euo pipefail

required_env=(
  BSC_MAINNET_RPC_URL
  DEPLOYER_PRIVATE_KEY
  PANCAKE_ROUTER
  WBNB
  TOKEN_PRICE_BNB_PER_TOKEN
  FLAP_VAULT_PORTAL
  FLAP_VAULT_FACTORY
  FLAP_TOKEN_NAME
  FLAP_TOKEN_SYMBOL
  FLAP_TOKEN_META
  FLAP_TOKEN_SALT
  FLAP_QUOTE_AMT_BNB
  CONFIRM_CREATE_FLAP_TOKEN
)

missing=()
for key in "${required_env[@]}"; do
  if [ -z "${!key:-}" ]; then
    missing+=("${key}")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "Missing required env keys: ${missing[*]}"
  exit 2
fi

if [ "${CONFIRM_CREATE_FLAP_TOKEN}" != "YES" ]; then
  echo "CONFIRM_CREATE_FLAP_TOKEN is not YES; stop before real create."
  exit 3
fi

if [ "${FLAP_TOKEN_META}" = "ipfs://REPLACE_WITH_TOKEN_METADATA_CID" ] || echo "${FLAP_TOKEN_META}" | grep -qi "REPLACE_WITH"; then
  echo "WARNING: metadata is placeholder; created Flap page may not look polished. Continuing because placeholder test token creation was allowed."
fi

if [ "${FLAP_VAULT_FACTORY}" != "0x9BF671d9F6A55C6dE524936e61E7F21D4e5bDAc0" ]; then
  echo "FLAP_VAULT_FACTORY mismatch; stop."
  exit 4
fi

if [ "${FLAP_TOKEN_SALT}" != "0xa8afe8dddf4d0646758b161faa9c21a48de973d54bdf363043a18b6f0a81c20a" ]; then
  echo "FLAP_TOKEN_SALT mismatch; stop."
  exit 5
fi

buy_bps="${FLAP_BUY_TAX_RATE_BPS:-500}"
sell_bps="${FLAP_SELL_TAX_RATE_BPS:-500}"
dividend_bps="${FLAP_DIVIDEND_BPS:-0}"

if [ "${buy_bps}" != "500" ] || [ "${sell_bps}" != "500" ]; then
  echo "Tax bps mismatch; buy=${buy_bps} sell=${sell_bps}; expected 500/500. Stop."
  exit 6
fi

if [ "${dividend_bps}" != "0" ]; then
  echo "FLAP_DIVIDEND_BPS must be 0; stop."
  exit 7
fi

echo "Environment presence/value checks passed without printing secret values."
echo "Using TOKEN_TAXED_V3 + newTokenV6WithVault via create:flap-token-with-vault."

git pull origin main
npm install
npx hardhat compile
npm test
npm run preflight:mainnet
npm run encode:flap-vault-data

test -f deployments/flap-vault-data-mainnet.txt || {
  echo "deployments/flap-vault-data-mainnet.txt missing; stop."
  exit 8
}

node - <<'NODE'
const { ethers } = require("ethers");
const fs = require("fs");

const expectedHash = "0x52aeb419d7afba6a00af6c77ac09c305426303b99b1e0a76f607e90999a98141";
const expectedToken = "0x62C3BB481370984BD8f8c01223FA61Ef3d857777";
const portal = "0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0";
const implementation = "0x024f18294970B5c76c0691b87f138A0317156422";
const initCode = `0x3d602d80600a3d3981f3${"363d3d373d3d3d363d73"}${implementation.slice(2)}5af43d82803e903d91602b57fd5bf3`;
const predicted = ethers.getCreate2Address(
  portal,
  process.env.FLAP_TOKEN_SALT,
  ethers.keccak256(initCode)
);

console.log("predicted token address:", predicted);
console.log("predicted matches expected:", predicted.toLowerCase() === expectedToken.toLowerCase());

if (predicted.toLowerCase() !== expectedToken.toLowerCase()) {
  process.exit(9);
}

const text = fs.readFileSync("deployments/flap-vault-data-mainnet.txt", "utf8");
const hashLine = text.match(/vaultCreationCodeHash:\s*(0x[0-9a-fA-F]+)/);
if (!hashLine || hashLine[1].toLowerCase() !== expectedHash.toLowerCase()) {
  console.error("vaultCreationCodeHash mismatch; stop.");
  process.exit(10);
}

const dataLine = text.match(/vaultData:\s*(0x[0-9a-fA-F]+)/);
if (!dataLine || dataLine[1].length < 1000) {
  console.error("vaultData missing/too short; stop.");
  process.exit(11);
}

console.log("vaultCreationCodeHash verified:", hashLine[1]);
console.log("vaultData source verified: deployments/flap-vault-data-mainnet.txt");
console.log("vaultData length:", dataLine[1].length);
NODE

npm run create:flap-token-with-vault
