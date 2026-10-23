#!/usr/bin/env bash
# DIVE-6795 — a served `act` answers with what the steps changed, not the whole page.
#
# Measured 2026-10-23 on the bench rig (a timing build of the served browser):
# after every act the session derived page.md with Defuddle (0.9-4 s), and
# bin/browser parsed the multi-MB report with jq six times over (1.6 s on a
# Wikipedia article). The agent then read the page.md printed inline, or opened
# tree.json / page.md itself (32 KB a Read on the Online-Mind2Web jobs).
#
#   U  lib/look.cjs, direct: the first look is all new; refs that appear and go;
#      text lines as multisets; non-interactive roles do not count; the caps.
#   S  the session daemon on the main suite's playwright stub:
#      S1 a snapshot with look:true, then a plan with look:true: the report's look
#         names the ref that appeared and the one that went
#      S2 split:true sends the document (base64), the picture and the refs on lines
#         of their own, and the report line carries none of them
#      S3 a caller that did not ask gets the one combined line it always got
#      S4 no extract sha, no extraction: the report has no `extracted`
#   C  bin/browser's half, on canned daemon payloads (no daemon):
#      C1 the split payload lands as page.html, tree.json, page.png, after.json+look
#      C2 the old combined payload still lands the same files
#      C3 what changed is printed: + and - refs, the new text, the counts
#      C4 nothing changed says so
#      C5 the plan asks for look and split, and sends the extract sha only on --full
#   V  --expect also reads what the form fields hold (a typed ZIP is on screen,
#      innerText never has it): _valuesIn, pageAfter, bin/browser's grep
#   E  a failed step's error has no Playwright "Call log:" (30 lines per failure)
#   R  snapshot --interactive prints up to 300 refs inline (past 60 the agent Read
#      tree.json: 20-42 KB of JSON a page on the bench)
#   N  a goto the site's own redirect interrupts waits for that load (2 of 5 first
#      snapshots on the bench exited 69 on it)
#   K  `snapshot _public` with no url is the page the last act/snapshot left
#   P  a look act's page.md is the page's plain text (the model opened page.md
#      after acts and found no file)
#   D  documented: SKILL.md tells the agent to act on the refs the act printed.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
DAEMON="$ROOT/browser/bin/session-daemon"
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2

TMP="$(mktemp -d)"
_KILL=()
trap 'rc=$?; for p in "${_KILL[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }
tn() { if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected NOT to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }
run() { local o="$TMP/.o" e="$TMP/.e"; "$@" >"$o" 2>"$e"; RC=$?; OUT=$(cat "$o"); ERR=$(cat "$e"); return 0; }

# ============================================================= U  lib/look.cjs
u="$(node -e '
const L = require(process.argv[1]);
const n = (ref, role) => ({ ref, role: role || ref.split("/")[0], name: ref.split("/")[1] });
const a = L.lookOf("https://x.test/a", [n("button/Add"), n("textbox/Drug name"), n("heading/Title")], "Drug name\nAdd\n\nAdd");
const b = L.lookOf("https://x.test/a", [n("button/Add"), n("textbox/Drug name"), n("link/aspirin"), n("heading/Other")], "Drug name\nAdd\nAdd\nAdd\naspirin   added");
const first = L.compare(null, a), d = L.compare(a, b), none = L.compare(b, b);
const many = L.lookOf("https://x.test/b", Array.from({ length: 80 }, (_, i) => n("link/l" + i)), "x".repeat(4000));
const cap = L.compare(a, many), gone = L.compare(many, a);
const m = L.memory(), p = {};
const m1 = m.since(p, a), m2 = m.since(p, b);
console.log(JSON.stringify({ first, d, none, cap: { n: cap.refs_added.length, tot: cap.refs_added_total, same: cap.same_url,
  text: cap.text_added.join("").length }, gone: { list: gone.refs_removed.length, tot: gone.refs_removed_total },
  m1: m1.first, m2: m2.refs_added }));
' "$ROOT/browser/lib/look.cjs" 2>&1)"
t  'U1 a tab not seen before: everything on it is new, and says so' 'true 2 ["button/Add","textbox/Drug name"]' \
   "$(jq -c '"\(.first.first) \(.first.refs_total) \(.first.refs_added)"' -r <<<"$u")"
t  'U2 a ref that appeared, and none went' '["link/aspirin"] 0' "$(jq -r '"\(.d.refs_added|tojson) \(.d.refs_removed_total)"' <<<"$u")"
t  'U2 ...a heading is not a ref to act on: it does not count either way' 3 "$(jq -r '.d.refs_total' <<<"$u")"
t  'U3 text as a multiset: a third "Add" and the new line, spaces squeezed' '["Add","aspirin added"] 2 0' \
   "$(jq -r '"\(.d.text_added|tojson) \(.d.text_added_total) \(.d.text_removed_total)"' <<<"$u")"
t  'U3 ...same url' true "$(jq -r '.d.same_url' <<<"$u")"
t  'U4 the same look twice: nothing changed' '0 0 0 0' \
   "$(jq -r '.none | "\(.refs_added_total) \(.refs_removed_total) \(.text_added_total) \(.text_removed_total)"' <<<"$u")"
t  'U5 the caps: 60 refs printed of 80, the url changed, 1.5 KB of text' '60 80 false 1501' \
   "$(jq -r '"\(.cap.n) \(.cap.tot) \(.cap.same) \(.cap.text)"' <<<"$u")"
t  'U6 eighty refs gone is a count, not a list' '0 80' "$(jq -r '"\(.gone.list) \(.gone.tot)"' <<<"$u")"
t  'U7 memory: the first look of a tab is first, the next compares against it' 'true ["link/aspirin"]' \
   "$(jq -r '"\(.m1) \(.m2|tojson)"' <<<"$u")"
o="$(node -e '
const L = require(process.argv[1]);
const n = (ref) => ({ ref, role: ref.split("/")[0] });
const a = L.lookOf("u", [n("button/Ship")], "");
const b = L.lookOf("u", [n("button/Ship"), n("combobox/Country")].concat(Array.from({ length: 30 }, (_, i) => n("option/c" + i)), [n("button/Go")]), "");
const d = L.compare(a, b);
console.log(d.refs_added.length, d.refs_added_total, d.refs_added.includes("button/Go"), d.refs_added.filter((r) => r.startsWith("option/")).length);
' "$ROOT/browser/lib/look.cjs" 2>&1)"
t  'U8 a list of 30 options prints 8 of them, and the ref after the list still shows' '10 32 true 8' "$o"

# ============================================================= V  what the form fields hold
v="$(node -e '
const A = require(process.argv[1]);
const el = (tagName, type, value, extra) => Object.assign({ tagName, type, value }, extra || {});
global.document = { querySelectorAll: () => [
  el("INPUT", "text", "75201"), el("INPUT", "password", "hunter2"), el("INPUT", "hidden", "csrf-tok"),
  el("INPUT", "checkbox", "on"), el("TEXTAREA", "textarea", "a note"), el("INPUT", "text", ""),
  el("SELECT", "select-one", "b", { selectedOptions: [{ textContent: "Second choice" }] }) ] };
console.log(JSON.stringify(A._valuesIn()));
' "$ROOT/browser/lib/aria.cjs" 2>&1)"
t  'V1 a field value, a text area and the chosen option; never a password, hidden input or checkbox' '"75201\na note\nSecond choice"' "$v"
pa() { node -e '
const A = require(process.argv[1]);
const vals = process.argv[2];
const page = { url: async () => "https://x.test/rate", title: async () => "Rates", content: async () => "<html></html>",
  waitForTimeout: async () => {}, evaluate: async (fn, arg) => arg && arg.valuesOf ? vals : arg && arg.textOf ? "Origin ZIP code" : "" };
A.pageAfter(page, { expect: "75201", expectWaitMs: 1000, pollMs: 250 }).then((o) => console.log(o.expect_polled_ms, JSON.stringify(o.values)));
' "$ROOT/browser/lib/aria.cjs" "$1" 2>&1; }
t  'V2 --expect matches a typed value at once: no polling' '0 "75201"' "$(pa 75201)"
t  'V2 ...(control) a field without it polls the full wait' '1000 ""' "$(pa '')"
tc 'V3 bin/browser grades --expect against the field values too' '[.text, .title, .url, .values]' "$(cat "$BROWSER")"
tc 'V3 ...and after.json keeps them' '{url, title, text, values, wait_for' "$(cat "$BROWSER")"

# ============================================================= E  what a failed step prints
e="$(node -e '
const A = require(process.argv[1]);
const log = ["page.click: Timeout 1500ms exceeded.", "Call log:", "  - waiting for locator(\"[data-5dive-ref=r16]\")", "  - attempting click action",
  "    - <aside id=\"usercentrics-cmp-ui\"></aside> intercepts pointer events", "  - retrying click action", "    - waiting 500ms"].join("\n");
console.log(JSON.stringify([A.stepErrorText(log), A.stepErrorText("page.click: Timeout 5000ms exceeded.\nCall log:\n  - waiting 20ms"), A.stepErrorText("no ref named x")]));
' "$ROOT/browser/lib/aria.cjs" 2>&1)"
t  'E1 a step error keeps its first line and the reason, not the 30-line Call log' \
   '["page.click: Timeout 1500ms exceeded. (<aside id=\"usercentrics-cmp-ui\"></aside> intercepts pointer events)","page.click: Timeout 5000ms exceeded.","no ref named x"]' "$e"
tc 'E1 ...and the daemon sends it so' 'aria.stepErrorText(e.message)' "$(cat "$DAEMON")"

# ============================================================= S  the session daemon
DSTUB="$TMP/dpw"; mkdir -p "$DSTUB/node_modules/playwright-core"
printf '{ "name": "playwright-core", "version": "0.0.0-daemon-stub", "main": "index.js" }\n' > "$DSTUB/node_modules/playwright-core/package.json"
sed -n "/^cat > \"\$DSTUB\/node_modules\/playwright-core\/index.js\" <<'DPWJS'$/,/^DPWJS$/p" tests/browser_plugin_unit.sh \
  | sed '1d;$d' > "$DSTUB/node_modules/playwright-core/index.js"
t  'S0 (anchor) the daemon stub was extracted from the main suite' yes \
   "$(grep -q 'DPWREFS' "$DSTUB/node_modules/playwright-core/index.js" && echo yes || echo no)"
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == --version ]] && { echo "Google Chrome 153"; exit 0; }\n' > "$FAKEBIN/google-chrome"
chmod +x "$FAKEBIN/google-chrome"
printf '<html><body><button>Add</button><a href="/aspirin">aspirin</a></body></html>' > "$TMP/dom.html"
jq -nc '{nodes:[{ref:"button/Add",role:"button",name:"Add"},{ref:"button/Close",role:"button",name:"Close"}],
         title:"Checker", url:"https://warm.test/check", html:"<html><body>before</body></html>"}' > "$TMP/snap.json"
jq -nc '{nodes:[{ref:"button/Add",role:"button",name:"Add"},{ref:"link/aspirin",role:"link",name:"aspirin"}]}' > "$TMP/refs.json"
SPROF="$TMP/served"; mkdir -p "$SPROF"; chmod 700 "$SPROF"
SOCK="$TMP/s.sock"
env NODE_PATH="$DSTUB/node_modules" PWREC="$TMP/rec.jsonl" DPWDOM="$TMP/dom.html" DPWSNAP="$TMP/snap.json" \
    DPWREFS="$TMP/refs.json" DPWTEXT=$'Checker\nAdd' DPWVALUES=aspirin FIVEDIVE_BROWSER_CHROME="$FAKEBIN/google-chrome" \
    FIVEDIVE_BROWSER_HEADLESS=1 FIVEDIVE_BROWSER_RUN_SETTLE_MS=0 FIVEDIVE_BROWSER_TREE_SETTLE_MS=0 FIVEDIVE_BROWSER_POPUP_WAIT_MS=0 \
    node "$DAEMON" serve "$SPROF" "$SOCK" > "$TMP/s.ready" 2> "$TMP/s.err" &
_KILL+=($!)
for _ in $(seq 50); do grep -q '^ready' "$TMP/s.ready" 2>/dev/null && break; sleep 0.1; done
t  'S0 (anchor) the served daemon is up on the stub' yes "$(grep -q '^ready' "$TMP/s.ready" && echo yes || { cat "$TMP/s.err" >&2; echo no; })"
call() { node "$DAEMON" call "$SOCK" <<<"$1"; }
URL="https://warm.test/check"
STEPS='[{"op":"click","selector":"#add"}]'
plan() { jq -nc --argjson s "$STEPS" --argjson x "$1" '{op:"plan", steps:$s, args:{}, literal:true,
  report:{tree:true, shot:true}} + $x'; }

run call "$(jq -nc --arg u "$URL" '{op:"snapshot", url:$u, inline:true, look:true}')"
t  'S1 (anchor) the snapshot answered' "$URL" "$(jq -r .url <<<"$OUT" 2>/dev/null)"
run call "$(plan '{"look":true,"split":true}')"
REP="$(grep -F '"act_report":true' <<<"$OUT" | tail -1)"
t  'S1 the act says what changed since the snapshot: +link/aspirin -button/Close' '["link/aspirin"] ["button/Close"] false' \
   "$(jq -c -r '"\(.look.refs_added|tojson) \(.look.refs_removed|tojson) \(.look.first)"' <<<"$REP" 2>/dev/null)"
t  'S2 split: the report line carries no document, picture or refs' 'false false false' \
   "$(jq -r '"\(has("html_inline")) \(has("png_b64")) \(has("nodes"))"' <<<"$REP" 2>/dev/null)"
t  'S2 ...the document is its own base64 line, byte for byte' "$(cat "$TMP/dom.html")" \
   "$(grep '^{"act_html_b64":"' <<<"$OUT" | sed 's/^{"act_html_b64":"//; s/"}$//' | base64 -d)"
t  'S2 ...the refs are their own line' '["button/Add","link/aspirin"]' \
   "$(grep '^{"act_tree":true,' <<<"$OUT" | jq -c '[.nodes[].ref]' 2>/dev/null)"
t  'S2 ...and the picture' stub-png "$(grep '^{"act_png_b64":"' <<<"$OUT" | sed 's/^{"act_png_b64":"//; s/"}$//' | base64 -d)"
t  'S5 the report carries what the form fields hold' aspirin "$(jq -r '.values' <<<"$REP" 2>/dev/null)"
t  'S4 no extract sha asked for: nothing was extracted' false "$(jq -r 'has("extracted") and .extracted != null' <<<"$REP" 2>/dev/null)"
run call "$(plan '{}')"
REP="$(grep -F '"act_report":true' <<<"$OUT" | tail -1)"
t  'S3 a caller that asked for neither gets the one line it always got' 'true true true null 1' \
   "$(jq -r '"\(has("html_inline")) \(has("png_b64")) \(.nodes|type=="array") \(.look)"' <<<"$REP" 2>/dev/null) $(grep -c . <<<"$OUT")"
run call "$(plan '{"look":true,"split":true}')"
REP="$(grep -F '"act_report":true' <<<"$OUT" | tail -1)"
t  'S1 the act after an act compares with that act: nothing changed' '0 0' \
   "$(jq -r '"\(.look.refs_added_total) \(.look.refs_removed_total)"' <<<"$REP" 2>/dev/null)"

# A second daemon whose first goto the site's own redirect interrupts.
SOCK2="$TMP/s2.sock"; SPROF2="$TMP/served2"; mkdir -p "$SPROF2"; chmod 700 "$SPROF2"
env NODE_PATH="$DSTUB/node_modules" PWREC="$TMP/rec2.jsonl" DPWDOM="$TMP/dom.html" DPWSNAP="$TMP/snap.json" \
    DPWREFS="$TMP/refs.json" DPWTEXT='Checker' DPWGOTO_INTERRUPT=1 FIVEDIVE_BROWSER_CHROME="$FAKEBIN/google-chrome" \
    FIVEDIVE_BROWSER_HEADLESS=1 FIVEDIVE_BROWSER_RUN_SETTLE_MS=0 FIVEDIVE_BROWSER_TREE_SETTLE_MS=0 FIVEDIVE_BROWSER_POPUP_WAIT_MS=0 \
    node "$DAEMON" serve "$SPROF2" "$SOCK2" > "$TMP/s2.ready" 2> "$TMP/s2.err" &
_KILL+=($!)
for _ in $(seq 50); do grep -q '^ready' "$TMP/s2.ready" 2>/dev/null && break; sleep 0.1; done
OUT=$(node "$DAEMON" call "$SOCK2" <<<"$(jq -nc --arg u "https://redirects.test/" '{op:"snapshot", url:$u, inline:true}')" 2>&1); RC=$?
t  'N1 a snapshot whose goto the site'"'"'s redirect interrupted waits for that load, and answers' '0 https://warm.test/check' "$RC $(jq -r .url <<<"$OUT" 2>/dev/null | tail -1)"
t  'N1 ...it waited for the load that won' yes "$(grep -q '"call":"waitForLoadState"' "$TMP/rec2.jsonl" && echo yes || echo no)"

# ============================================================= C  bin/browser's half
# The two functions under test, from the shipped file; the daemon call is canned.
eval "$(awk '/^_act_session\(\) \{/{f=1} /^_act_look_say\(\) \{/{f=1} f{print} f&&/^}/{f=0}' "$BROWSER")"
_daemon_lease_json() { echo '{}'; }; _settle_json() { echo '{}'; }; _landing_json() { echo '{}'; }
_extract_sha() { echo SHA; }; _act_downloads_unpack() { :; }
_take_extracted() { :; }
_daemon_call() { printf '%s\n' "$2" > "$TMP/plan.sent"; cat "$CANNED"; }
_PG_DIR=x; _ACT_STAY=0; ACT_STEP_MS=10000
LOOK='{"first":false,"same_url":true,"refs_total":2,"refs_added":["link/aspirin"],"refs_added_total":1,"refs_removed":["button/Close"],"refs_removed_total":1,"text_added":["aspirin added"],"text_added_total":3,"text_removed_total":0}'
CANNED="$TMP/split.out"
{ jq -nc --argjson l "$LOOK" '{act_report:true, url:"https://warm.test/check", title:"Checker", text:"Checker\naspirin added", browser_mode:"headed", popup:null, look:$l}'
  printf '{"act_html_b64":"%s"}\n' "$(base64 -w0 < "$TMP/dom.html")"
  printf '{"act_png_b64":"%s"}\n' "$(printf 'PNG' | base64 -w0)"
  jq -nc '{act_tree:true, url:"https://warm.test/check", title:"Checker", nodes:[{ref:"link/aspirin",role:"link",name:"aspirin"}]}'
} > "$CANNED"
ST="$TMP/c1"; mkdir -p "$ST"; _ACT_FULL=0
_act_session warm.test "$STEPS" false 1 "" '{}' '[]' "$ST" "$TMP/c1.err"
t  'C1 split: page.html is the document' "$(cat "$TMP/dom.html")" "$(cat "$ST/page.html")"
t  'C1 ...tree.json is {url,title,nodes}' '"https://warm.test/check"|["link/aspirin"]|false' \
   "$(jq -c '"\(.url|tojson)|\([.nodes[].ref]|tojson)|\(has("act_tree"))"' -r "$ST/tree.json" 2>/dev/null)"
t  'C1 ...page.png, and after.json carries the look' 'PNG ["link/aspirin"]' "$(cat "$ST/page.png") $(jq -c '.look.refs_added' "$ST/after.json")"
t  'C5 the plan asks for look and split, and no extract without --full' 'true true false' \
   "$(jq -r '"\(.look) \(.split) \(has("extract"))"' "$TMP/plan.sent")"
ST="$TMP/c5"; mkdir -p "$ST"; _ACT_FULL=1
_act_session warm.test "$STEPS" false 1 "" '{}' '[]' "$ST" "$TMP/c5.err"
t  'C5 ...--full sends the extract sha' SHA "$(jq -r '.extract' "$TMP/plan.sent")"
CANNED="$TMP/old.out"
jq -nc --rawfile h "$TMP/dom.html" '{act_report:true, url:"https://warm.test/check", title:"Checker", text:"Checker",
  html_inline:$h, png_b64:("PNG"|@base64), nodes:[{ref:"button/Add",role:"button",name:"Add"}], browser_mode:"headed", popup:null}' > "$CANNED"
ST="$TMP/c2"; mkdir -p "$ST"; _ACT_FULL=0
_act_session warm.test "$STEPS" false 1 "" '{}' '[]' "$ST" "$TMP/c2.err"
t  'C2 an older session'"'"'s one-line report lands the same files, with no look' "$(cat "$TMP/dom.html")|PNG|[\"button/Add\"]|false" \
   "$(cat "$ST/page.html")|$(cat "$ST/page.png")|$(jq -c '[.nodes[].ref]' "$ST/tree.json")|$(jq -r 'has("look")' "$ST/after.json")"
SAY="$(_act_look_say "$TMP/c1/after.json")"
tc 'C3 what changed is printed' '--- what changed (2 refs now) ---' "$SAY"
tc 'C3 ...the ref that appeared' '  + ref=link/aspirin' "$SAY"
tc 'C3 ...the ref that went' '  - ref=button/Close' "$SAY"
tc 'C3 ...the new text, and how many more lines there are' $'  new text:\n    aspirin added\n    … 2 more lines (act --full prints page.md)' "$SAY"
tn 'C3 ...and not "nothing changed"' 'nothing on the page changed' "$SAY"
jq -nc '{look:{first:false,same_url:true,refs_total:2,refs_added:[],refs_added_total:0,refs_removed:[],refs_removed_total:0,text_added:[],text_added_total:0,text_removed_total:0}}' > "$TMP/none.json"
t  'C4 nothing changed says so' $'  --- what changed (2 refs now) ---\n  nothing on the page changed' "$(_act_look_say "$TMP/none.json")"
jq -nc '{look:{first:true,same_url:false,refs_total:90,refs_added:["link/a"],refs_added_total:90,refs_removed:[],refs_removed_total:0,text_added:["Hello"],text_added_total:1,text_removed_total:0}}' > "$TMP/first.json"
SAY="$(_act_look_say "$TMP/first.json")"
tc 'C3 a tab not seen yet is the page, with the count of refs past the cap' $'  --- the page: 90 refs (your first look at this tab) ---\n  + ref=link/a\n  + 89 more: tree.json\n  text:\n    Hello' "$SAY"

# ============================================================= R  an interactive snapshot prints its refs
eval "$(awk '/^INLINE_MD_MAX=/||/^INLINE_REFS_MAX=/||/^INLINE_SNAP_REFS_MAX=/{print} /^_inline_page\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$BROWSER")"
RD="$TMP/r"; mkdir -p "$RD"
jq -nc '{url:"u", title:"t", nodes:[range(134) | {ref:"link/l\(.)", role:"link"}]}' > "$RD/tree.json"
t  'R1 134 refs: an interactive snapshot prints every one' 134 "$(_inline_page "$RD" "$INLINE_SNAP_REFS_MAX" | grep -c '^  ref=')"
t  'R1 ...the default (page text and act) still stops at 60' 0 "$(_inline_page "$RD" | grep -c '^  ref=')"
tc 'R1 ...and cmd_snapshot passes the cap on --interactive' 'if (( interactive )); then _inline_page "$out" "$INLINE_SNAP_REFS_MAX"' "$(cat "$BROWSER")"

# ============================================================= K  snapshot <site> with no url
eval "$(awk '/^FLOW_CRUMB_TTL=/||/^_flow_crumb_file\(\)/{print} /^_page_crumb\(\) \{/{f=1} /^_crumb_url\(\) \{/{f=1} f{print} f&&/^}/{f=0}' "$BROWSER")"
KD="$TMP/seat"; mkdir -p "$KD"; _seat_dir() { echo "$KD"; }
_page_crumb _public 'https://www.fedex.com/en-us/online/rating.html'
t  'K1 right after an act on _public, its page is the url' 'https://www.fedex.com/en-us/online/rating.html' "$(_crumb_url _public)"
t  'K1 ...another profile has no page from it' 1 "$(_crumb_url github.com >/dev/null; echo $?)"
printf '_public\t%s\thttps://old.test/\n' "$(( $(date +%s) - FLOW_CRUMB_TTL - 5 ))" > "$(_flow_crumb_file)"
t  'K1 ...a stale page is no page' 1 "$(_crumb_url _public >/dev/null; echo $?)"
run env FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/kp" "$BROWSER" snapshot _public --interactive
tc 'K2 with nothing to go on it is still a usage error, and says the url can be left out' 'the url may be left out' "$ERR"
t  'K2 ...exit 64' 64 "$RC"

# ============================================================= P  a look act's page.md is the page text
PJ="$(awk '/# page.md IS THE PAGE.S TEXT/{f=1} f&&/jq -r/{c=1} c{print} c&&/after.json"; }/{exit}' "$BROWSER" | sed -n '/jq -r/,/after.json/p' | sed 's/^ *( umask 077; { //; s/ *"\$stage\/after.json"; }.*$//; s/\\$//' | tr -d '\n')"
jq -nc '{url:"https://x.test/rate", title:"Rates", text:"Origin ZIP code\nWeight"}' > "$TMP/pa.json"
PMD="$(eval "$PJ \"$TMP/pa.json\"" 2>&1)"
t  'P1 page.md after a look act: front matter, then the text --expect read' \
   $'---\nurl: "https://x.test/rate"\ntitle: "Rates"\nsource: "the page text; act --full extracts the page"\n---\n\nOrigin ZIP code\nWeight' "$PMD"

# ============================================================= D  documented
tc 'D1 SKILL.md: act on the refs the act printed' 'An act prints what it changed' "$(cat "$ROOT/browser/skills/use-browser/SKILL.md")"
tc 'D2 act --help names --full' '--full' "$(env FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/p" "$BROWSER" act --help 2>&1)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
