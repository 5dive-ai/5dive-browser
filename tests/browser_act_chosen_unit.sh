#!/usr/bin/env bash
# DIVE-7791 — every served act says what is set on the page now, and when the url
# dropped a filter or sort.
#
# On the 1.69.0 bench rerun (DIVE-7754) 18-19 of the 30 non-wall misses were a
# filter or sort the task named that the final list did not have: never applied,
# a site question skipped, or undone by a later load (Best Buy: sorted by price,
# then a goto dropped `sp=Price-Low-To-High`; the list was Best Match again).
#
#   P  lib/aria.cjs _chosenIn on a fake document: checked inputs by their label,
#      aria-checked / aria-pressed, a select as "name: option" (never its option
#      list), a custom combobox's shown value, a "Sort by" button; caps; dedupe
#   A  pageAfter carries `chosen`, and a page that throws gives []
#   L  lib/look.cjs: lookOf keeps chosen; compare reports it and the params lost;
#      paramsLost: same page only, dropped keys only, tracking/paging keys skipped
#   B  bin/browser _act_look_say prints `set now:` and `! the url dropped`, and
#      neither line when there is nothing to say (an older daemon's look)
#   S  the daemon passes after.chosen into the look
#   D  documented: SKILL.md checks each filter and sort against `set now:`
#   R  red on the pre-fix tree: run with FIVEDIVE_CHOSEN_BASE=<checkout of main>
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="${FIVEDIVE_CHOSEN_BASE:-$PWD}"
BROWSER="$ROOT/browser/bin/browser"
printf 'grading tree: %s @ %s\n' "$ROOT" "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2

TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }
tn() { if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected NOT to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }

# ============================================================= P  _chosenIn
# A fake document: querySelectorAll answers by the kind of control the selector
# asks for, which is how _chosenIn asks (one query per kind).
chosen() { node -e '
const A = require(process.argv[1]);
if (typeof A._chosenIn !== "function") { console.log("NO _chosenIn"); process.exit(0); }
const mk = (tagName, o) => Object.assign({ tagName, getAttribute: (k) => (o.attrs || {})[k] || null,
  closest: () => o.wrapLabel || null, labels: o.labels || null, textContent: o.text || "" }, o);
const ids = { lblSort: { textContent: "Sort by" } };
const kinds = JSON.parse(process.argv[2]);
const build = (x) => mk(x.tag, Object.assign({}, x, x.label ? { labels: [{ textContent: x.label }] } : {},
  x.wrap ? { wrapLabel: { textContent: x.wrap } } : {}));
global.document = { getElementById: (id) => ids[id] || null,
  querySelectorAll: (sel) => (kinds[sel.startsWith("input") ? "input" : sel.startsWith("select") ? "select"
    : sel.startsWith("button") ? "button" : sel === "[role=combobox]" ? "combo" : "aria"] || []).map(build) };
console.log(JSON.stringify(A._chosenIn()));
' "$ROOT/browser/lib/aria.cjs" "$1" 2>&1; }
P1="$(chosen '{
 "input": [ {"tag":"INPUT","type":"checkbox","checked":true,"label":"  Part-time  "},
            {"tag":"INPUT","type":"checkbox","checked":false,"label":"Full-time"},
            {"tag":"INPUT","type":"radio","checked":true,"wrap":"Weekly\n (most popular)"},
            {"tag":"INPUT","type":"radio","checked":true,"attrs":{"aria-label":"1 star"}} ],
 "aria": [ {"tag":"DIV","text":"Accepts Medicare"}, {"tag":"BUTTON","attrs":{"aria-label":"Free shipping"},"text":"x"} ],
 "select": [ {"tag":"SELECT","name":"sort","attrs":{"aria-labelledby":"lblSort"},"text":"Best Match Price Low to High Newest",
              "selectedOptions":[{"textContent":"Price Low to High"}]},
             {"tag":"SELECT","name":"radius","text":"5 10 25","selectedOptions":[{"textContent":"5 miles"}]} ],
 "button": [ {"tag":"BUTTON","text":"Sort by: Newest"}, {"tag":"BUTTON","text":"Add to cart"} ]
}')"
t  'P1 ticked boxes and radios by their label; a select as name: option; the sort button' \
   '["[x] Part-time","[x] Weekly (most popular)","[x] 1 star","[x] Accepts Medicare","[x] Free shipping","Sort by: Price Low to High","radius: 5 miles","Sort by: Newest"]' "$P1"
tn 'P1 ...an unticked box is not listed' 'Full-time' "$P1"
tn 'P1 ...a select is never its option list' 'Best Match Price' "$P1"
tn 'P1 ...a button that is not a sort is not listed' 'Add to cart' "$P1"
P2="$(chosen '{
 "combo": [],
 "input": [ {"tag":"INPUT","type":"checkbox","checked":true,"label":"Same"}, {"tag":"INPUT","type":"checkbox","checked":true,"label":"Same"} ]
}')"
t  'P2 the same words twice are listed once' '["[x] Same"]' "$P2"
P3="$(node -e '
const A = require(process.argv[1]);
if (typeof A._chosenIn !== "function") { console.log("NO _chosenIn"); process.exit(0); }
const box = (i) => ({ tagName: "INPUT", type: "checkbox", checked: true, labels: [{ textContent: "Option " + i + " " + "z".repeat(i === 0 ? 90 : 0) }],
  getAttribute: () => null, closest: () => null });
const combo = [{ tagName: "BUTTON", textContent: "Best Match", getAttribute: () => null, closest: () => null },
  { tagName: "INPUT", textContent: "", value: "typed", getAttribute: () => null, closest: () => null }];
global.document = { getElementById: () => null, querySelectorAll: (s) => s.startsWith("input") ? Array.from({ length: 30 }, (_, i) => box(i))
  : s.startsWith("[role=combobox]") ? combo : [] };
const r = A._chosenIn();
console.log(r.length, r[0].length, r[0].endsWith("…"));
' "$ROOT/browser/lib/aria.cjs" 2>&1)"
t  'P3 capped at 14 entries of at most 60 characters' '14 60 true' "$P3"
P4="$(chosen '{"combo": [ {"tag":"BUTTON","text":"Best Match"}, {"tag":"DIV","attrs":{"aria-label":"Sort"},"text":"Lowest price"},
  {"tag":"INPUT","text":""} ]}')"
t  'P4 a custom dropdown shows its value, named when it has a name; an input combobox is not listed' '["Best Match","Sort: Lowest price"]' "$P4"
P5="$(node -e '
const A = require(process.argv[1]);
if (typeof A._chosenIn !== "function") { console.log("NO _chosenIn"); process.exit(0); }
global.document = { getElementById: () => null, querySelectorAll: () => { throw new Error("bad selector"); } };
console.log(JSON.stringify(A._chosenIn()));' "$ROOT/browser/lib/aria.cjs" 2>&1)"
t  'P5 a page that refuses a selector gives an empty list, not an error' '[]' "$P5"

# ============================================================= A  pageAfter
pa() { node -e '
const A = require(process.argv[1]);
const mode = process.argv[2];
const page = { url: async () => "https://x.test/list", title: async () => "List", content: async () => "<html></html>",
  waitForTimeout: async () => {}, evaluate: async (fn, arg) => {
    if (arg && arg.chosenOf) { if (mode === "throw") throw new Error("detached"); return ["[x] Part-time"]; }
    return arg && arg.textOf ? "Jobs" : ""; } };
A.pageAfter(page, {}).then((o) => console.log(JSON.stringify(o.chosen)));
' "$ROOT/browser/lib/aria.cjs" "$1" 2>&1; }
t  'A1 pageAfter carries what is set now' '["[x] Part-time"]' "$(pa ok)"
t  'A2 ...and a page that throws gives []' '[]' "$(pa throw)"

# ============================================================= L  lib/look.cjs
L="$(node -e '
const L = require(process.argv[1]);
const n = (ref) => ({ ref, role: ref.split("/")[0] });
const a = L.lookOf("https://www.bestbuy.com/site/searchpage.jsp?id=pcat17071&sp=Price-Low-To-High&st=NordicTrack&utm_source=x&page=2", [n("button/Add")], "a", ["Sort by: Price Low to High"]);
const b = L.lookOf("https://www.bestbuy.com/site/searchpage.jsp?st=NordicTrack&id=pcat17071", [n("button/Add")], "a", ["Best Match"]);
const c = L.lookOf("https://www.bestbuy.com/site/other.jsp", [n("button/Add")], "a");
const d = L.lookOf("https://www.bestbuy.com/site/searchpage.jsp?id=pcat17071&sp=Price-High-To-Low&st=NordicTrack", [n("button/Add")], "a");
const pl = (x, y) => JSON.stringify(L.compare(x, y).params_lost);
console.log([JSON.stringify(a.chosen), JSON.stringify(L.compare(a, b).chosen), pl(a, b), pl(a, c), pl(a, d),
  pl(null, b), JSON.stringify(L.compare(null, b).params_lost), JSON.stringify(c.chosen),
  JSON.stringify(L.paramsLost("not a url", "https://x.test/")),
  JSON.stringify(L.paramsLost("https://x.test/s?a=1&b=2&c=3&d=4&e=5&f=6&g=7&h=8", "https://x.test/s"))].join("\n"));
' "$ROOT/browser/lib/look.cjs" 2>&1)"
mapfile -t LL <<<"$L"
t  'L1 lookOf keeps what is set now' '["Sort by: Price Low to High"]' "${LL[0]:-}"
t  'L2 compare reports the CURRENT look'"'"'s set controls' '["Best Match"]' "${LL[1]:-}"
t  'L3 same page, sp= gone: it is lost; tracking and paging keys are not' '["sp=Price-Low-To-High"]' "${LL[2]:-}"
t  'L4 another page: nothing is lost' '[]' "${LL[3]:-}"
t  'L5 a value the agent changed is not lost' '[]' "${LL[4]:-}"
t  'L6 the first look loses nothing' '[]' "${LL[6]:-}"
t  'L7 no chosen given: []' '[]' "${LL[7]:-}"
t  'L8 a url that does not parse: []' '[]' "${LL[8]:-}"
t  'L9 at most 6 keys' '["a=1","b=2","c=3","d=4","e=5","f=6"]' "${LL[9]:-}"

# ============================================================= B  bin/browser prints it
eval "$(awk '/^_act_look_say\(\) \{/{f=1} f{print} f&&/^}/{f=0}' "$BROWSER")"
base='{first:false,same_url:false,refs_total:9,refs_added:[],refs_added_total:0,refs_removed:[],refs_removed_total:0,text_added:["x"],text_added_total:1,text_removed_total:0}'
jq -nc "{look:($base + {chosen:[\"[x] Part-time\",\"Sort by: Best Match\"], params_lost:[\"sp=Price-Low-To-High\"]})}" > "$TMP/b1.json"
SAY="$(_act_look_say "$TMP/b1.json")"
tc 'B1 set now: lists what is set, in one line' '  set now: [x] Part-time · Sort by: Best Match' "$SAY"
tc 'B1 ...and the dropped key is said' '  ! the url dropped sp=Price-Low-To-High: a filter or sort you set may be undone; check it is still on before you answer' "$SAY"
t  'B1 ...after what changed, set now last' '  set now: [x] Part-time · Sort by: Best Match' "$(tail -n1 <<<"$SAY")"
jq -nc "{look:($base + {chosen:[], params_lost:[]})}" > "$TMP/b2.json"
SAY="$(_act_look_say "$TMP/b2.json")"
tn 'B2 nothing set: no set now line' 'set now' "$SAY"
tn 'B2 ...nothing dropped: no warning' 'url dropped' "$SAY"
jq -nc "{look:$base}" > "$TMP/b3.json"
SAY="$(_act_look_say "$TMP/b3.json")"
t  'B3 an older daemon'"'"'s look (no chosen, no params_lost) prints as before' $'  --- what changed (the url changed; 9 refs now) ---\n  text:\n    x' "$SAY"

# ============================================================= S  the daemon
tc 'S1 the daemon passes what is set now into the look' 'look.lookOf(after.url, after.nodes, after.text, after.chosen)' "$(cat "$ROOT/browser/bin/session-daemon")"

# ============================================================= D  documented
SK="$(cat "$ROOT/browser/skills/use-browser/SKILL.md")"
tc 'D1 the skill checks each filter and sort against set now:' "Check each filter and sort the job names against the LAST
   act's \`set now:\`" "$SK"
tc 'D2 ...words in the search box are not a filter' 'Words
   in the search box are not a filter' "$SK"
tc 'D3 ...a question the job answers is answered, never skipped' 'is answered, never skipped' "$SK"
tn 'D4 ...and the show step of #135 is not brought back' '"op":"show"' "$SK"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
