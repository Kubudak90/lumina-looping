#!/usr/bin/env bash
# Deploy LightLend Looping contracts to Base Sepolia.
# Usage:
#   export PRIVATE_KEY=0x...
#   export RPC_BASE_SEPOLIA=https://sepolia.base.org
#   ./scripts/deploy-lighter.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -z "${PRIVATE_KEY:-}" ]; then
  echo "ERROR: PRIVATE_KEY env var is required"
  exit 1
fi

RPC_URL="${RPC_BASE_SEPOLIA:-${RPC_URL:-}}"
if [ -z "$RPC_URL" ]; then
  echo "ERROR: RPC_BASE_SEPOLIA (or RPC_URL) is required"
  exit 1
fi

if [[ "$RPC_URL" == *"zklighter"* ]]; then
  echo "ERROR: refusing to broadcast against a Lighter REST URL. Use a verified EVM RPC (Base Sepolia)."
  exit 1
fi

echo "==> Building contracts..."
cd "$PROJECT_ROOT"
forge build

CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL")"
if [ "$CHAIN_ID" != "84532" ]; then
  echo "ERROR: expected Base Sepolia chain id 84532, got $CHAIN_ID"
  exit 1
fi

VERIFY_FLAGS=""
if [ "${VERIFY:-false}" = "true" ]; then
  if [ -z "${ETHERSCAN_API_KEY:-}" ]; then
    echo "WARNING: VERIFY=true but ETHERSCAN_API_KEY is not set. Skipping verification."
  else
    VERIFY_FLAGS="--verify --etherscan-api-key $ETHERSCAN_API_KEY"
  fi
fi

echo "==> Deploying Looping to Base Sepolia..."
forge script scripts/DeployLighterEVM.s.sol:DeployLooping \
  --rpc-url "$RPC_URL" \
  --broadcast \
  $VERIFY_FLAGS \
  -vvvv
