#!/usr/bin/env bash
# Deploys Brake, dUSD and the DemoWorld factory to a running Anvil (npm run chain), and refreshes
# the ABIs the web app uses. Each viewer's wallet then sets up its own run from the page.
set -euo pipefail
cd "$(dirname "$0")/../../../contracts/brake"

# Anvil's public default key #0. Never use it anywhere but a local chain.
ANVIL_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

NETWORK=anvil forge script script/DeployDemo.s.sol --rpc-url http://127.0.0.1:8545 \
  --broadcast --private-key $ANVIL_KEY --slow >/dev/null
bash ../../client/demo/scripts/abis.sh
echo "Ready on Anvil: $(cat ../../client/demo/src/chains/evm/networks/anvil.json | tr -d '\n ')"
