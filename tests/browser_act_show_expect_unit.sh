#!/usr/bin/env bash
# DIVE-8051 — the act that proves the job pictures its proof.
#
# WebJudge grades the screenshots, never the answer. An act's page.png is the
# browser WINDOW, so a matched --expect below the fold ("$850 ... estimates",
# a "Climate Controlled" chip) was in the agent's text and in no picture: the
# nightly bench's om2w-a7a73c8f failed on "none of the screenshots show a cost
# estimate" while the answer quoted it. After a matched --expect, when no match
# is on screen, the first visible one is scrolled to the middle before the shot.
#
#   S1-S6  lib/aria.cjs _showIn, against a DOM shim (layout is the shim's: a
#          stub cannot grade the function it stands in for).
#   S7     showExpect only asks the page when the match is in the TEXT.
#   S8     the REAL bin/browser + driver-playwright (recording stub, fake Chrome):
#          a matched act asks to show BEFORE its screenshot and says it scrolled;
#          a failed or unmatched act does not ask. RED on a mutant without the wiring.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2

TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }
tn() { if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected NOT to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }
run() { local o="$TMP/.o" e="$TMP/.e"; "$@" >"$o" 2>"$e"; RC=$?; OUT=$(cat "$o"); ERR=$(cat "$e"); return 0; }
mutant() {  # mutant <name> <file under browser/> <perl-expr> -> path of the mutant bin/browser
  rm -rf "$TMP/mut-$1"; cp -r "$ROOT/browser" "$TMP/mut-$1"
  perl -0pi -e "$3" "$TMP/mut-$1/$2"
  printf '%s\n' "$TMP/mut-$1/bin/browser"
}

# ============================================================= S1-S7 the page side
# A shim page: each element has its text and a box; the viewport is 800 tall.
SHIM="$TMP/shim.cjs"
cat > "$SHIM" <<'JS'
const aria = require(process.argv[2]);
const out = {};
function el(tag, text, box, kids = [], style = {}) {
  const e = { tagName: tag, children: kids, _box: box, _style: style, scrolled: 0,
    get textContent() { return text + kids.map((k) => k.textContent).join(''); },
    getBoundingClientRect() { return this._box; },
    scrollIntoView(o) { this.scrolled++; this.block = o && o.block; } };
  return e;
}
const R = (top, h = 20, w = 300) => ({ top, bottom: top + h, width: w, height: h });
function page(body) {
  global.document = { body };
  global.window = { innerHeight: 800 };
  global.getComputedStyle = (e) => ({ visibility: e._style.visibility || 'visible', display: e._style.display || 'block' });
}
// S1 below the fold: the smallest match is scrolled to the middle.
let price = el('P', '$850 - These pros\' estimates', R(1900));
let body = el('BODY', '', R(0, 3000, 1200), [el('H1', 'Photographers', R(10)), el('DIV', '', R(1800, 400), [price])]);
page(body);
out.s1 = aria._showIn({ expect: 'estimates', showOf: true });
out.s1_scrolled = price.scrolled; out.s1_block = price.block; out.s1_body = body.scrolled;
// S2 a match already on screen: nothing moves, even with another below.
let top = el('SPAN', 'Climate Controlled', R(200)); let low = el('SPAN', 'Climate Controlled', R(2400));
page(el('BODY', '', R(0, 3000, 1200), [top, low]));
out.s2 = aria._showIn({ expect: 'climate controlled' });
out.s2_moved = top.scrolled + low.scrolled;
// S3 no match anywhere.
page(el('BODY', '', R(0, 3000, 1200), [el('P', 'nothing here', R(10))]));
out.s3 = aria._showIn({ expect: 'Superbike' });
// S4 a match split over a <b> and its sentence: the parent is the proof.
let b = el('B', '$850', R(2000, 20, 40)); let rest = el('SPAN', ' estimated cost', R(2000, 20, 200));
let sent = el('P', '', R(2000), [b, rest]);
page(el('BODY', '', R(0, 3000, 1200), [sent]));
out.s4 = aria._showIn({ expect: '\\$850.*estimated' });
out.s4_parent = sent.scrolled; out.s4_child = b.scrolled + rest.scrolled;
// S5 hidden (no box, or visibility:hidden) and a section taller than 1.5 screens are skipped.
let hid = el('SPAN', 'Level: Beginner', { top: 0, bottom: 0, width: 0, height: 0 });
let inv = el('SPAN', 'Level: Beginner', R(1500), [], { visibility: 'hidden' });
let tall = el('SECTION', 'Level: Beginner', R(1600, 1300));
page(el('BODY', '', R(0, 4000, 1200), [hid, inv, tall]));
out.s5 = aria._showIn({ expect: 'Level: Beginner' });
out.s5_moved = hid.scrolled + inv.scrolled + tall.scrolled;
// S6 a pattern that is no valid regex is matched as plain words.
let paren = el('SPAN', 'Italien (IT)', R(1700));
page(el('BODY', '', R(0, 3000, 1200), [paren]));
out.s6 = aria._showIn({ expect: 'Italien (IT' });
out.s6_scrolled = paren.scrolled;
// S7 showExpect: the page is asked only when the match is in the text.
(async () => {
  let asked = 0;
  const pg = { evaluate: async (fn, arg) => { asked++; return { show_report: true, in_view: true, argShow: arg.showOf }; },
               waitForTimeout: async () => {} };
  out.s7_title_only = await aria.showExpect(pg, 'Wedding Photography', 'unrelated page text');
  out.s7_asked_title_only = asked;
  out.s7_text = await aria.showExpect(pg, 'estimate', 'Your estimate: $850');
  out.s7_asked_text = asked;
  // a page that answers with something else (a stub's walk) is no report
  const walkPg = { evaluate: async () => ({ nodes: [] }), waitForTimeout: async () => {} };
  out.s7_walk = await aria.showExpect(walkPg, 'estimate', 'estimate');
  const throwPg = { evaluate: async () => { throw new Error('navigating'); } };
  out.s7_throw = await aria.showExpect(throwPg, 'estimate', 'estimate');
  console.log(JSON.stringify(out));
})();
JS
S="$(node "$SHIM" "$ROOT/browser/lib/aria.cjs")"
j() { jq -c "$1" <<<"$S"; }
t 'S1 a match below the fold is scrolled into the picture' '{"show_report":true,"scrolled":true,"text":"$850 - These pros'"'"' estimates"}' "$(j .s1)"
t 'S1 ...the smallest element, to the middle, the body untouched' '1 "center" 0' "$(j .s1_scrolled) $(j .s1_block) $(j .s1_body)"
t 'S2 a match already on screen moves nothing' '{"show_report":true,"in_view":true} 0' "$(j .s2) $(j .s2_moved)"
t 'S3 no match: null' 'null' "$(j .s3)"
t 'S4 a match split over <b> and its sentence scrolls the sentence' '1 0' "$(j .s4_parent) $(j .s4_child)"
t 'S5 hidden, invisible and page-tall matches are skipped' 'null 0' "$(j .s5) $(j .s5_moved)"
t 'S6 an invalid regex is matched as plain words' '1' "$(j .s6_scrolled)"
t 'S7 a title-only match never asks the page' 'null 0' "$(j .s7_title_only) $(j .s7_asked_title_only)"
t 'S7 a text match asks once, flagged showOf' 'true 1' "$(j .s7_text.argShow) $(j .s7_asked_text)"
t 'S7 a non-report answer and a throwing page are null' 'null null' "$(j .s7_walk) $(j .s7_throw)"

# ============================================================= S8 the wiring
SEAT="$(id -un)"
export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/profiles"
export FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/adapters"; mkdir -p "$FIVEDIVE_BROWSER_ADAPTER_DIR"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/sessions"
export FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/no-session-daemon"
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli"
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
export FIVEDIVE_BROWSER_APPROVAL_DIR="$TMP/approvals" FIVEDIVE_BROWSER_APPROVAL_POLICY="$TMP/policy.json"
export FIVEDIVE_BROWSER_GRANT_UID="$(id -u)" FIVEDIVE_BROWSER_RUN_SETTLE_MS=0 FIVEDIVE_BROWSER_TREE_SETTLE_MS=0
mkdir -p "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT"
chmod 711 "$FIVEDIVE_BROWSER_PROFILE_ROOT"; chmod 700 "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT"
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == --version ]] && { echo "Google Chrome 153"; exit 0; }\necho "<html><body>public</body></html>"\n' > "$FAKEBIN/google-chrome"
chmod +x "$FAKEBIN/google-chrome"
export PATH="$FAKEBIN:$PATH"
PWROOT="$TMP/pw"; mkdir -p "$PWROOT/node_modules/playwright-core"
printf '{ "name": "playwright-core", "version": "0.0.0-stub", "main": "index.js" }\n' > "$PWROOT/node_modules/playwright-core/package.json"
sed -n "/^cat > \"\$PWROOT\/node_modules\/playwright-core\/index.js\" <<'PWJS'$/,/^PWJS$/p" tests/browser_plugin_unit.sh \
  | sed '1d;$d' > "$PWROOT/node_modules/playwright-core/index.js"
t 'S8 (anchor) the stub was extracted from the main suite, with the show call' yes \
   "$(grep -q 'launchPersistentContext' "$PWROOT/node_modules/playwright-core/index.js" && grep -q 'arg.showOf' "$PWROOT/node_modules/playwright-core/index.js" && echo yes || echo no)"
export NODE_PATH="$PWROOT/node_modules"
export PWREC="$TMP/pw.jsonl"

URL="https://www.thumbtack.test/k/photographers/near-me/?zip=07055"
STEPS='[{"op":"click","selector":"#duration-4h"}]'
P_TEXT='Photographers near 07055
Duration: 4 hours
$850 - These pros'"'"' estimates have been updated based on 1 project detail'
SCROLLED='{"show_report":true,"scrolled":true,"text":"$850 - These pros estimates"}'
act() {  # act <bin/browser> <out> [act flags...]
  local bin="$1" out="$2"; shift 2; : > "$PWREC"
  run env PWTEXT="$P_TEXT" PWTITLE='Photographers' PWSHOW="$SCROLLED" "$bin" act "$URL" --steps="$STEPS" --out="$TMP/$out" "$@"
}
order() { jq -r 'select(.call=="show" or .call=="screenshot")|.call' "$PWREC" | tr '\n' ' ' | sed 's/ $//'; }

act "$BROWSER" s8a --expect='estimates' --expect-wait=0
t  'S8a a matched --expect verifies (0)' 0 "$RC"
t  'S8a ...the page is asked to show the match BEFORE the picture' 'show screenshot' "$(order)"
t  'S8a ...with the agent'"'"'s own pattern' 'estimates' "$(jq -r 'select(.call=="show")|.expect' "$PWREC")"
tc 'S8a ...and the act says the picture was scrolled to it' 'the picture is scrolled to what --expect matched' "$OUT$ERR"
act "$BROWSER" s8b --expect='Superbike' --expect-wait=0
t  'S8b an unmatched --expect never asks to show' 'screenshot' "$(order)"
act "$BROWSER" s8c
t  'S8c an act with no --expect never asks to show' 'screenshot' "$(order)"
: > "$PWREC"
run env PWTEXT="$P_TEXT" PWSHOW="$SCROLLED" PWFAIL=1 "$BROWSER" act "$URL" --steps="$STEPS" --out="$TMP/s8d" --expect='estimates' --expect-wait=0
t  'S8d (anchor) a failed step fails the act' 1 "$([[ $RC -ne 0 ]] && echo 1 || echo 0)"
t  'S8d ...and its re-read never asks to show' 0 "$(jq -r 'select(.call=="show")|.call' "$PWREC" | wc -l)"
MUT="$(mutant nowire bin/driver-playwright 's/if \(!failed && report\.expect && !report\.scope\) \{/if (false) {/')"
t  'M0 (anchor) the unwired copy landed' yes "$(grep -q 'if (false) {' "$TMP/mut-nowire/bin/driver-playwright" && echo yes || echo no)"
act "$MUT" s8m --expect='estimates' --expect-wait=0
t  'S8 RED ARM: without the wiring the matched act never asks to show' 'screenshot' "$(order)"

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
