#!/usr/bin/env bash
# DIVE-7237 (GAP-11) — a DOM `act` attaches a file: {"op":"upload","selector":…,"path":…}.
#
# Before: "'upload' is not an act step", so a picture for a Meta ad could only go
# in through input mode, and facebook.com reached input mode only by a root step
# (DIVE-6902, 10-29). Now the step sets the page's file input. The file is read
# HERE, as the calling seat, and travels as bytes to the browser (which may run
# as another seat), with the same rules input mode's upload has: an absolute path
# to a regular file the caller can read, capped, audited.
#
#   C  `act` through the real bin/browser and the real driver-playwright, with the
#      recording playwright stub from browser_plugin_unit.sh
#      C1 the step reaches setInputFiles once, with the file's name, its type and
#         exactly its bytes (not a path for the browser's seat to open)
#      C2 the upload is written to the profile's audit log, by path
#      C3 refused before anything runs (64, no setInputFiles): a relative path, a
#         directory, a file the caller cannot read, no selector, over the cap,
#         and with --record
#   N  control: the pre-fix tree refuses the same step as "not an act step"
#   L  LIVE, where this machine has Chrome and playwright-core (CI installs it):
#      a local page's <input type=file> receives the file in real Chrome
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
BASE=46ef3a5   # 5dive-browser main before DIVE-7237
TMP="$(mktemp -d /tmp/d7237u.XXXXXX)"
_KILL=()
trap 'rc=$?; for p in "${_KILL[@]}"; do kill "$p" 2>/dev/null; done; chmod -R u+rwx "${TMP:-}" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0; SKIP=0
arm() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
        else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
has() { [[ "$2" == *"$1"* ]] && echo yes || echo no; }
run() { local o="$TMP/.o" e="$TMP/.e"; "$@" >"$o" 2>"$e"; RC=$?; OUT=$(cat "$o"); ERR=$(cat "$e"); return 0; }

SEAT="$(id -un)"
export FIVEDIVE_BROWSER_TMP_ROOT="$TMP/tmproot" FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/profiles"
export FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/adapters"; mkdir -p "$FIVEDIVE_BROWSER_ADAPTER_DIR"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/sessions" FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/no-session-daemon"
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli"
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
export FIVEDIVE_BROWSER_APPROVAL_DIR="$TMP/approvals" FIVEDIVE_BROWSER_APPROVAL_POLICY="$TMP/policy.json"
export FIVEDIVE_BROWSER_GRANT_UID="$(id -u)" FIVEDIVE_BROWSER_RUN_SETTLE_MS=0 FIVEDIVE_BROWSER_TREE_SETTLE_MS=0
export FIVEDIVE_BROWSER_EXPECT_WAIT_MS=0
mkdir -p "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT"
chmod 711 "$FIVEDIVE_BROWSER_PROFILE_ROOT"; chmod 700 "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT"
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == --version ]] && { echo "Google Chrome 153"; exit 0; }\necho "<html><body>public</body></html>"\n' > "$FAKEBIN/google-chrome"
chmod +x "$FAKEBIN/google-chrome"
REALPATH="$PATH"; export PATH="$FAKEBIN:$PATH"

PWROOT="$TMP/pw"; mkdir -p "$PWROOT/node_modules/playwright-core"
printf '{ "name": "playwright-core", "version": "0.0.0-stub", "main": "index.js" }\n' > "$PWROOT/node_modules/playwright-core/package.json"
sed -n "/^cat > \"\$PWROOT\/node_modules\/playwright-core\/index.js\" <<'PWJS'$/,/^PWJS$/p" tests/browser_plugin_unit.sh \
  | sed '1d;$d' > "$PWROOT/node_modules/playwright-core/index.js"
arm 'C0 (anchor) the stub was extracted, and it records setInputFiles' yes \
  "$(grep -q "setInputFiles: async (sel, p) => rec" "$PWROOT/node_modules/playwright-core/index.js" && echo yes || echo no)"
export NODE_PATH="$PWROOT/node_modules" PWREC="$TMP/pw.jsonl" PWWALK="$TMP/walk.json"
: > "$PWREC"; printf '{"nodes":[],"marker":"m-1"}' > "$PWWALK"

# A real 1x1 PNG, the shape of an ad picture.
printf 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC' | base64 -d > "$TMP/ad picture.png"
URL="https://ads.test/create"
step() { printf '[{"op":"upload","selector":"ref=button/Upload","path":"%s"}]' "$1"; }
calls() { jq -s '[.[] | select(.call=="setInputFiles")] | length' "$PWREC"; }

run "$BROWSER" act "$URL" --steps="$(step "$TMP/ad picture.png")" --out="$TMP/c1"
arm 'C1a act with an upload step exits 0' 0 "$RC"
[[ "$RC" == 0 ]] || printf 'C1 output: %s %s\n' "$OUT" "$ERR"
arm 'C1b setInputFiles was called once' 1 "$(calls)"
got=$(jq -r -s '[.[] | select(.call=="setInputFiles")] | last | .path' "$PWREC")
arm 'C1c ...with the file name and its type' 'ad picture.png image/png' "$(jq -r '"\(.name) \(.mimeType)"' <<<"$got" 2>/dev/null)"
arm 'C1d ...and exactly its bytes (not a path for the browser'"'"'s seat to open)' "$(od -An -tu1 "$TMP/ad picture.png" | tr -s ' \n' ' ' | sed 's/^ //;s/ $//')" \
  "$(jq -r '.buffer.data | map(tostring) | join(" ")' <<<"$got" 2>/dev/null)"
arm 'C2 the upload is in the profile'"'"'s audit log, by path' yes \
  "$(grep -rh '"event":"act-upload"' "$FIVEDIVE_BROWSER_PROFILE_ROOT" --include=.5dive-audit.jsonl 2>/dev/null | grep -qF "$TMP/ad picture.png" && echo yes || echo no)"

: > "$PWREC"
run "$BROWSER" act "$URL" --steps="$(step 'ad.png')"
arm 'C3a a relative path is refused (64), nothing runs' "64 0 yes" "$RC $(calls) $(has 'absolute' "$ERR")"
run "$BROWSER" act "$URL" --steps="$(step "$TMP")"
arm 'C3b a directory is refused (64)' "64 0" "$RC $(calls)"
cp "$TMP/ad picture.png" "$TMP/locked.png"; chmod 000 "$TMP/locked.png"
if [[ -r "$TMP/locked.png" ]]; then echo "SKIP: C3c — this uid reads a 0000 file (root)"; SKIP=$((SKIP+1))
else
  run "$BROWSER" act "$URL" --steps="$(step "$TMP/locked.png")"
  arm 'C3c a file this seat cannot read is refused (64)' "64 0 yes" "$RC $(calls) $(has 'this seat can read' "$ERR")"
fi
run "$BROWSER" act "$URL" --steps="[{\"op\":\"upload\",\"path\":\"$TMP/ad picture.png\"}]"
arm 'C3d an upload with no selector is refused (64)' "64 0 yes" "$RC $(calls) $(has 'names the file input' "$ERR")"
run env FIVEDIVE_BROWSER_UPLOAD_MAX_BYTES=10 "$BROWSER" act "$URL" --steps="$(step "$TMP/ad picture.png")"
arm 'C3e a file over the cap is refused (64)' "64 0 yes" "$RC $(calls) $(has 'over the 10' "$ERR")"
run "$BROWSER" act "$URL" --steps="$(step "$TMP/ad picture.png")" --record=adpic
arm 'C3f an upload is not recorded as a routine (64)' "64 0" "$RC $(calls)"

if git -C "$ROOT" cat-file -e "$BASE:browser/bin/browser" 2>/dev/null; then
  mkdir -p "$TMP/old"; git -C "$ROOT" archive "$BASE" browser | tar -x -C "$TMP/old"
  run "$TMP/old/browser/bin/browser" act "$URL" --steps="$(step "$TMP/ad picture.png")"
  arm 'N1 control: before the fix the same step is not an act step (64)' "64 yes" "$RC $(has "'upload' is not an act step" "$ERR")"
else
  echo "SKIP: N1 — base $BASE is not in this checkout"; SKIP=$((SKIP+1))
fi

REAL_CHROME="$(PATH="$REALPATH" command -v google-chrome || PATH="$REALPATH" command -v chromium || true)"
PW_OK=no; [[ -d "$ROOT/browser/node_modules/playwright-core" ]] && PW_OK=yes
if [[ -z "$REAL_CHROME" || "$PW_OK" != yes || -n "${INPUT_DRIVE_SKIP_LIVE:-}" ]]; then
  SKIP=$((SKIP+1)); printf 'SKIP: L live arm — chrome: %s, playwright-core next to the plugin: %s\n' "${REAL_CHROME:-none}" "$PW_OK"
else
  cat > "$TMP/site.cjs" <<'JS'
require('http').createServer((req, res) => {
  res.setHeader('content-type', 'text/html');
  res.end('<html><head><title>Create ad</title></head><body><h1>Create ad</h1><input type="file" id="pic" onchange="document.getElementById(\'got\').textContent = \'GOT \' + this.files[0].name + \' \' + this.files[0].size"><p id="got">none</p></body></html>');
}).listen(0, '127.0.0.1', function () { console.log(this.address().port); });
JS
  node "$TMP/site.cjs" > "$TMP/port" & _KILL+=($!)
  for _ in $(seq 50); do [[ -s "$TMP/port" ]] && break; sleep 0.1; done
  run env -u NODE_PATH -u PWWALK PATH="$REALPATH" FIVEDIVE_BROWSER_RUN_SETTLE_MS=300 \
    "$BROWSER" act "http://localhost:$(cat "$TMP/port")/" --steps="[{\"op\":\"upload\",\"selector\":\"#pic\",\"path\":\"$TMP/ad picture.png\"}]" \
    --expect="GOT ad picture.png $(stat -c %s "$TMP/ad picture.png")" --out="$TMP/live"
  arm 'L1 real Chrome: the page'"'"'s file input received the file (verified by the page itself)' "0 yes" "$RC $(has 'verified' "$OUT")"
  [[ "$RC" == 0 ]] || printf 'L1 output: %s %s\n' "$OUT" "$ERR"
fi

printf '\n%d pass, %d fail, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
