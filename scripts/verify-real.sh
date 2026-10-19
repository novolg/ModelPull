#!/bin/sh
# End-to-end integrity checks on real HF files (run inside the Linux container):
#  1. LFS file: engine SHA256 check + independent sha256sum vs official hash from the HF API.
#  2. Small git file: engine git-blob check + independent `git hash-object`-style check.
# Usage: scripts/verify-real.sh <DLChecks-binary>
set -u
BIN=${1:?DLChecks binary}
fail=0

D=$(mktemp -d)
URL=https://huggingface.co/openai-community/gpt2/resolve/main/64-8bits.tflite
OFFICIAL=c966da3b74697803352ca7c6f2f220e7090a557b619de9da0c6b34d89f7825c1   # HF API lfs.oid
"$BIN" --real "$URL" "$D" >"$D/run.log" 2>&1
echo "LFS:   $(grep '^RESULT' "$D/run.log")"
ACTUAL=$(sha256sum "$D/64-8bits.tflite" 2>/dev/null | cut -d' ' -f1)
if [ "$ACTUAL" = "$OFFICIAL" ]; then echo "  ok   independent sha256sum matches official HF hash"; else echo "  FAIL sha256sum=$ACTUAL"; fail=1; fi
grep -q 'label="Done · SHA256 OK"' "$D/run.log" && echo "  ok   app says SHA256 OK" || { echo "  FAIL app label"; fail=1; }
grep -q 'rev=[0-9a-f]\{40\}' "$D/run.log" && echo "  ok   version pinned to a commit" || { echo "  FAIL no pinned commit"; fail=1; }

D=$(mktemp -d)
URL=https://huggingface.co/openai-community/gpt2/resolve/main/config.json
"$BIN" --real "$URL" "$D" >"$D/run.log" 2>&1
echo "small: $(grep '^RESULT' "$D/run.log")"
F="$D/config.json"
if [ -f "$F" ]; then
  GIT=$( (printf 'blob %s\0' "$(wc -c <"$F" | tr -d ' ')"; cat "$F") | sha1sum | cut -d' ' -f1)
  grep -q "git=$GIT" "$D/run.log" && echo "  ok   independent git blob id matches ($GIT)" || { echo "  FAIL git blob id $GIT"; fail=1; }
else echo "  FAIL no file"; fail=1; fi
grep -q 'label="Done · git hash OK"' "$D/run.log" && echo "  ok   app says git hash OK" || { echo "  FAIL app label"; fail=1; }

[ $fail -eq 0 ] && echo "REAL INTEGRITY PASSED" || { echo "REAL INTEGRITY FAILED"; exit 1; }
