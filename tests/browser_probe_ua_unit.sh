#!/usr/bin/env bash
# DIVE-8486 — a client signed in to a site in the sign-in window, tapped Done,
# and the check read "still on the sign-in page"; every later check read signed
# out, and the site's login cookies were gone from the profile. The window is a
# plain Chrome ("Chrome/<n>"); the check after Done is a headless Chrome on the
# same profile ("HeadlessChrome/<n>"). A site that binds its login to the browser
# it was made in answers that check signed out and deletes the login cookies
# itself. The cold check now sends the window's user-agent string.
#
#   U  bin/browser with a fake Chrome that records how it was started
#      U1 a cold `status` starts headless Chrome with --user-agent=… Chrome/<major>.0.0.0,
#         and the string carries no "Headless"
#      U2 FIVEDIVE_BROWSER_PROBE_UA=off is the way back: no --user-agent
#      U3 MUTANT: the pre-fix tree (BASE) starts the check with no --user-agent
#      U4 a profile no Chrome has opened (no "Last Version") keeps the headless
#         string, and no extra Chrome is started to ask for a version
#   L  LIVE, when this machine has Chrome (CI): a local site that records the
#      User-Agent header the check sends
#      L1 the fixed tree: "Chrome/", no "HeadlessChrome"
#      L2 MUTANT, the pre-fix tree: "HeadlessChrome" (the red arm)
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
BASE=f99d728   # 5dive-browser main before DIVE-8486 (1.94.1)
REAL_CHROME="$(command -v google-chrome || command -v chromium || command -v chromium-browser || true)"
[[ -n "${PROBE_UA_SKIP_LIVE:-}" ]] && REAL_CHROME=""
TMP="$(mktemp -d /tmp/d8486.XXXXXX)"
_KILL=()
trap 'rc=$?; for p in "${_KILL[@]}"; do kill "$p" 2>/dev/null; done; chmod -R u+rwx "${TMP:-}" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
PASS=0; FAIL=0; SKIP=0
gha() {
  [[ "${GITHUB_ACTIONS:-}" == true ]] || return 0
  local m="$2"; m="${m//'%'/%25}"; m="${m//$'\r'/%0D}"; m="${m//$'\n'/%0A}"
  printf '::error title=%s::%s\n' "${1//[:,]/ }" "$m"
}
arm() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
        else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; gha "$1" "expected: $2 got: $3"; fi; }
has() { [[ "$2" == *"$1"* ]] && echo yes || echo no; }
yn() { if "$@"; then echo yes; else echo no; fi; }

export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/pr" FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/ad"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/rv" FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/no-daemon"
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli" FIVEDIVE_BROWSER_TMP_ROOT="$TMP/tmproot"
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
export FIVEDIVE_BROWSER_APPROVAL_POLICY="$TMP/no-policy.json" FIVEDIVE_BROWSER_WAKE_PRIV="$TMP/no-wake"
export FIVEDIVE_BROWSER_X11_DIR="$TMP/x11" FIVEDIVE_BROWSER_DRIVE_DEFAULT_FILE="$TMP/drive-default"
export FIVEDIVE_BROWSER_PROBE_WAIT_MS=400 FIVEDIVE_BROWSER_PROBE_POLL_MS=400
# Chrome's reduced version, built from parts: <major> then three ".0".
Z=.0; V="153$Z$Z$Z"
SEAT="$(id -un)"
S=ua.example.com
D="$TMP/pr/$SEAT/$S"
mkdir -p "$D" "$TMP/ad" "$TMP/x11" "$TMP/rv/$SEAT"
chmod 711 "$TMP/pr"; chmod 700 "$TMP/pr/$SEAT" "$D"
# Chrome writes the version it ran into the profile at every start.
printf '153%s%s%s' .0 .7000 .12 > "$D/Last Version"
printf '%s\n' '{"site":"ua.example.com","probe":{"url":"https://ua.example.com/","logged_out_when_dom_matches":"id=\"login-form\""},"actions":{}}' > "$TMP/ad/$S.json"
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
# The fake Chrome logs every launch's argv and answers a --dump-dom with a sign-in page.
cat > "$FAKEBIN/google-chrome" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/chrome-argv.log"
echo '<html><body><form id="login-form"></form></body></html>'
FAKE
chmod +x "$FAKEBIN/google-chrome"
export PATH="$FAKEBIN:$PATH"
cd "$TMP"
probe_line() { grep -- '--dump-dom' "$TMP/chrome-argv.log" | head -1; }

# ================================================================ U1-U2
: > "$TMP/chrome-argv.log"; "$BROWSER" status "$S" >"$TMP/u1.out" 2>&1
L=$(probe_line)
arm "U1a a cold status check starts headless Chrome with the window's user-agent: Chrome/$V" 'yes yes' \
  "$(has ' --headless' " $L") $(has "--user-agent=Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$V Safari/537.36" "$L")"
arm 'U1b ...and the string it sends carries no "Headless"' 'no' "$(has 'Headless' "$L")"
[[ -n "$L" ]] || gha 'U1 detail' "no probe launch; status said: $(tail -c 400 "$TMP/u1.out")"
: > "$TMP/chrome-argv.log"; FIVEDIVE_BROWSER_PROBE_UA=off "$BROWSER" status "$S" >/dev/null 2>&1
L=$(probe_line)
arm 'U2 FIVEDIVE_BROWSER_PROBE_UA=off gives back Chrome'"'"'s own headless string: a check with no --user-agent' 'yes no' \
  "$(has ' --headless' " $L") $(has '--user-agent' "$L")"

# ================================================================ U3  the pre-fix tree
BASEDIR="$TMP/base"
if git -C "$ROOT" cat-file -e "$BASE:browser/bin/browser" 2>/dev/null; then
  mkdir -p "$BASEDIR"; git -C "$ROOT" archive "$BASE" browser | tar -x -C "$BASEDIR"
  : > "$TMP/chrome-argv.log"; "$BASEDIR/browser/bin/browser" status "$S" >/dev/null 2>&1
  L=$(probe_line)
  arm 'U3 MUTANT: the pre-fix check starts headless Chrome with no --user-agent' 'yes no' \
    "$(has ' --headless' " $L") $(has '--user-agent' "$L")"
else
  SKIP=$((SKIP+1)); echo "SKIP: U3 — base $BASE is not in this checkout"
fi

# ================================================================ U4  a profile Chrome never opened
N=never.example.com; mkdir -m 700 -p "$TMP/pr/$SEAT/$N"
sed "s/ua.example.com/$N/g" "$TMP/ad/$S.json" > "$TMP/ad/$N.json"
: > "$TMP/chrome-argv.log"; "$BROWSER" status "$N" >/dev/null 2>&1
arm 'U4 a profile with no "Last Version" keeps the headless string, and no Chrome is started just to ask a version' 'yes no no' \
  "$(has ' --headless' " $(probe_line)") $(has '--user-agent' "$(probe_line)") $(yn grep -q -- '--version' "$TMP/chrome-argv.log")"

# ================================================================ L  LIVE
if [[ -z "$REAL_CHROME" ]]; then
  SKIP=$((SKIP+2)); echo "SKIP: L — needs Chrome; CI has it"
else
  LS=localhost
  PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("localhost",0)); print(s.getsockname()[1])')
  cat > "$TMP/srv.py" <<'PY'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers()
        self.wfile.write(b'<html><body><form id="login-form"></form></body></html>')
        open(sys.argv[2], "a").write((self.headers.get("User-Agent") or "none") + "\n")
    def log_message(self, *a): pass
http.server.HTTPServer(("localhost", int(sys.argv[1])), H).serve_forever()
PY
  python3 "$TMP/srv.py" "$PORT" "$TMP/ua.seen" & _KILL+=($!)
  for i in $(seq 1 50); do python3 -c 'import socket,sys; socket.create_connection(("localhost",int(sys.argv[1])),0.2)' "$PORT" 2>/dev/null && break; sleep 0.1; done
  # The real Chrome, through a shim that adds only --no-sandbox (a CI runner's kernel refuses Chrome's sandbox).
  LBIN="$TMP/lbin"; mkdir -p "$LBIN"
  printf '#!/usr/bin/env bash\nexec "%s" --no-sandbox --disable-gpu "$@"\n' "$REAL_CHROME" > "$LBIN/google-chrome"; chmod +x "$LBIN/google-chrome"
  LPATH="$LBIN:${PATH#"$FAKEBIN:"}"
  printf '{"site":"%s","probe":{"url":"http://%s:%s/projects/","logged_out_when_dom_matches":"id=\\"login-form\\""},"actions":{}}\n' "$LS" "$LS" "$PORT" > "$TMP/ad/$LS.json"
  mkdir -m 700 -p "$TMP/pr/$SEAT/$LS"
  # The window's Chrome would have written this; the runner's Chrome writes its own version here.
  "$REAL_CHROME" --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1 | tr -d '\n' > "$TMP/pr/$SEAT/$LS/Last Version"
  live() { : > "$TMP/ua.seen"; env PATH="$LPATH" FIVEDIVE_BROWSER_PROBE_WAIT_MS=3000 "$1" status "$LS" > "$TMP/$2.out" 2>&1; head -1 "$TMP/ua.seen"; }
  o=$(live "$BROWSER" fixed)
  arm 'L1 LIVE: the check reaches the site as Chrome, not HeadlessChrome' 'yes no' "$(has 'Chrome/' "$o") $(has 'HeadlessChrome' "$o")"
  [[ "$o" == *Chrome/* && "$o" != *HeadlessChrome* ]] || gha 'L1 detail' "seen=$o status=$(tail -c 300 "$TMP/fixed.out")"
  if [[ -x "$BASEDIR/browser/bin/browser" ]]; then
    o=$(live "$BASEDIR/browser/bin/browser" base)
    arm 'L2 LIVE MUTANT: the pre-fix check reaches the site as HeadlessChrome' 'yes' "$(has 'HeadlessChrome' "$o")"
    [[ "$o" == *HeadlessChrome* ]] || gha 'L2 detail' "seen=$o status=$(tail -c 300 "$TMP/base.out")"
  else
    SKIP=$((SKIP+1)); echo "SKIP: L2 — base $BASE is not in this checkout"
  fi
fi

printf '\n%d pass, %d fail, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
