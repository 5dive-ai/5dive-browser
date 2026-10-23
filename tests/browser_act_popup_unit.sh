#!/usr/bin/env bash
# DIVE-6392 — a popup an act opens is followed, and an act's capture says its browser mode.
#
# Round 8 (cic-arm-a, browser 1.45.0): Gamma loaded with no challenge, then
# "Continue with Google" showed pressed and nothing came into view, twice. The
# Google chooser opens in a POPUP, and both step loops kept acting on and
# re-reading the page they started on. And page.meta.json had no browser_mode for
# an act, so nobody could tell whether that click ran headed.
#
#   U  lib/popup.cjs in node, against fake pages
#      U1 a popup that opens during the wait is taken into view, and said
#      U2 one that closes hands the view back to its opener, and said
#      U3 no wait after a fill; the wait ends as soon as a popup arrives
#      U4 pageFor: the popup for a URL on its own origin or no URL, null for another
#      U5 a popup that closed before it was taken is said, and never in view
#   C  `act`, cold, through the real bin/browser and driver-playwright, with the
#      recording playwright stub from browser_plugin_unit.sh wrapped so a click
#      can open a popup (PWPOPUP)
#      C1 a click that opens a popup: the act's re-read IS the popup (url, title,
#         page.html, page.png), the output says "a popup opened", page.meta.json
#         carries popup and browser_mode
#      C2 a step after the click acts IN the popup
#      C3 a popup that closes on its own click: the re-read is the opener again
#      C4 (control) a click that opens nothing: the opener, no popup line, and
#         browser_mode is still on the act's page.meta.json
#      C5 a Google chooser in the popup gets the Google sign-in guard: the
#         hard stop on "no saved account" holds there too
#      M1 MUTANT: the loop never follows (1.45.0's behaviour) -> C1 goes red
#   S  the SERVED browser (bin/session-daemon serve, same stub), over its socket
#      S1 a plan whose click opens a popup: act_report is the popup, browser_mode
#         headed, and the log says so
#      S2 the next plan on the popup's URL acts in the popup and does not reload it
#      S2c a plan with no URL continues in the popup
#      S3 a snapshot on that URL is read from the popup, not reloaded
#      S4 a plan on the opener's site goes to the main tab, the popup left open
#   L  LIVE, where this machine has Chrome and playwright-core (CI installs it): a
#      local page whose button opens a popup with window.open
#      L1 `act` clicks it in real Chrome: the re-read is the popup page
#      L2 a second step clicks a button inside the popup, and its effect shows
#      L3 MUTANT (no follow, 1.45.0's behaviour) in real Chrome: the re-read
#         stays on the opener — the negative control for L1
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
LIB="$ROOT/browser/lib/popup.cjs"

TMP="$(mktemp -d /tmp/d6392.XXXXXX)"
_KILL=()
trap 'rc=$?; for p in "${_KILL[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0; SKIP=0
gha() {
  [[ "${GITHUB_ACTIONS:-}" == true ]] || return 0
  local m="$2"; m="${m//'%'/%25}"; m="${m//$'\r'/%0D}"; m="${m//$'\n'/%0A}"
  printf '::error title=%s::%s\n' "${1//[:,]/ }" "$m"
}
arm() {  # arm <name> <expected> <got>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; gha "$1" "expected: $2 got: $3"; fi
}
has() { [[ "$2" == *"$1"* ]] && echo yes || echo no; }
run() { local o="$TMP/.o" e="$TMP/.e"; "$@" >"$o" 2>"$e"; RC=$?; OUT=$(cat "$o"); ERR=$(cat "$e"); return 0; }

# ================================================================ U  lib
cat > "$TMP/fake.cjs" <<'JS'
// A page that is an EventEmitter with a url and a closed flag: what lib/popup.cjs reads.
const { EventEmitter } = require('events');
exports.page = (url) => { const p = new EventEmitter(); p._url = url; p._closed = false;
  p.url = () => p._url; p.isClosed = () => p._closed; p.waitForLoadState = async () => {};
  p.setDefaultTimeout = () => {}; return p; };
JS
u="$(FIVEDIVE_BROWSER_POPUP_WAIT_MS=2000 node -e '
const pop=require(process.argv[1]), F=require(process.argv[2]); const lines=[]; const out={};
(async () => {
  const a=F.page("https://gamma.test/signup"); const f=pop.follow(a,{log:(l)=>lines.push(l)});
  const g=F.page("https://accounts.google.test/o/oauth2?x=1");
  setTimeout(()=>a.emit("popup",g),50);
  let t=Date.now(); const p1=await f.sync("click"); out.u1=(p1===g)+" "+(Date.now()-t<1500)+" "+(f.popup&&f.popup.host);
  out.u4a=(f.pageFor("https://accounts.google.test/other")===g)+" "+(f.pageFor("https://gamma.test/")===null)+" "+(f.pageFor(null)===g);
  g._closed=true; const p2=await f.sync(null); out.u2=(p2===a)+" "+(f.popup===null);
  t=Date.now(); await f.sync("fill"); out.u3=(Date.now()-t<100)+"";
  const h=F.page("https://accounts.google.test/x"); h._closed=true; a.emit("popup",h);
  const p3=await f.sync(null); out.u5=(p3===a)+"";
  out.lines=lines; console.log(JSON.stringify(out));
})();' "$LIB" "$TMP/fake.cjs")"
arm 'U1 a popup opened during the wait is in view, and the wait ended when it came' 'true true accounts.google.test' "$(jq -r .u1 <<<"$u")"
arm 'U1b ...and it is said, with its host' yes "$(has 'a popup opened: accounts.google.test, now in view' "$(jq -r '.lines[0]' <<<"$u")")"
arm 'U2 a popup that closed hands the view back to its opener' 'true true' "$(jq -r .u2 <<<"$u")"
arm 'U2b ...and it is said' yes "$(has 'the popup (accounts.google.test) closed; back on gamma.test' "$(jq -r '.lines[1]' <<<"$u")")"
arm 'U3 no popup wait after a fill' true "$(jq -r .u3 <<<"$u")"
arm 'U4 pageFor: the popup on its own origin or with no URL, none for another' 'true true true' "$(jq -r .u4a <<<"$u")"
arm 'U5 a popup closed before it was taken: said, never in view' 'true yes' \
  "$(jq -r .u5 <<<"$u") $(has 'opened (accounts.google.test) and closed again by itself' "$(jq -r '.lines[2]' <<<"$u")")"

# ================================================================ C  act, cold
SEAT="$(id -un)"
export FIVEDIVE_BROWSER_TMP_ROOT="$TMP/tmproot"
export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/profiles"
export FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/adapters"; mkdir -p "$FIVEDIVE_BROWSER_ADAPTER_DIR"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/sessions"
export FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/no-session-daemon"
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli"
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
export FIVEDIVE_BROWSER_APPROVAL_DIR="$TMP/approvals" FIVEDIVE_BROWSER_APPROVAL_POLICY="$TMP/policy.json"
export FIVEDIVE_BROWSER_GRANT_UID="$(id -u)" FIVEDIVE_BROWSER_RUN_SETTLE_MS=0 FIVEDIVE_BROWSER_TREE_SETTLE_MS=0
export FIVEDIVE_BROWSER_EXPECT_WAIT_MS=0 FIVEDIVE_BROWSER_POPUP_WAIT_MS=300
# The stub arms run headless on purpose: no Xvfb is started for a stub browser.
export FIVEDIVE_BROWSER_HEADLESS=1
mkdir -p "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT"
chmod 711 "$FIVEDIVE_BROWSER_PROFILE_ROOT"; chmod 700 "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT"

FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == --version ]] && { echo "Google Chrome 153"; exit 0; }\necho "<html><body>public</body></html>"\n' > "$FAKEBIN/google-chrome"
chmod +x "$FAKEBIN/google-chrome"
REALPATH="$PATH"
export PATH="$FAKEBIN:$PATH"

# THE STUB, from the main suite, so the two cannot grade two different stubs —
# wrapped: PWPOPUP={on, url, title, html, close_on_click} makes a click on <on>
# open a popup page with those answers, the way Playwright fires 'popup'.
PWROOT="$TMP/pw"; mkdir -p "$PWROOT/node_modules/playwright-core"
printf '{ "name": "playwright-core", "version": "0.0.0-stub", "main": "index.js" }\n' > "$PWROOT/node_modules/playwright-core/package.json"
sed -n "/^cat > \"\$PWROOT\/node_modules\/playwright-core\/index.js\" <<'PWJS'$/,/^PWJS$/p" tests/browser_plugin_unit.sh \
  | sed '1d;$d' > "$PWROOT/node_modules/playwright-core/base.js"
arm 'C0 (anchor) the main suite'"'"'s stub was extracted' yes \
  "$(grep -q 'launchPersistentContext' "$PWROOT/node_modules/playwright-core/base.js" && echo yes || echo no)"
cat > "$PWROOT/node_modules/playwright-core/index.js" <<'PWJS'
const base = require('./base.js');
const fs = require('fs');
const rec = (o) => fs.appendFileSync(process.env.PWREC, JSON.stringify(o) + '\n');
let patched = null;
const patch = (page) => {
  if (patched === page) return;
  patched = page;
  const fns = [];
  const on = page.on, off = page.off, click = page.click;
  page.on = (ev, fn) => (ev === 'popup' ? fns.push(fn) : on(ev, fn));
  page.off = (ev, fn) => { if (ev === 'popup') { const i = fns.indexOf(fn); if (i >= 0) fns.splice(i, 1); } else off(ev, fn); };
  page.click = async (sel, o) => {
    await click(sel, o);
    const spec = process.env.PWPOPUP ? JSON.parse(process.env.PWPOPUP) : null;
    if (!spec || sel !== spec.on) return;
    let closed = false;
    const p = Object.assign(Object.create(page), {
      on: () => {}, off: () => {}, setDefaultTimeout: () => {},
      isClosed: () => closed,
      waitForLoadState: async () => rec({ call: 'popupLoad', url: spec.url }),
      url: () => spec.url,
      title: async () => spec.title,
      content: async () => spec.html,
      goto: async (url) => rec({ call: 'goto', url, popup: true }),
      click: async (s) => { rec({ call: 'click', sel: s, popup: true }); if (spec.close_on_click) closed = true; },
      screenshot: async (o) => { rec({ call: 'screenshot', popup: true });
        if (o && o.path) { fs.writeFileSync(o.path, 'popup-png'); return; } return Buffer.from('popup-png'); },
    });
    rec({ call: 'popupOpened', url: spec.url });
    for (const fn of fns.slice()) fn(p);
  };
};
exports.chromium = {
  launchPersistentContext: async (profile, opts) => {
    const ctx = await base.chromium.launchPersistentContext(profile, opts);
    for (const p of ctx.pages()) patch(p);
    return ctx;
  },
};
PWJS
export NODE_PATH="$PWROOT/node_modules"
export PWREC="$TMP/pw.jsonl"; : > "$PWREC"
export PWWALK="$TMP/walk.json"; printf '{"nodes":[],"marker":"m-1"}' > "$PWWALK"
export PWTITLE='Gamma sign up' PWHTML='<html><body>opener: Continue with Google</body></html>'

URL="https://gamma.test/signup"
GURL="https://login.example.test/oauth/authorize?client_id=gamma"
POP="$(jq -nc --arg u "$GURL" '{on:"#google", url:$u, title:"Sign in - Example ID",
  html:"<html><body>popup: Choose an account</body></html>"}')"
CLICK='[{"op":"click","selector":"#google"}]'

run env PWPOPUP="$POP" "$BROWSER" act "$URL" --steps="$CLICK" --out="$TMP/c1"
arm 'C1a act exits 0' 0 "$RC"
[[ "$RC" == 0 ]] || gha 'C1 act output' "$OUT $ERR"
arm 'C1b the re-read is the popup: its url and title are the act'"'"'s' "$GURL|Sign in - Example ID" \
  "$(jq -r '"\(.url)|\(.title)"' "$TMP/c1/after.json" 2>/dev/null)"
arm 'C1c ...page.html and page.png are the popup'"'"'s' 'yes popup-png' \
  "$(has 'popup: Choose an account' "$(cat "$TMP/c1/page.html" 2>/dev/null)") $(cat "$TMP/c1/page.png" 2>/dev/null)"
arm 'C1d the output says a popup opened, and that this browser closed with it' 'yes yes' \
  "$(has 'a popup opened: login.example.test, now in view' "$OUT") $(has 'does not carry over' "$OUT")"
arm 'C1e page.meta.json carries the popup and browser_mode' "login.example.test|headless|act" \
  "$(jq -r '"\(.popup.host)|\(.browser_mode)|\(.capture)"' "$TMP/c1/page.meta.json" 2>/dev/null)"

run env PWPOPUP="$POP" "$BROWSER" act "$URL" --json \
  --steps='[{"op":"click","selector":"#google"},{"op":"click","selector":"#use-alex"}]' --out="$TMP/c2"
arm 'C2a a step after the popup opened acts IN the popup' '{"call":"click","sel":"#use-alex","popup":true}' \
  "$(grep -F '"#use-alex"' "$PWREC" | tail -1)"
arm 'C2b --json carries popup and browser_mode' 'login.example.test headless' \
  "$(jq -r '"\(.popup.host) \(.browser_mode)"' <<<"$OUT" 2>/dev/null)"

: > "$PWREC"
run env PWPOPUP="$(jq -c '. + {close_on_click:true}' <<<"$POP")" "$BROWSER" act "$URL" \
  --steps='[{"op":"click","selector":"#google"},{"op":"click","selector":"#use-alex"}]' --out="$TMP/c3"
arm 'C3a a popup that closes on its own click: the re-read is the opener again' "$URL" \
  "$(jq -r .url "$TMP/c3/after.json" 2>/dev/null)"
arm 'C3b ...and the output says it closed, with no popup line after the verdict' 'yes no' \
  "$(has 'the popup (login.example.test) closed; back on gamma.test' "$ERR") $(has 'now in view (page.png' "$OUT")"

run "$BROWSER" act "$URL" --steps="$CLICK" --out="$TMP/c4"
arm 'C4a (control) a click that opens nothing: the opener, no popup line' "$URL no" \
  "$(jq -r .url "$TMP/c4/after.json" 2>/dev/null) $(has 'a popup opened' "$OUT$ERR")"
arm 'C4b (control) ...and browser_mode is on the act'"'"'s page.meta.json, no popup key' 'headless null' \
  "$(jq -r '"\(.browser_mode) \(.popup)"' "$TMP/c4/page.meta.json" 2>/dev/null)"

# THE POPUP GETS THE SAME GUARD AS ANY PAGE: Google's chooser with no saved
# account, opened as a popup, is the hard stop it is in the main tab (DIVE-6228).
# Before this row the guard never saw it, because the loop never looked there.
GPOP="$(jq -nc '{on:"#google", url:"https://accounts.google.com/v3/signin/accountchooser?client_id=gamma",
  title:"Sign in - Google Accounts", html:"<html><body><h1>Choose an account</h1><div role=\"link\">Use another account</div></body></html>"}')"
run env PWPOPUP="$GPOP" "$BROWSER" act "$URL" \
  --steps='[{"op":"click","selector":"#google"},{"op":"click","selector":"#use-another"}]' --out="$TMP/c5"
arm 'C5 a Google chooser in the popup with no saved account: the guard stops there, the step after is not run' '75 yes no' \
  "$RC $(has "STOP: Google's chooser has no saved account" "$ERR") $(grep -cF '"#use-another"' "$PWREC" | sed 's/^0$/no/;s/^[1-9].*/yes/')"

# MUTANT: the one-shot loop never follows, which is 1.45.0's loop. A whole copy
# of the plugin, because the script finds its driver and lib/ beside itself.
cp -r "$ROOT/browser" "$TMP/mut1"
sed -i 's/page = await pop.sync(lastOp);/void 0;/; s/page = await pop.sync(resolved\[at\]/void (resolved[at]/' "$TMP/mut1/bin/driver-playwright"
arm 'M1 (anchor) mutant applied' 0 "$(grep -c 'page = await pop.sync' "$TMP/mut1/bin/driver-playwright")"
run env PWPOPUP="$POP" "$TMP/mut1/bin/browser" act "$URL" --steps="$CLICK" --out="$TMP/m1"
arm 'M1 MUTANT (no follow): the re-read stays on the opener (C1 goes red)' "$URL no" \
  "$(jq -r .url "$TMP/m1/after.json" 2>/dev/null) $(has 'a popup opened' "$OUT")"

# ================================================================ S  served
DAEMON="$ROOT/browser/bin/session-daemon"
SPROF="$TMP/served"; mkdir -p "$SPROF"; chmod 700 "$SPROF"
SOCK="$TMP/s.sock"
FIVEDIVE_BROWSER_CHROME="$FAKEBIN/google-chrome" PWPOPUP="$POP" node "$DAEMON" serve "$SPROF" "$SOCK" > "$TMP/s.ready" 2> "$TMP/s.err" &
_KILL+=($!)
for _ in $(seq 50); do grep -q '^ready' "$TMP/s.ready" 2>/dev/null && break; sleep 0.1; done
arm 'S0 (anchor) the served daemon is up on the stub' yes "$(grep -q '^ready' "$TMP/s.ready" && echo yes || { cat "$TMP/s.err" >&2; echo no; })"
call() { node "$DAEMON" call "$SOCK" <<<"$1"; }
plan() { jq -nc --argjson s "$1" '{op:"plan", steps:$s, args:{}, literal:true, report:{tree:false}}'; }

: > "$PWREC"
run call "$(plan "$(jq -nc --arg u "$URL" '[{op:"goto",url:$u},{op:"click",selector:"#google"}]')")"
rep="$(grep -F '"act_report":true' <<<"$OUT" | tail -1)"
arm 'S1a served: the act_report is the popup, headed' "$GURL|login.example.test|headed" \
  "$(jq -r '"\(.url)|\(.popup.host)|\(.browser_mode)"' <<<"$rep" 2>/dev/null)"
arm 'S1b ...and the log says a popup opened' yes "$(has 'a popup opened: login.example.test, now in view' "$ERR")"

: > "$PWREC"
run call "$(plan "$(jq -nc --arg u "$GURL" '[{op:"goto",url:$u},{op:"click",selector:"#use-alex"}]')")"
arm 'S2a the next plan on the popup'"'"'s URL is not a reload of it' 'yes 0' \
  "$(has 'not reloaded' "$ERR") $(grep -c '"call":"goto"' "$PWREC")"
arm 'S2b ...and its click lands in the popup' '{"call":"click","sel":"#use-alex","popup":true}' \
  "$(grep -F '"#use-alex"' "$PWREC" | tail -1)"

: > "$PWREC"
run call "$(jq -nc --arg u "$GURL" '{op:"snapshot", url:$u, inline:true}')"
arm 'S3 a snapshot of that URL is read from the popup, not reloaded' "$GURL 0 headed" \
  "$(jq -r '.url' <<<"$OUT" 2>/dev/null) $(grep -c '"call":"goto"' "$PWREC") $(jq -r '.browser_mode' <<<"$OUT" 2>/dev/null)"

: > "$PWREC"
run call "$(plan '[{"op":"click","selector":"#use-alex"}]')"
arm 'S2c a plan with no URL continues in the popup' '{"call":"click","sel":"#use-alex","popup":true}' \
  "$(grep -F '"#use-alex"' "$PWREC" | tail -1)"

: > "$PWREC"
run call "$(plan "$(jq -nc '[{op:"goto",url:"https://gamma.test/home"},{op:"click",selector:"#menu"}]')")"
arm 'S4 a plan on the opener'"'"'s site goes to the main tab' '{"call":"goto","url":"https://gamma.test/home"} {"call":"click","sel":"#menu"}' \
  "$(grep -F '"goto"' "$PWREC" | tail -1) $(grep -F '"#menu"' "$PWREC" | tail -1)"

# ================================================================ L  LIVE
REAL_CHROME="$(PATH="$REALPATH" command -v google-chrome || PATH="$REALPATH" command -v chromium || true)"
PW_OK=no; [[ -d "$ROOT/browser/node_modules/playwright-core" ]] && PW_OK=yes
if [[ -z "$REAL_CHROME" || "$PW_OK" != yes ]]; then
  SKIP=$((SKIP+1)); printf 'SKIP: L live arms — chrome: %s, playwright-core next to the plugin: %s\n' "${REAL_CHROME:-none}" "$PW_OK"
else
  # The shape of a "Continue with Google" button: window.open from the click, a
  # chooser in the new window, and a choice that changes what the chooser shows.
  cat > "$TMP/site.cjs" <<'JS'
const http = require('http');
http.createServer((req, res) => {
  res.setHeader('content-type', 'text/html');
  if (req.url.startsWith('/chooser')) {
    res.end('<html><head><title>Choose an account</title></head><body><h1>Choose an account</h1>' +
      '<button id="pick" onclick="document.body.insertAdjacentHTML(\'beforeend\', \'<p>picked alex</p>\')">alex@example.com</button></body></html>');
    return;
  }
  res.end('<html><head><title>Sign up</title></head><body><h1>Sign up</h1>' +
    '<button id="google" onclick="window.open(\'/chooser?client=fixture\', \'g\', \'width=480,height=600\')">Continue with Google</button></body></html>');
}).listen(0, '127.0.0.1', function () { console.log(this.address().port); });
JS
  node "$TMP/site.cjs" > "$TMP/port" & _KILL+=($!)
  for _ in $(seq 50); do [[ -s "$TMP/port" ]] && break; sleep 0.1; done
  PORT="$(cat "$TMP/port")"
  live() { env -u NODE_PATH -u PWWALK -u PWTITLE -u PWHTML -u FIVEDIVE_BROWSER_DRIVER -u FIVEDIVE_BROWSER_HEADLESS \
    PATH="$REALPATH" FIVEDIVE_BROWSER_RUN_SETTLE_MS=300 FIVEDIVE_BROWSER_POPUP_WAIT_MS=3000 "$@"; }
  run live "$BROWSER" act "http://localhost:$PORT/" --steps='[{"op":"click","selector":"#google"}]' --out="$TMP/l1"
  arm 'L1a act in real Chrome exits 0' 0 "$RC"
  [[ "$RC" == 0 ]] || gha 'L1 act output' "$OUT $ERR"
  arm 'L1b the re-read is the popup (the chooser)' "Choose an account|yes" \
    "$(jq -r '.title' "$TMP/l1/after.json" 2>/dev/null)|$(has '/chooser?client=fixture' "$(jq -r .url "$TMP/l1/after.json" 2>/dev/null)")"
  # after.json, not page.meta.json: a served act derives page.md and its meta only for --full (DIVE-6795).
  arm 'L1c the output says so, and after.json names the popup and a browser mode' 'yes yes' \
    "$(has 'a popup opened: localhost' "$OUT") $(jq -r 'if .popup.url and (.browser_mode == "headed" or .browser_mode == "headless") then "yes" else "no" end' "$TMP/l1/after.json" 2>/dev/null)"
  run live "$BROWSER" act "http://localhost:$PORT/" --expect='picked alex' \
    --steps='[{"op":"click","selector":"#google"},{"op":"click","selector":"#pick"}]' --out="$TMP/l2"
  arm 'L2 a second step clicks inside the popup, and its effect is what the act verifies' '0 yes' \
    "$RC $(has 'verified' "$OUT")"
  [[ "$RC" == 0 ]] || gha 'L2 act output' "$OUT $ERR"
  run live "$TMP/mut1/bin/browser" act "http://localhost:$PORT/" --steps='[{"op":"click","selector":"#google"}]' --out="$TMP/l3"
  arm 'L3 MUTANT (no follow, 1.45.0'"'"'s loop) in real Chrome: the re-read stays on the opener' 'Sign up' \
    "$(jq -r '.title' "$TMP/l3/after.json" 2>/dev/null)"
fi

printf '\n%d pass, %d fail, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
