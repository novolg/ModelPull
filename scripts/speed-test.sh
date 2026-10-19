#!/bin/sh
# Compare engine speed with 1 vs N connections on a real HF file (run inside the Linux container).
# Usage: scripts/speed-test.sh <DLChecks-binary> [seconds]
set -u
BIN=${1:?DLChecks binary}
SECS=${2:-40}
URL=https://huggingface.co/openai-community/gpt2/resolve/main/model.safetensors
for c in 1 4; do
  D=$(mktemp -d)
  DL_CONNECTIONS=$c "$BIN" --real "$URL" "$D" >"$D/run.log" 2>&1 &
  P=$!
  sleep "$SECS"
  kill $P 2>/dev/null
  echo "connections=$c: $(grep '^downloading' "$D/run.log" | tail -1)"
done
