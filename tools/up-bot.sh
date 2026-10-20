#!/usr/bin/env bash
# Start the Arcis daemon in Visio tier with a hearth directory.
# Adjust paths for your house box.

set -euo pipefail
HEARTH="${HEARTH:-$HOME/arcis-hearth}"
mkdir -p "$HEARTH"

cd "$(dirname "$0")/../.." || exit 1
# Assume sibling arcis checkout; adjust if needed
ARCIS_BIN="${ARCIS_BIN:-../arcis/zig-out/bin/arcis}"
MODEL="${MODEL:-models/gguf/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf}"

exec "$ARCIS_BIN" --tier visio --port 9090 --model "$MODEL"
