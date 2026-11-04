#!/usr/bin/env bash
# DIVE-7701 — a text field the page is swapping is waited for, not called missing.
#
# main CI's routine-bench went red on live en.wikipedia.org (3 of 20 runs on
# 2026-11-04): replay's press re-derived `combobox/Search Wikipedia`, saw only
# the old `searchbox` (the typeahead had not mounted yet), picked it as the same
# field, and by the next walk it was gone too — "matches nothing either".
# Wikipedia REMOVES the server-rendered input and mounts a new one, so for a
# moment neither is on the page.
#
# Graded on a page stub whose walks are scripted, one per call, so the swap
# window is exact (no Chrome on this host). The control arm runs the same
# script with the wait set to 0 ms: the old one-shot behaviour, and it must fail.
set -uo pipefail
cd "$(dirname "$0")/.."
export ARIA="$PWD/browser/lib/aria.cjs"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }

cat > "$TMP/swap.js" <<'JS'
const aria = require(process.env.ARIA);
// argv: <op> <selector> <waitMs> <walk>... ; a walk is refs joined by ',' ('-' = none).
// The last walk repeats once the script runs out.
const [op, selector, waitMs, ...walks] = process.argv.slice(2);
let k = 0;
const page = {
  url: async () => 'about:blank',
  evaluate: async (fn, arg) => {
    if (fn !== aria.pageWalk || !arg || !arg.mark) return null;
    const w = walks[Math.min(k++, walks.length - 1)];
    const nodes = w === '-' ? [] : w.split(',').map((ref) => ({ ref, role: ref.split('/')[0], name: ref.split('/')[1].replace(/#\d+$/, '') }));
    return { nodes, marker: nodes.some((n) => n.ref === arg.mark) ? `m${k}` : null };
  },
};
const t0 = Date.now();
aria.resolveOrRepick(page, { op, selector, key: 'Enter', value: 'x' }, 3, { fieldSwapMs: Number(waitMs) })
  .then((r) => console.log(JSON.stringify({ ok: true, sel: r.sel, retry: r.retry, walks: k, ms: Date.now() - t0 })))
  .catch((e) => console.log(JSON.stringify({ ok: false, miss: !!e.refMiss, err: e.message, walks: k, ms: Date.now() - t0 })));
JS
run() { node "$TMP/swap.js" "$@"; }
j() { jq -r "$1" <<<"$2"; }
CB='combobox/Search Wikipedia'; SB='searchbox/Search Wikipedia'

# --- S1 the bench's red, exactly: recorded combobox; walk 1 shows the old searchbox,
# the pick's walk finds neither, then the combobox mounts.
R=$(run press "ref=$CB" 3000 "$SB" - - "$CB")
t  'S1 the swap window is waited out: the step resolves' true "$(j .ok "$R")"
t  'S1 ...on the ref as recorded, so nothing is re-picked' null "$(j .retry "$R")"
C=$(run press "ref=$CB" 0 "$SB" - - "$CB")
t  'S1 CONTROL: with no wait (the old one-shot path) it is the bench red' false "$(j .ok "$C")"
tc 'S1 CONTROL: ...with the bench message' 'and that matches nothing either' "$(j .err "$C")"

# --- S2 recorded searchbox (headless never mounts), page now shows a combobox that
# is itself swapped once: the role-swapped twin is found on a later walk.
R=$(run fill "ref=$SB" 3000 "$CB" - "$CB" "$CB")
t  'S2 the same field under another role, found on a later walk' true "$(j .ok "$R")"
tc 'S2 ...and said as the name match the routine recorder reads' "name match picked ref=$CB" "$(j .retry "$R")"

# --- S3 the field never comes back: it still fails, after the bounded wait only.
R=$(run press "ref=$CB" 600 "$SB" -)
t  'S3 a field that never returns still fails' false "$(j .ok "$R")"
tc 'S3 ...naming the twin it saw' "picked ref=$SB, and that matches nothing either" "$(j .err "$R")"
MS=$(j .ms "$R"); (( MS >= 500 && MS < 2500 )); t "S3 ...within its wait (600 ms; took ${MS} ms)" 0 $?

# --- S4 only text fields wait: a button that misses fails at once (DIVE-4674's one-shot).
R=$(run click "ref=button/Decline" 3000 - - "button/Decline")
t  'S4 a button miss is not waited for' false "$(j .ok "$R")"
t  'S4 ...one walk, no polling' 1 "$(j .walks "$R")"

# --- S5 two twins is not "the same field": nothing is picked, as before.
R=$(run press "ref=$SB" 300 "$CB,textbox/Search Wikipedia" -)
t  'S5 two field roles answer: no pick' false "$(j .ok "$R")"

# --- S7 no twin in walk 1 = DIVE-4674's one look (quinn, DIVE-7701 it1). A textbox
# that is plainly absent is not "mid-swap": it refuses on the first walk with the
# refMiss the driver turns into rc 70, even though a later walk WOULD show it
# (that later walk is the poll T28g-i forbid). The default 5 s wait is in force.
for op in click fill; do
  R=$(run "$op" 'ref=textbox/Add a comment' 5000 - 'textbox/Add a comment')
  t  "S7 $op on a textbox with no twin in walk 1: refused" false "$(j .ok "$R")"
  t  "S7 ...as a refMiss (the driver's rc 70)" true "$(j .miss "$R")"
  tc "S7 ...with the one-shot text" 'matches nothing on this page' "$(j .err "$R")"
  t  "S7 ...having looked EXACTLY ONCE" 1 "$(j .walks "$R")"
  MS=$(j .ms "$R"); (( MS < 1000 )); t "S7 ...at once, not after the wait (took ${MS} ms)" 0 $?
done
# MUTANT: drop the twin gate so every field miss waits (iteration 1 as delivered).
# S7 must go red on it, or the arm does not grade the gate.
mkdir -p "$TMP/mut"; cp "$ARIA" "$TMP/mut/aria.cjs"
perl -pi -e 's/if \(twin && FIELD_ROLES\.includes\(role\)/if (FIELD_ROLES.includes(role)/' "$TMP/mut/aria.cjs"
t  'S7 (anchor) the mutation landed' 1 "$(grep -c "if (FIELD_ROLES.includes(role) && step.op !== 'wait_for')" "$TMP/mut/aria.cjs")"
R=$(ARIA="$TMP/mut/aria.cjs" run click 'ref=textbox/Add a comment' 5000 - 'textbox/Add a comment')
t  'S7 MUTANT: without the twin gate the click polls into a success' true "$(j .ok "$R")"
t  'S7 MUTANT: ...on a second look' 2 "$(j .walks "$R")"

# --- S6 the default wait covers a script load on a slow runner.
t  'S6 FIELD_SWAP_MS is 5 s' 5000 "$(node -e 'process.stdout.write(String(require(process.env.ARIA).FIELD_SWAP_MS))')"

echo "browser_field_swap_unit: $PASS pass, $FAIL fail"
(( FAIL == 0 ))
