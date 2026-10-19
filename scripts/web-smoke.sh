#!/bin/sh
# Smoke test of the web version API in an isolated state/config dir.
# Usage: scripts/web-smoke.sh <path-to-ModelPullWeb-binary>
set -u
BIN=${1:?binary}
T=$(pwd)/tests/tmp/web-$$
mkdir -p "$T/state" "$T/dl" "$T/cfg/downloader"
echo '{"connections":2,"maxActive":1,"verifySHA":true,"keepAwake":false,"saveDir":"/tmp"}' > "$T/cfg/downloader/settings.json"  # old-name config to migrate
MODELPULL_STATE_DIR="$T/state" XDG_CONFIG_HOME="$T/cfg" "$BIN" --port 18765 --no-open >"$T/server.log" 2>&1 &
PID=$!
sleep 2
B=http://127.0.0.1:18765
H='X-ModelPull: 1'
fail=0
expect() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got: $2, want: $3)"; fail=1; fi; }

expect "ping" "$(curl -s $B/api/ping)" "modelpull"
expect "old config folder moved" "$(test -f "$T/cfg/modelpull/settings.json" && test ! -e "$T/cfg/downloader" && echo yes)" "yes"
expect "old POST header rejected" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'X-Downloader: 1' -d '{}' $B/api/quit)" "403"
expect "foreign Host rejected" "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.com' $B/api/state)" "403"
expect "POST without header rejected" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -d '{}' $B/api/quit)" "403"
# Malformed framing must close the connection without killing the server.
for length in -1 invalid 999999999999999999999999 1048577; do
  expect "invalid Content-Length $length rejected" "$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' -H "Content-Length: $length" $B/api/ping)" "000"
  expect "server survives malformed length" "$(curl -s --max-time 3 $B/api/ping)" "modelpull"
done
expect "page served" "$(curl -s $B/ | head -c 15)" "<!doctype html>"
expect "icon served as PNG" "$(curl -s -o /dev/null -w '%{http_code} %{content_type}' $B/icon.png)" "200 image/png"
SETTINGS=$(printf '{"connections":4,"maxActive":1,"verifySHA":true,"keepAwake":true,"saveDir":"%s/dl"}' "$T")
expect "settings saved" "$(curl -s -X POST -H "$H" -d "$SETTINGS" $B/api/settings)" '{"ok":true}'
expect "settings applied" "$(curl -s $B/api/state | grep -c "web-$$")" "1"
expect "bad folder rejected" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$H" -d '{"connections":4,"maxActive":1,"verifySHA":true,"keepAwake":true,"saveDir":"/nope/x"}' $B/api/settings)" "400"
expect "non-HF link rejected" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$H" -d '{"url":"https://huggingface.co/a/b"}' $B/api/add)" "400"
# Token tests only on Linux: on macOS the store is the real user Keychain.
if [ "$(uname)" = "Linux" ]; then
  expect "token saved" "$(curl -s -X POST -H "$H" -d '{"huggingface":"hf_test123"}' $B/api/tokens)" '{"ok":true}'
  expect "token value never returned" "$(curl -s $B/api/state | grep -c hf_test123)" "0"
  expect "token flag set" "$(curl -s $B/api/state | grep -o '"huggingface":true')" '"huggingface":true'
  expect "tokens file mode 600" "$(stat -c '%a' "$T/cfg/modelpull/tokens.json")" "600"
  expect "token removed" "$(curl -s -X POST -H "$H" -d '{"huggingface":""}' $B/api/tokens)" '{"ok":true}'
fi
expect "add HF link" "$(curl -s -X POST -H "$H" -d '{"url":"https://huggingface.co/openai-community/gpt2/resolve/main/config.json"}' $B/api/add)" '{"ok":true}'
expect "duplicate rejected" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$H" -d '{"url":"https://huggingface.co/openai-community/gpt2/resolve/main/config.json"}' $B/api/add)" "400"

i=0
while [ $i -lt 60 ] && [ ! -f "$T/dl/config.json" ]; do sleep 1; i=$((i+1)); done
expect "file downloaded" "$(test -f "$T/dl/config.json" && echo yes)" "yes"
expect "state shows done" "$(curl -s $B/api/state | grep -o '"phase":"done"' | head -1)" '"phase":"done"'
expect "dirs listing" "$(curl -s "$B/api/dirs?path=$T" | grep -o '"dl"' | head -1)" '"dl"'
expect "quit" "$(curl -s -X POST -H "$H" -d '{}' $B/api/quit)" '{"ok":true}'
sleep 1
expect "process exited" "$(kill -0 $PID 2>/dev/null && echo alive || echo gone)" "gone"
expect "no orphan keep-awake process" "$(pgrep -f "pid=$PID" >/dev/null 2>&1 || pgrep -f "caffeinate -i -w $PID" >/dev/null 2>&1; [ $? -eq 0 ] && echo orphan || echo none)" "none"

echo "--- server log"; cat "$T/server.log"
[ $fail -eq 0 ] && echo "WEB SMOKE PASSED" || { echo "WEB SMOKE FAILED"; exit 1; }
