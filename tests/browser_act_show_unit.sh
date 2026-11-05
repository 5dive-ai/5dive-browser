#!/usr/bin/env bash
# DIVE-7754 — `act` has a `show` step: it scrolls an element into the window and
# changes nothing, so the act's page.png pictures the proof the agent read.
#
# Measured on the 50-task bench (DIVE-7728, browser 1.68.2): the agent reads the
# whole page as text, but page.png is the window only. A result below the fold
# (BabyCenter's percentiles after "Calculate", a filter chip, a sort label) was
# read and reported, and absent from every picture; WebJudge grades the pictures.
# Runs that ended on an act passed 15 of 22; runs that ended on a snapshot, 3 of 18.
#
# Driven through the REAL bin/browser and the REAL driver-playwright, with the
# recording playwright-core stub extracted from browser_plugin_unit.sh at run time
# and a fake google-chrome. No Chrome, no network.
#
#   S1  `show` runs: the element is scrolled into the window, and the act's
#       screenshot is taken AFTER the scroll (the picture is of it).
#   S2  `show` changes nothing: no click, fill, type, press or select is sent.
#   S3  `show` with no selector is refused before the browser opens.
#   S4  RED ARM: on the pre-fix vocabulary (no `show`) the same act is refused 64.
#   S5  both executors know it: the served session-daemon has the same entry
#       and case line as the one-shot driver.
#   S6  lib/aria.cjs direct: showStep takes the FIRST match and passes the
#       timeout; stepRisk never makes it one of the owner's four.
#   S7  documented: SKILL.md teaches `show` and to end on the proof.
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
run() { local o="$TMP/.o" e="$TMP/.e"; "$@" >"$o" 2>"$e"; RC=$?; OUT=$(cat "$o"); ERR=$(cat "$e"); return 0; }
mutant() {  # mutant <name> <file under browser/> <perl-expr> -> path of the mutant bin/browser
  rm -rf "$TMP/mut-$1"; cp -r "$ROOT/browser" "$TMP/mut-$1"
  perl -0pi -e "$3" "$TMP/mut-$1/$2"
  printf '%s\n' "$TMP/mut-$1/bin/browser"
}

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
t  'S0 (anchor) the stub was extracted from the main suite' yes \
   "$(grep -q 'launchPersistentContext' "$PWROOT/node_modules/playwright-core/index.js" && echo yes || echo no)"
t  'S0 (anchor) ...and it records a scroll into view' yes \
   "$(grep -q 'scrollIntoViewIfNeeded' "$PWROOT/node_modules/playwright-core/index.js" && echo yes || echo no)"
export NODE_PATH="$PWROOT/node_modules"
export PWREC="$TMP/pw.jsonl"

# BabyCenter's calculator, cut down: the result is on the page, below the form.
URL="https://growth.calc.test/percentile-calculator"
HTML='<html><body><form><button>Calculate</button></form><section id="result"><h2>Results</h2><p>Weight: 55th percentile</p></section></body></html>'
TEXT=$'Growth calculator\nCalculate\nResults\nWeight: 55th percentile'
act() {  # act <bin/browser> <out> <steps> [flags...]
  local bin="$1" out="$2" steps="$3"; shift 3; : > "$PWREC"
  run env PWHTML="$HTML" PWTEXT="$TEXT" PWTITLE='Growth calculator' \
      "$bin" act "$URL" --steps="$steps" --out="$TMP/$out" "$@"
}
SHOW='[{"op":"show","selector":"text=55th percentile"}]'
calls() { jq -r '.call' "$PWREC" | tr '\n' ' '; }

# ============================================================= S1 it runs, and the picture follows it
act "$BROWSER" s1 "$SHOW" --expect='55th percentile' --expect-wait=0
t  'S1 an act whose step is show exits 0' 0 "$RC"
tc 'S1 ...and says the step ran' 'step 2 (show) ok' "$ERR"
t  'S1 ...the element was scrolled into view, by its selector' 'text=55th percentile' \
   "$(jq -r 'select(.call=="scrollIntoView") | .sel' "$PWREC" | head -1)"
t  'S1 ...on the first match' 'text=55th percentile' "$(jq -r 'select(.call=="first") | .sel' "$PWREC" | head -1)"
t  'S1 ...with a bounded wait' yes "$(jq -r 'select(.call=="scrollIntoView") | .timeout' "$PWREC" | head -1 | grep -qE '^[0-9]+$' && echo yes || echo no)"
t  'S1 ...and the act'"'"'s screenshot is taken after the scroll' 'scrollIntoView screenshot' \
   "$(jq -r '.call' "$PWREC" | grep -E '^(scrollIntoView|screenshot)$' | head -2 | tr '\n' ' ' | sed 's/ $//')"
t  'S1 ...page.png was written' yes "$([[ -s "$TMP/s1/page.png" || -e "$TMP/s1/page.png" ]] && echo yes || echo no)"

# ============================================================= S2 it changes nothing
t  'S2 show sends no click, fill, type, press or select' '' \
   "$(jq -r 'select(.call|test("^(click|fill|type|press|selectOption|setInputFiles)$")) | .call' "$PWREC" | tr '\n' ' ')"

# ============================================================= S3 a selector is required
act "$BROWSER" s3 '[{"op":"show"}]'
t  'S3 show with no selector is refused' yes "$([[ $RC -ne 0 ]] && echo yes || echo no)"
tc 'S3 ...naming the missing field' 'selector' "$ERR"
t  'S3 ...and nothing was scrolled' '' "$(jq -r 'select(.call=="scrollIntoView") | .call' "$PWREC" 2>/dev/null)"

# ============================================================= S4 red arm: the pre-fix vocabulary
MUT="$(mutant vocab bin/browser "s/(ACT_VOCAB='[^']*) show'/\$1'/")"
t  'S4 (anchor) the pre-fix vocabulary landed in the copy' yes \
   "$(grep -q "^ACT_VOCAB='goto fill type click wait_for select press upload'$" "$MUT" && echo yes || echo no)"
act "$MUT" s4 "$SHOW"
t  'S4 RED ARM: without show in the vocabulary the same act is refused (64)' 64 "$RC"
tc 'S4 ...as not an act step' 'is not an act step' "$ERR"

# ============================================================= S5 both executors
D="$ROOT/browser/bin/session-daemon"; P="$ROOT/browser/bin/driver-playwright"
t  'S5 both executors list show with a selector' '1 1' \
   "$(grep -c "^  show:     \['selector'\],$" "$P") $(grep -c "^  show:     \['selector'\],$" "$D")"
t  'S5 ...and both run it through aria.showStep' '1 1' \
   "$(grep -c "case 'show':     await on((x, timeout) => aria.showStep(page, x, timeout)); break;" "$P") $(grep -c "case 'show':     await on((x, timeout) => aria.showStep(page, x, timeout)); break;" "$D")"

# ============================================================= S6 aria direct
cat > "$TMP/s6.js" <<'JS'
const aria = require(process.env.ARIA);
const seen = [];
const page = { locator: (sel) => ({ first: () => ({ scrollIntoViewIfNeeded: async (o) => { seen.push(`${sel}@${o.timeout}`); } }),
                                    scrollIntoViewIfNeeded: async () => { seen.push('NOT-FIRST'); } }) };
(async () => {
  await aria.showStep(page, 'text=55th percentile', 1234);
  const risk = await aria.stepRisk(page, { op: 'show', selector: 'text=Place order' }, 'text=Place order');
  console.log(`${seen.join(',')} ${risk === null ? 'no-risk' : 'RISK'}`);
})().catch((e) => console.log('ERR ' + e.message));
JS
t  'S6 showStep scrolls the first match with the timeout; stepRisk ignores show' 'text=55th percentile@1234 no-risk' \
   "$(ARIA="$ROOT/browser/lib/aria.cjs" node "$TMP/s6.js" 2>&1)"

# ============================================================= S7 the words
SK="$(tr -s ' \n' '  ' < "$ROOT/browser/skills/use-browser/SKILL.md")"
tc 'S7 SKILL.md lists the show step' '{"op":"show","selector":…}' "$SK"
tc 'S7 ...and tells the agent to end with the proof in the picture' 'End with the proof in the picture' "$SK"
tc 'S7 ...because page.png is only the window' 'only the browser window' "$SK"
tc 'S7 CHANGES.md names the row' 'DIVE-7754' "$(cat "$ROOT/CHANGES.md")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
