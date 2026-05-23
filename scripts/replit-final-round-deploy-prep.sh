#!/usr/bin/env bash
set -Eeuo pipefail

MODE="preflight"
if [[ "${1:-}" == "--deploy-factory" ]]; then
  MODE="deploy-factory"
elif [[ $# -gt 0 ]]; then
  echo "Unknown argument: $1"
  echo "Usage: bash scripts/replit-final-round-deploy-prep.sh [--deploy-factory]"
  exit 2
fi

unset CONFIRM_CREATE_FLAP_TOKEN

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

STEP="startup"
on_error() {
  local exit_code=$?
  echo
  echo "FINAL ROUND DEPLOY PREP FAILED"
  echo "failed_step=$STEP"
  echo "exit_code=$exit_code"
  echo "No Factory deployment or Token creation was attempted after this failure."
}
trap on_error ERR

run_step() {
  STEP="$1"
  shift
  echo
  echo "==> $STEP"
  "$@"
}

require_envs() {
  local missing=()
  local keys=(
    BSC_MAINNET_RPC_URL
    PANCAKE_ROUTER
    WBNB
    TOKEN_PRICE_BNB_PER_TOKEN
    VRF_COORDINATOR
    VRF_SUB_ID
    VRF_KEY_HASH
    VRF_CALLBACK_GAS_LIMIT
    VRF_REQUEST_CONFIRMATIONS
  )
  if [[ "$MODE" == "deploy-factory" ]]; then
    keys+=(DEPLOYER_PRIVATE_KEY)
  fi
  for key in "${keys[@]}"; do
    if [[ -z "${!key:-}" ]]; then
      missing+=("$key")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Missing required env keys:"
    printf 'MISSING %s\n' "${missing[@]}"
    exit 3
  fi
  echo "Required env keys: OK"
}

write_bytecode_summary() {
  node <<'NODE'
const fs = require("fs");
const { keccak256 } = require("ethers");

fs.mkdirSync("deployments", { recursive: true });
const artifacts = {
  NFTPVPVaultV1: "artifacts/contracts/NFTPVPVaultV1.sol/NFTPVPVaultV1.json",
  NFTPVPVaultFactory: "artifacts/contracts/NFTPVPVaultFactory.sol/NFTPVPVaultFactory.json",
  NFTPVPVaultV1SchemaHelper: "artifacts/contracts/NFTPVPVaultV1SchemaHelper.sol/NFTPVPVaultV1SchemaHelper.json"
};

const summary = {};
for (const [name, file] of Object.entries(artifacts)) {
  const artifact = JSON.parse(fs.readFileSync(file, "utf8"));
  const deployed = artifact.deployedBytecode || artifact.bytecode;
  summary[name] = (deployed.length - 2) / 2;
}
const vaultArtifact = JSON.parse(fs.readFileSync(artifacts.NFTPVPVaultV1, "utf8"));
summary.vaultCreationCodeHash = keccak256(vaultArtifact.bytecode);
fs.writeFileSync("deployments/replit-final-round-bytecode-summary.json", `${JSON.stringify(summary, null, 2)}\n`);
NODE
}

check_vault_data() {
  node <<'NODE'
const fs = require("fs");
const p = "deployments/flap-vault-data-mainnet.txt";
const s = fs.readFileSync(p, "utf8").trim();
const startsWith0x = s.startsWith("0x");
const hexOnly = /^0x[0-9a-fA-F]+$/.test(s);
const summary = {
  vaultDataLength: s.length,
  head20: s.slice(0, 20),
  tail20: s.slice(-20),
  startsWith0x,
  hexOnly
};
console.log("vaultData length=", summary.vaultDataLength);
console.log("startsWith0x=", startsWith0x);
console.log("hexOnly=", hexOnly);
console.log("head20=", summary.head20);
console.log("tail20=", summary.tail20);
if (!startsWith0x || !hexOnly) {
  throw new Error("flap-vault-data-mainnet.txt must be pure 0x hex vaultData");
}
fs.writeFileSync("deployments/replit-final-round-vaultdata-summary.json", `${JSON.stringify(summary, null, 2)}\n`);
NODE
}

print_preflight_summary() {
  node <<'NODE'
const fs = require("fs");
const bytecode = JSON.parse(fs.readFileSync("deployments/replit-final-round-bytecode-summary.json", "utf8"));
const vaultData = JSON.parse(fs.readFileSync("deployments/replit-final-round-vaultdata-summary.json", "utf8"));
let meta = {};
if (fs.existsSync("deployments/flap-vault-data-mainnet.meta.json")) {
  meta = JSON.parse(fs.readFileSync("deployments/flap-vault-data-mainnet.meta.json", "utf8"));
}

console.log("");
console.log("FINAL ROUND PREFLIGHT SUMMARY");
console.log("commitHash=", process.env.FINAL_ROUND_COMMIT_HASH || "unknown");
console.log("testResult=", process.env.FINAL_ROUND_TEST_RESULT || "unknown");
console.log("preflightResult=", process.env.FINAL_ROUND_PREFLIGHT_RESULT || "unknown");
console.log("NFTPVPVaultV1 bytecode size=", bytecode.NFTPVPVaultV1);
console.log("NFTPVPVaultFactory bytecode size=", bytecode.NFTPVPVaultFactory);
console.log("SchemaHelper bytecode size=", bytecode.NFTPVPVaultV1SchemaHelper);
console.log("vaultCreationCodeHash=", meta.vaultCreationCodeHash || bytecode.vaultCreationCodeHash);
console.log("vaultData length=", vaultData.vaultDataLength);
console.log("vaultData head20=", vaultData.head20);
console.log("vaultData tail20=", vaultData.tail20);
console.log("vaultData pure0xHex=", vaultData.startsWith0x && vaultData.hexOnly ? "true" : "false");
console.log("factoryDeployment=", "not attempted");
console.log("tokenCreation=", "not attempted");
NODE
}

print_factory_summary() {
  node <<'NODE'
const fs = require("fs");
const deployment = JSON.parse(fs.readFileSync("deployments/bsc-mainnet-factory.json", "utf8"));
const link = `https://bscscan.com/address/${deployment.NFTPVPVaultFactory}`;

console.log("");
console.log("FINAL ROUND FACTORY DEPLOYMENT SUMMARY");
console.log("txHash=", deployment.txHash);
console.log("newFactoryAddress=", deployment.NFTPVPVaultFactory);
console.log("ownerDeployer=", deployment.deployer);
console.log("vaultCreationCodeHash=", deployment.vaultCreationCodeHash);
console.log("NFTPVPVaultV1 bytecode size=", deployment.bytecodeSizes.NFTPVPVaultV1);
console.log("NFTPVPVaultFactory bytecode size=", deployment.bytecodeSizes.NFTPVPVaultFactory);
console.log("SchemaHelper bytecode size=", deployment.bytecodeSizes.NFTPVPVaultV1SchemaHelper);
console.log("BscScan Factory link=", link);
console.log("Update Replit Secret FLAP_VAULT_FACTORY=", deployment.NFTPVPVaultFactory);
console.log("tokenCreation=", "not attempted");
NODE
}

run_step "git fetch origin main" git fetch origin main
run_step "git reset --hard origin/main" git reset --hard origin/main
FINAL_ROUND_COMMIT_HASH="$(git rev-parse HEAD)"
export FINAL_ROUND_COMMIT_HASH

run_step "check required env keys" require_envs
run_step "npm install" npm install
run_step "npx hardhat compile" npx hardhat compile
run_step "write bytecode summary" write_bytecode_summary
run_step "npm test" npm test
FINAL_ROUND_TEST_RESULT="passed"
export FINAL_ROUND_TEST_RESULT
run_step "npm run preflight:mainnet" npm run preflight:mainnet
FINAL_ROUND_PREFLIGHT_RESULT="passed"
export FINAL_ROUND_PREFLIGHT_RESULT
run_step "npm run encode:flap-vault-data" npm run encode:flap-vault-data
run_step "validate vaultData file" check_vault_data
run_step "print preflight summary" print_preflight_summary

if [[ "$MODE" == "deploy-factory" ]]; then
  run_step "npm run deploy:mainnet-factory" npm run deploy:mainnet-factory
  run_step "print factory deployment summary" print_factory_summary
else
  echo
  echo "DEFAULT MODE COMPLETE: Factory deployment was not attempted."
fi
