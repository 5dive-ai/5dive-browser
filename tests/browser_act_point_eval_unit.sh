#!/usr/bin/env bash
# DIVE-8241 — an act's two fallbacks: a click by position on a normal page, and a
# read-only page script.
#
# WHY: in the 7-agent bench (DIVE-7804) BrowserOS clicked at screenshot coordinates in
# 22 of 100 runs (in 9 of the 18 tasks it won and 5dive lost) and ran page JavaScript
# 216 times; 5dive had coordinates only in input mode, and 31 of its clicks died on a
# covered or off-window control (bench/matrix-7804-2026-11-07/BROWSEROS-EDGE.md).
#
#   U  no browser: lib/point.cjs, the executor's vocabulary, bin/browser's checks
#      U1 a step by position needs x and y as numbers from 0; type_at needs a value and
#         refuses a line break (Enter is the owner's to read); eval needs an expression
#         of at most 4000 characters
#      U2 an adapter's recipe (an unguarded plan) refuses click_at and eval as outside
#         the fixed vocabulary: `run` keeps "no eval, no script"
#      U3 bin/browser: the act vocabulary names the four; the ADAPTER vocabulary is
#         unchanged; --record of a step by position is refused; eval in an act that
#         types a saved login is refused; nothing ran in any of them
#   L  LIVE, where this machine has Chrome and playwright-core (CI installs it): a local
#      page, the real bin/browser and driver-playwright
#      L1  click_at on a control that is in no map (a bare div) clicks it: the page
#          sees the click, and the act says what the point landed on
#      L2  THE OWNER'S GATE: click_at over "Place order" stops with exit 73, names pay,
#          and the page never sees the click
#      L3  a point on what cannot be read (a closed shadow root) is the strictest kind:
#          exit 73 as pay, no click
#      L4  click_at on a text field is not classified: it runs
#      L5  hover_at opens a menu that opens on mouseover
#      L6  type_at types into the field the click focused; eval reads it back
#      L7  type_at whose click focuses no field types nothing and fails
#      L8  a point outside the window is refused before anything runs on it
#      L9  eval returns the page's embedded JSON and a hidden control's text
#      L10 eval that CLICKS is refused, and the page never sees the click
#      L11 eval that NAVIGATES (location, history, window.open) is refused; the page stays
#      L12 eval that fetches or writes the page is refused
#      L13 eval reads document.cookie as "", and the page's own cookie is back after it
#      L14 eval on a page whose password field holds a value is refused
#      L15 eval that never ends is stopped at its bound
#      L16 a huge answer is cut, and says its full size
#      L17 a click_at that opens a popup is followed, as a ref click is
#   M  MUTANTS (live): the gate removed -> L2 goes red (the page gets the pay click);
#      the side-effect check removed -> L10 goes red (the page gets the click)
#   S  SERVED, where Xvfb is present too: the same steps through bin/session-daemon
#      S1 click_at over "Place order": the plan stops for the owner, no click
#      S2 eval reads the embedded JSON; S3 eval that clicks is refused
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
DRIVER="$ROOT/browser/bin/driver-playwright"
DAEMON="$ROOT/browser/bin/session-daemon"
LIB="$ROOT/browser/lib/point.cjs"

TMP="$(mktemp -d /tmp/d8241.XXXXXX)"
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

# ================================================================ U  no browser
U1="$(node -e '
const p = require(process.argv[1]);
const t = (s) => { try { p.validate(s, 1); return "ok"; } catch (e) { return "no"; } };
console.log([
  t({ op: "click_at", x: 10, y: 20 }), t({ op: "click_at", x: 10 }), t({ op: "click_at", x: -1, y: 2 }),
  t({ op: "click_at", x: "10", y: 2 }), t({ op: "hover_at", x: 0, y: 0 }),
  t({ op: "type_at", x: 1, y: 1, value: "abc" }), t({ op: "type_at", x: 1, y: 1 }), t({ op: "type_at", x: 1, y: 1, value: "a\nb" }),
  t({ op: "eval", expr: "document.title" }), t({ op: "eval", expr: "  " }), t({ op: "eval", expr: "x".repeat(4001) }),
].join(" "));' "$LIB" 2>&1)"
arm 'U1 position steps need numeric x,y; type_at a value with no line break; eval an expression of at most 4000 chars' \
  'ok no no no ok ok no no ok no no' "$U1"

SEAT="$(id -un)"
export FIVEDIVE_BROWSER_TMP_ROOT="$TMP/tmproot"
export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/profiles"
export FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/adapters"; mkdir -p "$FIVEDIVE_BROWSER_ADAPTER_DIR"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/sessions"
export FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/no-session-daemon"
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli"
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
export FIVEDIVE_BROWSER_APPROVAL_DIR="$TMP/approvals" FIVEDIVE_BROWSER_APPROVAL_POLICY="$TMP/policy.json"
export FIVEDIVE_BROWSER_GRANT_UID="$(id -u)" FIVEDIVE_BROWSER_TREE_SETTLE_MS=0
export FIVEDIVE_BROWSER_EXPECT_WAIT_MS=0 FIVEDIVE_BROWSER_POPUP_WAIT_MS=2000
mkdir -p "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT"
chmod 711 "$FIVEDIVE_BROWSER_PROFILE_ROOT"; chmod 700 "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT"

# U2: the executor, handed a recipe (no guard) with the new steps, refuses them as
# outside the vocabulary before any browser opens. A guarded plan with a bad x is
# refused by the same check, also before the browser.
PROF="$TMP/uprof"; mkdir -p "$PROF"; chmod 700 "$PROF"
run env FIVEDIVE_BROWSER_PROFILE="$PROF" node "$DRIVER" <<<'{"steps":[{"op":"goto","url":"https://x.test/"},{"op":"click_at","x":1,"y":2}],"args":{}}'
arm 'U2a a recipe (unguarded) with click_at: refused as outside the fixed vocabulary, nothing ran (70)' '70 yes' \
  "$RC $(has "uses 'click_at', which is outside the fixed vocabulary" "$ERR")"
run env FIVEDIVE_BROWSER_PROFILE="$PROF" node "$DRIVER" <<<'{"steps":[{"op":"eval","expr":"document.title"}],"args":{}}'
arm 'U2b a recipe with eval: refused the same way (no eval in an adapter)' '70 yes' \
  "$RC $(has "uses 'eval', which is outside the fixed vocabulary" "$ERR")"
run env FIVEDIVE_BROWSER_PROFILE="$PROF" node "$DRIVER" <<<'{"guard":true,"literal":true,"steps":[{"op":"click_at","x":"a","y":2}],"args":{}}'
arm 'U2c an act plan with a bad x: refused before the browser, nothing ran' '70 yes' \
  "$RC $(has "needs 'x'" "$ERR")"

U3V="$(sed -n "s/^ACT_VOCAB='\(.*\)'$/\1/p" "$BROWSER")"
arm 'U3a the act vocabulary names click_at hover_at type_at eval' \
  'goto fill type click wait_for select press upload click_at hover_at type_at eval' "$U3V"
arm 'U3b the ADAPTER vocabulary is unchanged (no eval, no script, no position)' \
  'goto fill type click wait_for select upload press' "$(sed -n 's/^ADAPTER_STEPS="\(.*\)"$/\1/p' "$BROWSER")"
arm 'U3c the README still says adapters carry no eval and no script' yes \
  "$(grep -qiE 'no eval|no `eval`' "$ROOT/README.md" "$ROOT/browser/README.md" 2>/dev/null && echo yes || echo no)"
run "$BROWSER" act https://shop.example.test/ --steps='[{"op":"click_at","x":5,"y":5}]' --record=r1
arm 'U3d --record of an act with a step by position: refused, usage exit' '64 yes' \
  "$RC $(has 'not recorded as a routine' "$ERR")"
run "$BROWSER" act https://shop.example.test/ --steps='[{"op":"fill","selector":"ref=textbox/Email","saved":"shop.login"},{"op":"eval","expr":"1"}]'
arm 'U3e eval in an act that types a saved login: refused before anything opens' '64 yes' \
  "$RC $(has 'does not run in an act that types a saved login' "$ERR")"
run "$BROWSER" act https://shop.example.test/ --steps='[{"op":"script","expr":"1"}]'
arm 'U3f an op outside the act vocabulary is still refused' '64 yes' "$RC $(has "'script' is not an act step" "$ERR")"

# ================================================================ L  LIVE
REAL_CHROME="$(command -v google-chrome || command -v chromium || true)"
PW_OK=no; [[ -d "$ROOT/browser/node_modules/playwright-core" ]] && PW_OK=yes
if [[ -z "$REAL_CHROME" || "$PW_OK" != yes ]]; then
  SKIP=$((SKIP+1)); printf 'SKIP: L, M, S live arms — chrome: %s, playwright-core next to the plugin: %s\n' "${REAL_CHROME:-none}" "$PW_OK"
else
  HITS="$TMP/hits"; : > "$HITS"
  cat > "$TMP/site.cjs" <<'JS'
const http = require('http'), fs = require('fs');
const hits = process.argv[2];
// Everything at a fixed place, so a pixel of page.png is a known element (1280x800, scale 1).
const box = (l, t, w, h) => `position:absolute;left:${l}px;top:${t}px;width:${w}px;height:${h}px;`;
const hit = (what) => `fetch('/hit?${what}')`;
const PAGE = `<!doctype html><html><head><title>Point shop</title><style>body{margin:0;font:16px sans-serif}</style></head><body>
<div id="go" style="${box(100, 100, 120, 40)}background:#cde" onclick="${hit('go')};document.getElementById('st').textContent='opened by position'"></div>
<button id="pay" style="${box(300, 100, 160, 40)}" onclick="${hit('pay')}">Place order</button>
<pay-widget id="pw" style="${box(500, 100, 160, 40)}display:block;background:#fed"></pay-widget>
<input id="q" aria-label="Search" style="${box(100, 200, 200, 30)}">
<div id="menu" style="${box(400, 200, 100, 30)}background:#eee" onmouseover="document.getElementById('st').textContent='menu open: Gift cards'">Menu</div>
<div id="nofield" style="${box(100, 300, 120, 40)}background:#efe">Plain</div>
<button id="open" style="${box(300, 300, 160, 40)}" onclick="window.open('/popup','p','width=400,height=300')">Details</button>
<button id="cookie" style="${box(500, 300, 160, 40)}" onclick="fetch('/hit?c='+encodeURIComponent(document.cookie))">Check</button>
<div style="display:none" id="hid">Duration: 20+ minutes</div>
<p id="st" style="${box(100, 400, 600, 30)}">ready</p>
<script type="application/json" id="data">{"price":12,"items":["a","b","c"]}</script>
<script>
  document.cookie = 'sid=abc123; path=/';
  customElements.define('pay-widget', class extends HTMLElement { constructor() { super();
    const r = this.attachShadow({ mode: 'closed' }); r.innerHTML = '<button onclick="fetch(\\'/hit?shadowpay\\')" style="width:100%;height:100%">Pay now</button>'; } });
  window.big = 'x'.repeat(50000);
</script></body></html>`;
http.createServer((req, res) => {
  if (req.url.startsWith('/hit')) { fs.appendFileSync(hits, decodeURIComponent(req.url.slice(5)) + '\n'); res.end('ok'); return; }
  res.setHeader('content-type', 'text/html');
  if (req.url.startsWith('/popup')) { res.end('<html><head><title>Details window</title></head><body><h1>Details</h1></body></html>'); return; }
  if (req.url.startsWith('/login')) { res.end('<html><head><title>Sign in</title></head><body><input type=password id=pw value="hunter2"><p>sign in</p></body></html>'); return; }
  res.end(PAGE);
}).listen(0, '127.0.0.1', function () { console.log(this.address().port); });
JS
  node "$TMP/site.cjs" "$HITS" > "$TMP/port" & _KILL+=($!)
  for _ in $(seq 50); do [[ -s "$TMP/port" ]] && break; sleep 0.1; done
  PORT="$(cat "$TMP/port")"; U="http://localhost:$PORT/"
  live() { env -u NODE_PATH -u FIVEDIVE_BROWSER_DRIVER FIVEDIVE_BROWSER_RUN_SETTLE_MS=300 "$@"; }
  hits() { sleep 0.4; tr '\n' ' ' < "$HITS" | sed 's/ $//'; }
  act() { : > "$HITS"; run live "$BROWSER" act "$U" "$@"; }

  act --steps='[{"op":"click_at","x":160,"y":120}]' --expect='opened by position' --out="$TMP/l1"
  arm 'L1a click_at on a bare div (in no map) clicks it: exit 0, the page saw it' '0 go' "$RC $(hits)"
  [[ "$RC" == 0 ]] || gha 'L1 output' "$OUT $ERR"
  arm 'L1b the act says what the point landed on' yes "$(has 'clicked div#go' "$OUT$ERR")"

  act --steps='[{"op":"click_at","x":380,"y":120}]' --out="$TMP/l2"
  arm 'L2a click_at over "Place order": exit 73 (the owner'"'"'s), and the page never saw the click' '73 ' "$RC $(hits)"
  arm 'L2b ...the ask names pay and what was under the point' 'yes yes' \
    "$(has '"cls":"pay"' "$OUT$ERR") $(has 'Place order' "$OUT$ERR")"

  act --steps='[{"op":"click_at","x":580,"y":120}]' --out="$TMP/l3"
  arm 'L3 a point on a closed shadow root (cannot be read) is the strictest kind: 73 as pay, no click' '73 yes ' \
    "$RC $(has '"cls":"pay"' "$OUT$ERR") $(hits)"

  act --steps='[{"op":"click_at","x":150,"y":215},{"op":"eval","expr":"document.activeElement.id"}]' --out="$TMP/l4"
  arm 'L4 click_at on a text field is not classified: it runs, and the field has focus' '0 yes' \
    "$RC $(has 'step 3 (eval) = "q"' "$OUT$ERR")"

  act --steps='[{"op":"hover_at","x":450,"y":215}]' --expect='menu open: Gift cards' --out="$TMP/l5"
  arm 'L5 hover_at opens a menu that opens on mouseover' '0 yes' "$RC $(has 'verified' "$OUT")"

  act --steps='[{"op":"type_at","x":150,"y":215,"value":"blue shoes"},{"op":"eval","expr":"document.querySelector(\"#q\").value"}]' --out="$TMP/l6"
  arm 'L6 type_at types into the field its click focused; eval reads it back' '0 yes' \
    "$RC $(has 'step 3 (eval) = "blue shoes"' "$OUT$ERR")"

  act --steps='[{"op":"type_at","x":160,"y":320,"value":"jk"}]' --out="$TMP/l7"
  arm 'L7 type_at whose click focuses no field types nothing and fails' '1 yes' \
    "$RC $(has 'which took no typing, so nothing was typed' "$OUT$ERR")"

  act --steps='[{"op":"click_at","x":5000,"y":120}]' --out="$TMP/l8"
  arm 'L8 a point outside the window is refused, and says the picture'"'"'s size' 'yes ' \
    "$(has 'is outside the page'"'"'s window' "$OUT$ERR") $(hits)"

  act --steps='[{"op":"eval","expr":"[JSON.parse(document.querySelector(\"#data\").textContent).price, document.querySelector(\"#hid\").textContent]"}]' --out="$TMP/l9"
  arm 'L9 eval returns embedded JSON and a hidden control'"'"'s text' '0 yes' \
    "$RC $(has 'step 2 (eval) = [12,"Duration: 20+ minutes"]' "$OUT$ERR")"

  act --steps='[{"op":"eval","expr":"document.querySelector(\"#pay\").click()"}]' --out="$TMP/l10"
  arm 'L10 eval that CLICKS is refused, and the page never saw the click' 'yes ' \
    "$(has 'refused: the expression would change the page' "$OUT$ERR") $(hits)"
  act --steps='[{"op":"eval","expr":"document.querySelector(\"#pay\").dispatchEvent(new MouseEvent(\"click\",{bubbles:true}))"}]' --out="$TMP/l10b"
  arm 'L10b ...and so is a synthetic click event' 'yes ' "$(has 'refused:' "$OUT$ERR") $(hits)"

  for ex in 'location.href=\"/away\"' 'history.pushState({},\"\",\"/away\")' 'window.open(\"/away\")' 'document.forms.length; document.body.insertAdjacentHTML(\"beforeend\",\"<form></form>\")'; do
    act --steps="[{\"op\":\"eval\",\"expr\":\"$ex\"}]" --out="$TMP/l11"
    arm "L11 eval that navigates or writes is refused, the page stays: $ex" "yes $U" \
      "$(has 'refused:' "$OUT$ERR") $(jq -r .url "$TMP/l11/after.json" 2>/dev/null)"
  done
  act --steps='[{"op":"eval","expr":"fetch(\"/hit?eval\")"}]' --out="$TMP/l12"
  arm 'L12 eval that fetches is refused, and nothing reached the server' 'yes ' "$(has 'refused:' "$OUT$ERR") $(hits)"

  act --steps='[{"op":"eval","expr":"document.cookie"},{"op":"click","selector":"#cookie"}]' --out="$TMP/l13"
  arm 'L13 eval reads document.cookie as "", and the page'"'"'s own cookie is back after it' '0 yes yes' \
    "$RC $(has 'step 2 (eval) = ""' "$OUT$ERR") $(has 'c=sid=abc123' "$(hits)")"

  : > "$HITS"; run live "$BROWSER" act "${U}login" --steps='[{"op":"eval","expr":"document.querySelector(\"#pw\").value"}]' --out="$TMP/l14"
  # The fixture's value is in its HTML (value=…), so the page text may show it; the arm is
  # that the SCRIPT never ran and printed nothing.
  arm 'L14 eval on a page whose password field holds a value is refused, and printed nothing' 'yes no' \
    "$(has 'a password field on this page holds a value' "$OUT$ERR") $(has '(eval) =' "$OUT$ERR")"

  act --steps='[{"op":"eval","expr":"(function(){ for(;;){} })()"}]' --out="$TMP/l15"
  arm 'L15 eval that never ends is stopped at its bound' yes "$(has 'the expression did not finish' "$OUT$ERR")"

  act --steps='[{"op":"eval","expr":"window.big"}]' --out="$TMP/l16"
  arm 'L16 a huge answer is cut, and says its full size' '0 yes' "$RC $(has '(cut: 50002 characters' "$OUT$ERR")"

  act --steps='[{"op":"click_at","x":380,"y":320}]' --out="$TMP/l17"
  arm 'L17 a click_at that opens a popup is followed: the re-read is the popup' 'Details window' \
    "$(jq -r .title "$TMP/l17/after.json" 2>/dev/null)"

  # ---------------------------------------------------------------- M  mutants
  cp -a "$ROOT/browser" "$TMP/mut1"
  sed -i 's/const risk = await point.pointRisk(page, s);/const risk = null;/' "$TMP/mut1/bin/driver-playwright" "$TMP/mut1/bin/session-daemon"
  arm 'M1 (anchor) mutant applied: no gate on a step by position' 0 "$(cat "$TMP/mut1/bin/driver-playwright" | grep -c 'point.pointRisk')"
  : > "$HITS"; run live "$TMP/mut1/bin/browser" act "$U" --steps='[{"op":"click_at","x":380,"y":120}]' --out="$TMP/m1"
  arm 'M1 MUTANT (no gate): L2 goes red — the page gets the pay click' '0 pay' "$RC $(hits)"
  cp -a "$ROOT/browser" "$TMP/mut2"
  sed -i 's/throwOnSideEffect: true/throwOnSideEffect: false/' "$TMP/mut2/lib/point.cjs"
  arm 'M2 (anchor) mutant applied: no side-effect check' 1 "$(grep -c 'throwOnSideEffect: false' "$TMP/mut2/lib/point.cjs")"
  : > "$HITS"; run live "$TMP/mut2/bin/browser" act "$U" --steps='[{"op":"eval","expr":"document.querySelector(\"#pay\").click()"}]' --out="$TMP/m2"
  arm 'M2 MUTANT (no side-effect check): L10 goes red — the page gets the click' 'pay' "$(hits)"

  # ---------------------------------------------------------------- S  served
  XVFB_RUN="$(command -v xvfb-run || true)"
  if [[ -z "$XVFB_RUN" ]]; then
    SKIP=$((SKIP+1)); printf 'SKIP: S served arms — no xvfb-run\n'
  else
    SPROF="$TMP/served"; mkdir -p "$SPROF"; chmod 700 "$SPROF"; SOCK="$TMP/s.sock"
    env -u NODE_PATH FIVEDIVE_BROWSER_CHROME="$REAL_CHROME" "$XVFB_RUN" -a node "$DAEMON" serve "$SPROF" "$SOCK" > "$TMP/s.ready" 2> "$TMP/s.err" &
    _KILL+=($!)
    for _ in $(seq 150); do grep -q '^ready' "$TMP/s.ready" 2>/dev/null && break; sleep 0.2; done
    arm 'S0 (anchor) the served daemon is up on real Chrome' yes "$(grep -q '^ready' "$TMP/s.ready" && echo yes || { tail -5 "$TMP/s.err" >&2; echo no; })"
    call() { env -u NODE_PATH node "$DAEMON" call "$SOCK" <<<"$1"; }
    plan() { jq -nc --arg u "$U" --argjson s "$1" '{op:"plan", steps:([{op:"goto",url:$u}] + $s), args:{}, literal:true, guard:true, allow_kinds:["publish","send","delete"], report:{tree:false}}'; }
    : > "$HITS"; run call "$(plan '[{"op":"click_at","x":380,"y":120}]')"
    arm 'S1 served: click_at over "Place order" stops for the owner (73), no click' '73 yes ' "$RC $(has '"cls":"pay"' "$ERR") $(hits)"
    run call "$(plan '[{"op":"eval","expr":"JSON.parse(document.querySelector(\"#data\").textContent).items"}]')"
    arm 'S2 served: eval reads the embedded JSON' '0 yes' "$RC $(has 'step 2 (eval) = ["a","b","c"]' "$ERR")"
    : > "$HITS"; run call "$(plan '[{"op":"eval","expr":"document.querySelector(\"#pay\").click()"}]')"
    arm 'S3 served: eval that clicks is refused, no click' 'yes ' "$(has 'refused:' "$ERR") $(hits)"
    : > "$HITS"; run call "$(plan '[{"op":"click_at","x":160,"y":120}]')"
    arm 'S4 served: click_at on the bare div clicks it' '0 go' "$RC $(hits)"
  fi
fi

printf '\n%d pass, %d fail, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
