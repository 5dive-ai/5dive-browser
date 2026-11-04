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
#   W  DIVE-7680 (box bug 690): windows no page 'popup' event reports, late ones,
#      and a page that moves during the report
#      U6  a CONTEXT page during an act (a cross-origin iframe's window.open) is taken
#      U7  a context page outside an act, or after its late window, is not
#      U8  a tab this code opened itself (mine()) is never taken
#      U9  a popup after the wait: waiting, and drain() takes it with no wait
#      U10 one window reported both ways is taken once
#      C6  cold act: a click whose window arrives only as a context page -> the re-read is it
#      C7  cold act: the page moves between the read and the picture -> read again, url = png's page
#      S5  served: the same context-only window -> act_report is it
#      S6  served: a popup 0.8 s after the act -> the next no-URL snapshot is it
#      S7  served: the page moves during the report -> url and png agree, and it is said
#      M2-M4 MUTANTS: no context listener (C6, S5 red), no drain (S6 red), no re-read (C7 red)
#   L  LIVE, where this machine has Chrome and playwright-core (CI installs it): a
#      local page whose button opens a popup with window.open
#      L1 `act` clicks it in real Chrome: the re-read is the popup page
#      L2 a second step clicks a button inside the popup, and its effect shows
#      L3 MUTANT (no follow, 1.45.0's behaviour) in real Chrome: the re-read
#         stays on the opener — the negative control for L1
#      L4 (DIVE-7680) the button inside a cross-origin iframe opens the window:
#         the re-read is that window
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

# ---- W (DIVE-7680): the context, late windows. A fake context that is an EventEmitter.
w="$(FIVEDIVE_BROWSER_POPUP_WAIT_MS=200 FIVEDIVE_BROWSER_POPUP_LATE_MS=300 node -e '
const pop=require(process.argv[1]), F=require(process.argv[2]); const { EventEmitter } = require("events");
const sleep=(ms)=>new Promise(r=>setTimeout(r,ms)); const out={};
(async () => {
  const mk=()=>{ const c=new EventEmitter(); const a=F.page("https://shop.test/apps/facebook"); a.context=()=>c; c.pages=()=>[a]; return {c,a}; };
  // U6: a context page during the act, no popup event (the iframe case)
  { const {c,a}=mk(); const lines=[]; const f=pop.follow(a,{log:(l)=>lines.push(l)});
    await f.sync(null);
    const m=F.page("https://www.facebook.test/login"); setTimeout(()=>c.emit("page",m),20);
    const p=await f.sync("click"); out.u6=(p===m)+" "+(f.popup&&f.popup.host)+" "+lines.some(l=>l.includes("a popup opened: www.facebook.test")); f.stop(); }
  // U7: before any act, and after the late window
  { const {c,a}=mk(); const f=pop.follow(a,{});
    const m=F.page("https://other.test/"); c.emit("page",m); await sleep(80); const p1=await f.sync(null);
    await sleep(400); const m2=F.page("https://other2.test/"); c.emit("page",m2); await sleep(80); const p2=await f.drain();
    out.u7=(p1===a)+" "+(p2===a)+" "+f.waiting; f.stop(); }
  // U8: a tab this code opened
  { const {c,a}=mk(); const f=pop.follow(a,{}); await f.sync(null);
    const m=F.page("https://read.test/"); c.emit("page",m); pop.mine(m); const p=await f.sync("click");
    out.u8=(p===a)+""; f.stop(); }
  // U9: a popup after the wait
  { const {c,a}=mk(); const f=pop.follow(a,{}); await f.sync(null);
    const g=F.page("https://accounts.google.test/chooser"); setTimeout(()=>a.emit("popup",g),350);
    const p1=await f.sync("click"); await sleep(400); const w1=f.waiting; const t=Date.now(); const p2=await f.drain();
    out.u9=(p1===a)+" "+w1+" "+(p2===g)+" "+(Date.now()-t<150)+" "+(f.pageFor(null)===g); f.stop(); }
  // U10: both events for one window
  { const {c,a}=mk(); const lines=[]; const f=pop.follow(a,{log:(l)=>lines.push(l)}); await f.sync(null);
    const g=F.page("https://accounts.google.test/x"); setTimeout(()=>{ a.emit("popup",g); c.emit("page",g); },20);
    await f.sync("click"); await sleep(120); await f.drain();
    out.u10=lines.filter(l=>l.includes("a popup opened")).length+" "+(f.page===g); f.stop(); }
  console.log(JSON.stringify(out));
})();' "$LIB" "$TMP/fake.cjs")"
arm 'U6 a context page during an act (no popup event) is taken into view, and said' 'true www.facebook.test true' "$(jq -r .u6 <<<"$w")"
arm 'U7 a context page outside an act, or after the late window, is not taken' 'true true false' "$(jq -r .u7 <<<"$w")"
arm 'U8 a tab this code opened itself (mine) is never taken' true "$(jq -r .u8 <<<"$w")"
arm 'U9 a popup after the wait waits; drain() takes it at once and pageFor() hands it out' 'true true true true true' "$(jq -r .u9 <<<"$w")"
arm 'U10 one window reported as a popup AND a context page is taken once' '1 true' "$(jq -r .u10 <<<"$w")"

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
// DIVE-7680: the context's 'page' listeners. A real popup is reported both ways;
// via:"context" reports it ONLY there (a window a cross-origin iframe opens), and
// late_ms reports it that long after the click.
const ctxFns = [];
let theCtx = null;
const patch = (page) => {
  if (patched === page) return;
  patched = page;
  page.context = () => theCtx;
  const fns = [];
  const on = page.on, off = page.off, click = page.click;
  page.on = (ev, fn) => (ev === 'popup' ? fns.push(fn) : on(ev, fn));
  page.off = (ev, fn) => { if (ev === 'popup') { const i = fns.indexOf(fn); if (i >= 0) fns.splice(i, 1); } else off(ev, fn); };
  page.click = async (sel, o) => {
    await click(sel, o);
    const spec = process.env.PWPOPUP ? JSON.parse(process.env.PWPOPUP) : null;
    if (!spec || sel !== spec.on) return;
    let closed = false, moved = false;
    // move_on_shot: the page goes on to spec.url2 as its picture is taken (the
    // report read its url before; DIVE-7680 case 1).
    const here = () => (moved ? spec.url2 : spec.url);
    const p = Object.assign(Object.create(page), {
      on: () => {}, off: () => {}, setDefaultTimeout: () => {},
      isClosed: () => closed,
      waitForLoadState: async () => rec({ call: 'popupLoad', url: spec.url }),
      url: () => here(),
      title: async () => (moved ? spec.title2 : spec.title),
      content: async () => (moved ? spec.html2 : spec.html),
      goto: async (url) => rec({ call: 'goto', url, popup: true }),
      click: async (s) => { rec({ call: 'click', sel: s, popup: true }); if (spec.close_on_click) closed = true; },
      screenshot: async (o) => { rec({ call: 'screenshot', popup: true, url: here() });
        const png = moved ? 'moved-png' : 'popup-png';
        if (spec.move_on_shot) moved = true;
        const now = moved ? 'moved-png' : png;
        if (o && o.path) { fs.writeFileSync(o.path, now); return; } return Buffer.from(now); },
    });
    const fire = () => {
      rec({ call: 'popupOpened', url: spec.url, via: spec.via || 'popup' });
      if (spec.via !== 'context') for (const fn of fns.slice()) fn(p);
      for (const fn of ctxFns.slice()) fn(p);
    };
    if (spec.late_ms) setTimeout(fire, spec.late_ms); else fire();
  };
};
exports.chromium = {
  launchPersistentContext: async (profile, opts) => {
    const ctx = await base.chromium.launchPersistentContext(profile, opts);
    ctx.on = (ev, fn) => { if (ev === 'page') ctxFns.push(fn); };
    ctx.off = (ev, fn) => { if (ev === 'page') { const i = ctxFns.indexOf(fn); if (i >= 0) ctxFns.splice(i, 1); } };
    theCtx = ctx;
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

# ---- DIVE-7680, cold. Meta's login opened from Shopify's embedded app (a
# cross-origin iframe) reaches Playwright only as a page of the context.
MURL="https://www.facebook.test/login?app=shopify"
CPOP="$(jq -nc --arg u "$MURL" '{on:"#connect", url:$u, title:"Log in to Facebook", via:"context",
  html:"<html><body>popup: Log in to Facebook</body></html>"}')"
: > "$PWREC"
run env PWPOPUP="$CPOP" "$BROWSER" act "$URL" --steps='[{"op":"click","selector":"#connect"}]' --out="$TMP/c6"
arm 'C6 a window that arrives only as a context page: the re-read is it, and it is said' "$MURL|Log in to Facebook|yes" \
  "$(jq -r '"\(.url)|\(.title)"' "$TMP/c6/after.json" 2>/dev/null)|$(has 'a popup opened: www.facebook.test' "$OUT$ERR")"
# The page goes on to Google's chooser between the read and the picture.
G2="https://accounts.google.test/v3/signin/accountchooser?x=1"
MPOP="$(jq -nc --arg u "$GURL" --arg u2 "$G2" '{on:"#google", url:$u, title:"Loading", html:"<html><body>loading</body></html>",
  move_on_shot:true, url2:$u2, title2:"Choose an account", html2:"<html><body>Choose an account</body></html>"}')"
run env PWPOPUP="$MPOP" "$BROWSER" act "$URL" --steps="$CLICK" --out="$TMP/c7"
arm 'C7 the page moved between the read and the picture: read again, url/title/html are the picture'"'"'s page' \
  "$G2|Choose an account|yes|moved-png|yes" \
  "$(jq -r '"\(.url)|\(.title)"' "$TMP/c7/after.json" 2>/dev/null)|$(has 'Choose an account' "$(cat "$TMP/c7/page.html" 2>/dev/null)")|$(cat "$TMP/c7/page.png" 2>/dev/null)|$(has 'the page moved while it was being read' "$OUT$ERR")"

# MUTANT: the one-shot loop never follows, which is 1.45.0's loop. A whole copy
# of the plugin, because the script finds its driver and lib/ beside itself.
cp -r "$ROOT/browser" "$TMP/mut1"
sed -i 's/page = await pop.sync(lastOp);/void 0;/; s/page = await pop.sync(resolved\[at\]/void (resolved[at]/; s/if (pop \&\& pop.waiting) {/if (false) {/' "$TMP/mut1/bin/driver-playwright"
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

# ---- DIVE-7680, served. One daemon per arm: PWPOPUP is read at each click, but
# the daemon is started with its env.
served() {  # served <name> <PWPOPUP> -> SOCK set, daemon up
  local d="$TMP/$1"; mkdir -p "$d/prof"; chmod 700 "$d/prof"; SOCK="$d/s.sock"
  FIVEDIVE_BROWSER_CHROME="$FAKEBIN/google-chrome" PWPOPUP="$2" node "${3:-$DAEMON}" serve "$d/prof" "$SOCK" > "$d/ready" 2> "$d/err" &
  _KILL+=($!)
  for _ in $(seq 50); do grep -q '^ready' "$d/ready" 2>/dev/null && break; sleep 0.1; done
}
shotplan() { jq -nc --argjson s "$1" '{op:"plan", steps:$s, args:{}, literal:true, report:{tree:false, shot:true}}'; }

served s5 "$CPOP"
run call "$(plan "$(jq -nc --arg u "$URL" '[{op:"goto",url:$u},{op:"click",selector:"#connect"}]')")"
rep="$(grep -F '"act_report":true' <<<"$OUT" | tail -1)"
arm 'S5 served: a window that arrives only as a context page is the act_report' "$MURL|www.facebook.test" \
  "$(jq -r '"\(.url)|\(.popup.host)"' <<<"$rep" 2>/dev/null)"

LPOP="$(jq -nc --arg u "$GURL" '{on:"#google", url:$u, title:"Choose an account", late_ms:800,
  html:"<html><body>popup: Choose an account</body></html>"}')"
served s6 "$LPOP"
run call "$(plan "$(jq -nc --arg u "$URL" '[{op:"goto",url:$u},{op:"click",selector:"#google"}]')")"
rep="$(grep -F '"act_report":true' <<<"$OUT" | tail -1)"
arm 'S6a (anchor) a popup 0.8 s after the click is not in the act_report (the wait is 0.3 s)' "null" \
  "$(jq -r '.popup' <<<"$rep" 2>/dev/null)"
sleep 1
: > "$PWREC"
run call "$(jq -nc --arg u "$URL" '{op:"snapshot", url:$u, inline:true}')"
# (a snapshot with no URL sends the last act's URL: the opener's)
arm 'S6b the next snapshot with no URL reads the late popup, not the page under it, and says so' "$GURL|login.example.test|0|yes" \
  "$(jq -r '"\(.url)|\(.popup.host)"' <<<"$OUT" 2>/dev/null)|$(grep -c '"call":"goto"' "$PWREC")|$(has 'a popup opened after the last act' "$ERR")"
run call "$(plan "$(jq -nc '[{op:"goto",url:"https://gamma.test/signup"},{op:"click",selector:"#menu"}]')")"
arm 'S6c ...and an act that names the opener'"'"'s URL still goes to the opener' '{"call":"click","sel":"#menu"}' \
  "$(grep -F '"#menu"' "$PWREC" | tail -1)"

served s7 "$MPOP"
run call "$(shotplan "$(jq -nc --arg u "$URL" '[{op:"goto",url:$u},{op:"click",selector:"#google"}]')")"
rep="$(grep -F '"act_report":true' <<<"$OUT" | tail -1)"
arm 'S7 served: the page moved during the report: url, title and png are one page, and it is said' \
  "$G2|Choose an account|$(printf moved-png | base64)|yes" \
  "$(jq -r '"\(.url)|\(.title)|\(.png_b64)"' <<<"$rep" 2>/dev/null)|$(has 'the page moved while it was being read' "$ERR")"

# MUTANTS, each a copy of the plugin with one part of the fix taken out.
cp -r "$ROOT/browser" "$TMP/mut2"
sed -i "s/  if (ctx) ctx.on('page', onCtxPage);/  void onCtxPage;/" "$TMP/mut2/lib/popup.cjs"
arm 'M2 (anchor) mutant applied: no context listener' 0 "$(grep -c "ctx.on('page'" "$TMP/mut2/lib/popup.cjs")"
run env PWPOPUP="$CPOP" "$TMP/mut2/bin/browser" act "$URL" --steps='[{"op":"click","selector":"#connect"}]' --out="$TMP/m2"
arm 'M2 MUTANT (no context listener): C6 goes red, the re-read stays on the opener' "$URL" \
  "$(jq -r .url "$TMP/m2/after.json" 2>/dev/null)"
served m2s "$CPOP" "$TMP/mut2/bin/session-daemon"
run call "$(plan "$(jq -nc --arg u "$URL" '[{op:"goto",url:$u},{op:"click",selector:"#connect"}]')")"
arm 'M2s MUTANT (no context listener): S5 goes red, popup null' null \
  "$(grep -F '"act_report":true' <<<"$OUT" | tail -1 | jq -r '.popup' 2>/dev/null)"

cp -r "$ROOT/browser" "$TMP/mut3"
sed -i 's/    try { await front.drain(); } catch (e) {/    try { void 0; } catch (e) {/' "$TMP/mut3/bin/session-daemon"
arm 'M3 (anchor) mutant applied: pageFor does not drain' 0 "$(grep -c 'await front.drain(); } catch (e) { /\* the page in view' "$TMP/mut3/bin/session-daemon")"
served m3s "$LPOP" "$TMP/mut3/bin/session-daemon"
run call "$(plan "$(jq -nc --arg u "$URL" '[{op:"goto",url:$u},{op:"click",selector:"#google"}]')")"
sleep 1
run call "$(jq -nc --arg u "$URL" '{op:"snapshot", url:$u, inline:true}')"
arm 'M3 MUTANT (no drain): S6b goes red, the snapshot reads the opener' "$URL" "$(jq -r '.url' <<<"$OUT" 2>/dev/null)"

cp -r "$ROOT/browser" "$TMP/mut4"
sed -i 's/const moved = aria.movedSince(page, after);/const moved = null;/' "$TMP/mut4/bin/driver-playwright" "$TMP/mut4/bin/session-daemon"
arm 'M4 (anchor) mutant applied: no re-read when the page moved' 0 "$(cat "$TMP/mut4/bin/driver-playwright" "$TMP/mut4/bin/session-daemon" | grep -c 'aria.movedSince(page, after)')"
run env PWPOPUP="$MPOP" "$TMP/mut4/bin/browser" act "$URL" --steps="$CLICK" --out="$TMP/m4"
arm 'M4 MUTANT (no re-read): C7 goes red, after.json is the page before the picture' "$GURL" \
  "$(jq -r .url "$TMP/m4/after.json" 2>/dev/null)"

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
http.createServer(function (req, res) {
  res.setHeader('content-type', 'text/html');
  if (req.url.startsWith('/chooser')) {
    res.end('<html><head><title>Choose an account</title></head><body><h1>Choose an account</h1>' +
      '<button id="pick" onclick="document.body.insertAdjacentHTML(\'beforeend\', \'<p>picked alex</p>\')">alex@example.com</button></body></html>');
    return;
  }
  // DIVE-7680: an embedded app on ANOTHER SITE (127.0.0.1 vs localhost: two sites,
  // so Chrome puts the frame in its own process) whose button opens the window.
  if (req.url.startsWith('/shop')) {
    res.end('<html><head><title>Shop admin</title></head><body><h1>Apps</h1>' +
      '<iframe id="app" title="Facebook app" src="http://127.0.0.1:' + this.address().port + '/app" width="400" height="200"></iframe></body></html>');
    return;
  }
  if (req.url.startsWith('/app')) {
    res.end('<html><body><button id="connect" onclick="window.open(\'http://localhost:' + this.address().port +
      '/chooser?client=iframe\', \'m\', \'width=480,height=600\')">Connect Facebook account</button></body></html>');
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
  # L4 (DIVE-7680 case 2): the button is inside a cross-origin iframe, as Shopify's
  # embedded Facebook app. Run with --json so the popup host is read off the output.
  run live "$BROWSER" act "http://localhost:$PORT/shop" \
    --steps='[{"op":"click","selector":"ref=frame:Facebook app >> button/Connect Facebook account"}]' --out="$TMP/l4"
  arm 'L4 a window opened from a cross-origin iframe: the re-read is it' "Choose an account|yes" \
    "$(jq -r '.title' "$TMP/l4/after.json" 2>/dev/null)|$(has 'client=iframe' "$(jq -r .url "$TMP/l4/after.json" 2>/dev/null)")"
  [[ "$(jq -r '.title' "$TMP/l4/after.json" 2>/dev/null)" == 'Choose an account' ]] || gha 'L4 act output' "$OUT $ERR"
fi

printf '\n%d pass, %d fail, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
