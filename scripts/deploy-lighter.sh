#!/usr/bin/env bash
# deploy-lighter.sh — Deploy LightLend Looping contracts to LighterEVM
# Usage:
#   export PRIVATE_KEY=0x...
#   export RPC_LIGHTER_EVM=https://...
#   ./scripts/deploy-lighter.sh
#
# Optional env vars:
#   ETHERSCAN_API_KEY  — for contract verification
#   VERIFY             — set to "true" to enable verification (default: false)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------- Validation ----------
if [ -z "${PRIVATE_KEY:-}" ]; then
  echo "ERROR: PRIVATE_KEY env var is required"
  exit 1
fi

if [ -z "${RPC_LIGHTER_EVM:-}" ]; then
  echo "ERROR: RPC_LIGHTER_EVM env var is required"
  exit 1
fi

# ---------- Build ----------
echo "==> Building contracts..."
cd "$PROJECT_ROOT"
forge build

# ---------- Deploy ----------
VERIFY_FLAGS=""
if [ "${VERIFY:-false}" = "true" ]; then
  if [ -z "${ETHERSCAN_API_KEY:-}" ]; then
    echo "WARNING: VERIFY=true but ETHERSCAN_API_KEY is not set. Skipping verification."
  else
    VERIFY_FLAGS="--verify --etherscan-api-key $ETHERSCAN_API_KEY"
  fi
fi

echo "==> Deploying to LighterEVM..."
forge script scripts/DeployLighterEVM.s.sol:DeployLighterEVM \
  --rpc-url "$RPC_LIGHTER_EVM" \
  --broadcast \
  $VERIFY_FLAGS \
  -vvvv

echo "==> Deployment complete!"
echo ""
echo "Next steps:"
echo "  1. Update POOL_ADDRESS in DeployLighterEVM.s.sol with the actual Pool proxy address"
echo "  2. Whitelist DEX swapper adapters via Looping.setSwapper(address, bool)"
echo "  3. Verify contracts on the block explorer if not done automatically"
