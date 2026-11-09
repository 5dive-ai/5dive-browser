#!/usr/bin/env bash
# DIVE-7648 — a signed-in Shopify admin reads signed in, and no probe holds a
# session past its deadline.
#
# Box report 680 (exact-swallow, 2026-11-03, CLI 0.116.1, browser 1.66.5): the
# owner signed in through connect-request, and `status|shot|read shopify.com`
# read UNKNOWN for hours: "Unable to retrieve content because the page is
# navigating" (the admin's own redirect to /store/<id> landed inside content()),
# or "the page never showed either marker within 8000ms" (the drawn admin took
# longer than the budget), while the served Chrome sat at
# admin.shopify.com/store/<id>, signed in. And one probe kept the group's session
# "busy with a probe request" for 230-380 s, so google.com and cjdropshipping.com
# in the same group were refused the whole time.
#
#   D  the REAL bin/session-daemon, over its socket, with a scripted playwright
#      stub on NODE_PATH (no Chrome)
#      D1 a page whose content() throws "navigating" twice, then shows the
#         signed-in marker, answers with that document (rc 0)
#      D2 a probe whose page never settles answers within its deadline, saying
#         so, and the session is FREE: the next request runs at once
#      D3 a page that already sits at the adapter's signed-in address ends the
#         wait without polling out the budget
#      D4 a render whose content() meets a navigation still returns the picture
#   L  the real bin/browser `status`, against a FAKE served daemon (as
#      browser_served_probe_unit.sh), with the SHIPPED shopify.com adapter
#      L1 undrawn admin + final URL admin.shopify.com/store/<id> -> authenticated
#      L2 undrawn admin + final URL that is not a store -> UNKNOWN
#      L3 Shopify's Cloudflare page, even at a /store/<id> URL -> never authenticated
#      L4 the measured signed-out render at accounts.shopify.com -> expired
#      L5 the request carries the adapter's 20 s wait and its signed-in address
#      L6 the cold probe (nothing served) is not given the adapter's wait
#
# NEGATIVE CONTROL: FIVEDIVE_TEST_DAEMON=<c8bc2f4 session-daemon> turns D1, D2
# and D3 red; FIVEDIVE_TEST_BROWSER=<c8bc2f4 bin/browser> turns L1 and L5 red.
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="${FIVEDIVE_TEST_BROWSER:-$ROOT/browser/bin/browser}"
DAEMON="${FIVEDIVE_TEST_DAEMON:-$ROOT/browser/bin/session-daemon}"
REAL_DAEMON="$ROOT/browser/bin/session-daemon"
FX="$ROOT/tests/fixtures/dive-7079"

TMP="$(mktemp -d)"
_KILL=()
trap 'rc=$?; for p in "${_KILL[@]}"; do kill -KILL "$p" 2>/dev/null; done; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
unset BASH_ENV ENV

PASS=0; FAIL=0
arm() {  # arm <name> <expected> <got>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi
}
yn() { if "$@"; then echo yes; else echo no; fi; }
now_ms() { local t="${EPOCHREALTIME//[!0-9]/}"; echo $(( t / 1000 )); }  # not date +%s%3N: uutils misprints it (DIVE-7978)

# =============================================================== D: the daemon
PW="$TMP/pw"; mkdir -p "$PW/node_modules/playwright-core"
printf '{ "name": "playwright-core", "version": "0.0.0-dive-7648", "main": "index.js" }\n' \
  > "$PW/node_modules/playwright-core/package.json"
# The page is scripted per URL, from the URL's own words, because the daemon's
# environment is fixed at `serve`:
#   nav<N>  content() throws Playwright's "navigating" error N times, then answers
#   hang    content(), waitForTimeout() and close() never resolve
#   landed  page.url() is https://admin.shopify.com/store/ewk1mf-70 from the start
# The document is $SPA_DOM (signed in) for nav*, $SHELL_DOM otherwise.
cat > "$PW/node_modules/playwright-core/index.js" <<'PWJS'
const fs = require('fs');
const rec = (o) => fs.appendFileSync(process.env.PWREC, JSON.stringify(o) + '\n');
const never = () => new Promise(() => {});
const mkpage = () => { let url = 'about:blank', thrown = 0;
  const hang = () => url.includes('hang');
  return {
    on: () => {}, off: () => {},
    setDefaultTimeout: () => {},
    setViewportSize: async () => {},
    goto: async (u) => { url = u; rec({ call: 'goto', url: u }); },
    url: () => url.includes('landed') ? 'https://admin.shopify.com/store/ewk1mf-70' : url,
    title: async () => 'stub',
    waitForLoadState: async (s) => { rec({ call: 'waitForLoadState', s }); },
    waitForTimeout: async (ms) => { if (hang()) return never(); await new Promise((r) => setTimeout(r, Math.min(Number(ms) || 0, 5))); },
    content: async () => {
      rec({ call: 'content', url });
      if (hang()) return never();
      const m = /nav(\d+)/.exec(url);
      if (m && thrown < Number(m[1])) { thrown++;
        throw new Error('page.content: Unable to retrieve content because the page is navigating and changing the content.'); }
      return fs.readFileSync(m ? process.env.SPA_DOM : process.env.SHELL_DOM, 'utf8');
    },
    evaluate: async () => null,
    $: async () => null, $$: async () => [],
    screenshot: async () => Buffer.from('stub-png'),
    close: async () => { rec({ call: 'pageclose', url }); if (hang()) return never(); },
  }; };
exports.chromium = {
  launchPersistentContext: async () => ({ pages: () => [mkpage()], newPage: async () => mkpage(), on: () => {}, close: async () => {} }),
};
PWJS
export PWREC="$TMP/pw.rec"; : > "$PWREC"
export SPA_DOM="$TMP/spa.html" SHELL_DOM="$TMP/shell.html"
cp "$FX/shopify-signed-in.html" "$SPA_DOM"
printf '%s' '<html><head><title>Shopify</title></head><body><div id="app-root"></div></body></html>' > "$SHELL_DOM"

PROF="$TMP/dprof/shopify.com"; mkdir -p "$PROF"; chmod 700 "$TMP/dprof" "$PROF"
DSOCK="$PROF/.5dive-session.sock"
env NODE_PATH="$PW/node_modules" FIVEDIVE_BROWSER_CHROME=/bin/true DISPLAY= \
    FIVEDIVE_BROWSER_PROBE_HARD_MS=2500 FIVEDIVE_BROWSER_BUSY_WAIT_MS=5000 FIVEDIVE_BROWSER_NAV_SETTLE_MS=500 \
    "$DAEMON" serve "$PROF" "$DSOCK" > "$TMP/daemon.out" 2>&1 &
DPID=$!; _KILL+=("$DPID")
for _ in $(seq 100); do grep -q '^ready' "$TMP/daemon.out" 2>/dev/null && break; sleep 0.1; done
arm 'D0 the real daemon serves over the stub' yes "$(yn grep -q '^ready' "$TMP/daemon.out")"
[[ -s "$TMP/daemon.out" ]] && ! grep -q '^ready' "$TMP/daemon.out" && sed 's/^/   daemon: /' "$TMP/daemon.out"

IN_RE='/store/[a-z0-9][a-z0-9-]*/(orders|products|customers)'
OUT_RE="cZone: ?'accounts\\\\.shopify\\\\.com'|/session-service/login"
URL_RE='^https://admin\\.shopify\\.com/store/[a-z0-9][a-z0-9-]*([/?#]|$)'
probe() {  # probe <url> [<extra jq object>] -> OUT ERR RC MS
  local t0; t0=$(now_ms)
  OUT=$(timeout 30 "$REAL_DAEMON" call "$DSOCK" 2>"$TMP/err" <<<"{\"op\":\"probe\",\"url\":\"$1\",\"wait\":3000,\"report_url\":true,\"until\":{\"logged_in\":\"$IN_RE\",\"logged_out\":\"$OUT_RE\",\"challenge\":\"cf-challenge\"${2:+,$2}}}")
  RC=$?; ERR=$(cat "$TMP/err"); MS=$(( $(now_ms) - t0 ))
}

probe 'https://admin.shopify.com/nav2'
arm 'D1 a probe whose page is navigating twice still answers (rc 0)' 0 "$RC"
arm 'D1 ...with the signed-in document' yes "$(yn grep -qE "$IN_RE" <<<"$OUT")"
arm 'D1 ...and no "navigating" error reached the caller' no "$(yn grep -q 'navigating' <<<"$ERR")"
arm 'D1 ...it looked three times' 3 "$(jq -rs '[.[]|select(.call=="content" and (.url|test("nav2")))]|length' "$PWREC")"

# Busy wait (5 s) > deadline (2.5 s), the same order as production (60 s > 35 s).
probe 'https://admin.shopify.com/hang' &
HANGJOB=$!
sleep 0.3
probe 'https://admin.shopify.com/nav0'
SECOND_RC=$RC SECOND_ERR=$ERR SECOND_MS=$MS
wait "$HANGJOB" 2>/dev/null
# The background probe's own numbers are lost to the subshell; re-run it in front.
probe 'https://admin.shopify.com/hang'
arm 'D2 a probe whose page never settles fails (not rc 0)' yes "$(yn test "$RC" -ne 0)"
arm 'D2 ...within its deadline (2.5 s here), not the client cap' yes "$(yn test "$MS" -lt 6000)"
arm 'D2 ...and says the session was freed' yes "$(yn grep -q 'session freed' <<<"$ERR")"
arm 'D2 a second site'"'"'s request behind a hung probe runs (rc 0)' 0 "$SECOND_RC"
arm 'D2 ...it was never refused as busy' no "$(yn grep -q 'still busy' <<<"$SECOND_ERR")"
probe 'https://admin.shopify.com/nav0'
arm 'D2 ...and the session is free right after the deadline, too' 0 "$RC"

: > "$PWREC"
probe 'https://admin.shopify.com/landed' "\"logged_in_url\":\"$URL_RE\""
arm 'D3 a page already at the signed-in address answers (rc 0)' 0 "$RC"
arm 'D3 ...reporting where it landed' yes "$(yn grep -q '5dive-probe-final-url: https://admin.shopify.com/store/ewk1mf-70' <<<"$ERR")"
arm 'D3 ...without polling the budget out (one look)' 1 "$(jq -rs '[.[]|select(.call=="content")]|length' "$PWREC")"

OUT=$(timeout 30 "$REAL_DAEMON" call "$DSOCK" 2>"$TMP/err" <<<'{"op":"render","url":"https://admin.shopify.com/nav1","wait":1}'); RC=$?
arm 'D4 a render that meets a navigation still returns (rc 0)' 0 "$RC"
arm 'D4 ...with the picture' yes "$(yn test "$(jq -r '.png' <<<"$OUT" 2>/dev/null)" = "$(printf stub-png | base64)")"
kill "$DPID" 2>/dev/null

# ===================================================== L: bin/browser `status`
export FIVEDIVE_BROWSER_TMP_ROOT="$TMP/tmproot"
export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/profiles"
export FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/adapters"; mkdir -p "$FIVEDIVE_BROWSER_ADAPTER_DIR"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/rv"
export FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/fake-daemon"
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli"
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
export FIVEDIVE_BROWSER_X11_DIR="$TMP/x11"; mkdir -p "$FIVEDIVE_BROWSER_X11_DIR"
unset FIVEDIVE_BROWSER_PROBE_WAIT_MS
cp "$ROOT/browser/adapters/shopify.com.json" "$FIVEDIVE_BROWSER_ADAPTER_DIR/"
SEAT="$(id -un)"
mkdir -p "$TMP/profiles/$SEAT" "$TMP/rv/$SEAT"; chmod 711 "$TMP/profiles"; chmod 700 "$TMP/profiles/$SEAT"

FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/google-chrome" <<'CHROME'
#!/usr/bin/env bash
[[ "${1:-}" == --version ]] && { echo 'Google Chrome 153.0.8010.36'; exit 0; }
ud=""; last=""
for a in "$@"; do case "$a" in --user-data-dir=*) ud="${a#*=}" ;; esac; last="$a"; done
echo "$last" >> "${URLLOG:-/dev/null}"
[[ "$last" == about:blank ]] && { echo '<html></html>'; exit 0; }
cat "${ud%/}/.fake-dom" 2>/dev/null
CHROME
chmod +x "$FAKEBIN/google-chrome"
export PATH="$FAKEBIN:$PATH" URLLOG="$TMP/urls.log"

DREC="$TMP/daemon.rec"; : > "$DREC"
cat > "$TMP/fake-daemon" <<DAEMONJS
#!/usr/bin/env node
'use strict';
const fs = require('fs'), net = require('net'), path = require('path');
const [, , mode, a1, a2] = process.argv;
if (mode === 'call') { const r = require('child_process').spawnSync('$REAL_DAEMON', ['call', a1], { stdio: 'inherit' }); process.exit(r.status === null ? 1 : r.status); }
const profile = a1, sock = a2;
const rd = (f, d) => { try { return fs.readFileSync(path.join(profile, f), 'utf8'); } catch (e) { return d; } };
const srv = net.createServer((c) => {
  let buf = '';
  c.on('data', (d) => {
    buf += d; const nl = buf.indexOf('\n'); if (nl < 0) return;
    const req = JSON.parse(buf.slice(0, nl));
    fs.appendFileSync('$DREC', JSON.stringify({ site: path.basename(profile), ...req }) + '\n');
    const send = (o) => c.write(JSON.stringify(o) + '\n');
    const end = (rc) => { send({ t: 'end', rc }); c.end(); };
    if (req.op === 'ping') { send({ t: 'out', data: 'pong\n' }); return end(0); }
    if (req.op === 'probe') {
      const furl = rd('.fake-final-url', '');
      if (req.report_url && furl) send({ t: 'log', line: '5dive-probe-final-url: ' + furl.trim() });
      send({ t: 'out', data: rd('.fake-served-dom', '<html></html>') + '\n' }); return end(0);
    }
    send({ t: 'err', msg: "unknown op '" + req.op + "'" }); end(70);
  });
});
try { fs.unlinkSync(sock); } catch (e) {}
srv.listen(sock, () => process.stdout.write('ready\n'));
DAEMONJS
chmod +x "$TMP/fake-daemon"

SD="$TMP/profiles/$SEAT/shopify.com"; mkdir -p "$SD"; chmod 700 "$SD"
cp "$SHELL_DOM" "$SD/.fake-dom"
serve_fake() {
  sleep 600 & local xp=$!; _KILL+=("$xp")
  "$TMP/fake-daemon" listen "$SD" "$SD/.5dive-session.sock" > "$TMP/fd.out" 2>&1 & local dp=$!; _KILL+=("$dp")
  for _ in $(seq 50); do [[ -S "$SD/.5dive-session.sock" ]] && break; sleep 0.1; done
  ( umask 077; printf 'display=150\nxvfb_pid=%s\ndaemon_pid=%s\nsock=%s\nstarted_at=%s\n' \
      "$xp" "$dp" "$SD/.5dive-session.sock" "$(date -u +%s)" > "$SD/.5dive-serve" )
}
stamp() { cut -d' ' -f2- "$SD/.5dive-liveness" 2>/dev/null || echo none; }
serve_fake

cp "$SHELL_DOM" "$SD/.fake-served-dom"; echo 'https://admin.shopify.com/store/ewk1mf-70' > "$SD/.fake-final-url"
out=$("$BROWSER" status shopify.com 2>&1); rc=$?
arm 'L1 undrawn admin at admin.shopify.com/store/<id> -> authenticated' authenticated "$(stamp)"
arm 'L1 ...saying it read the address' yes "$(yn grep -q 'landed on https://admin.shopify.com/store/ewk1mf-70' <<<"$out")"
arm 'L1 ...rc 0' 0 "$rc"

echo 'https://admin.shopify.com/' > "$SD/.fake-final-url"
out=$("$BROWSER" status shopify.com 2>&1)
arm 'L2 undrawn admin NOT at a store address -> unknown, never certified' unknown "$(stamp)"
arm 'L2 ...naming the wait it spent (the adapter'"'"'s 20000ms)' yes "$(yn grep -q 'within 20000ms' <<<"$out")"

cp "$FX/shopify-admin-cloudflare.html" "$SD/.fake-served-dom"; echo 'https://admin.shopify.com/store/ewk1mf-70' > "$SD/.fake-final-url"
"$BROWSER" status shopify.com >/dev/null 2>&1
arm 'L3 Shopify'"'"'s Cloudflare page at a /store/<id> address -> never authenticated' no "$(yn test "$(stamp)" = authenticated)"

cp "$FX/shopify-signed-out-cloudflare.html" "$SD/.fake-served-dom"; echo 'https://accounts.shopify.com/lookup' > "$SD/.fake-final-url"
"$BROWSER" status shopify.com >/dev/null 2>&1
arm 'L4 the measured signed-out render -> expired' expired "$(stamp)"

arm 'L5 the served probe asks for the adapter'"'"'s 20 s wait' 20000 "$(jq -rs '[.[]|select(.op=="probe")]|last|.wait' "$DREC")"
arm 'L5 ...and names the signed-in address' yes \
  "$(jq -rs '[.[]|select(.op=="probe")]|last|.until.logged_in_url|test("store")' "$DREC" 2>/dev/null | sed 's/true/yes/;s/false/no/;s/null/no/')"

# Cold: nothing served. Each look is a Chrome launch, so the adapter's wait must
# not multiply them; the box budget (8000 ms here: 20 polls + 1) still holds.
rm -f "$SD/.5dive-serve"; : > "$URLLOG"
out=$("$BROWSER" status shopify.com 2>&1)
arm 'L6 the cold probe reports the box budget, not the adapter'"'"'s' yes "$(yn grep -q 'within 8000ms' <<<"$out")"
arm 'L6 ...and a shell with no markers stays unknown cold (no address to read)' unknown "$(stamp)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
