#!/usr/bin/env bash
# DIVE-8755 — the end-of-task applied-filter check (browser/hooks/applied-check.cjs).
#
# The hook is driven the way Claude Code drives it: the command from hooks.json,
# with ${CLAUDE_PLUGIN_ROOT} expanded, JSON on stdin, a JSONL transcript on disk.
# Each arm is one clause of the contract in the hook's header; the M arms run a
# MUTANT with the loop guards cut out and must see it block twice, so a green A4/A5
# is a property of the guards and not of a fixture that could never loop.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"; PLUG="$ROOT/browser"
TMP="$(mktemp -d)"; trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
export FIVEDIVE_BROWSER_APPLIED_STATE_DIR="$TMP/state"
unset FIVEDIVE_BROWSER_APPLIED_CHECK

PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }

# The command exactly as hooks.json names it.
CMD="$(node -e 'const h=require(process.argv[1]);console.log(h.hooks.Stop[0].hooks[0].command)' "$PLUG/hooks/hooks.json")"
CMD="${CMD//\$\{CLAUDE_PLUGIN_ROOT\}/$PLUG}"
HOOK="$CMD"
run() { # run <session> <transcript> [stop_hook_active] -> stdout; exit code via rc()
  local out; out="$(printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"Stop","stop_hook_active":%s}' "$1" "$2" "${3:-false}" | $HOOK)"; echo $? > "$TMP/rc"; printf '%s' "$out"
}
rc() { cat "$TMP/rc"; }

# --- transcript builders -----------------------------------------------------
u()  { printf '{"type":"user","uuid":"%s","message":{"role":"user","content":%s}}\n' "$1" "$(node -e 'console.log(JSON.stringify(process.argv[1]))' "$2")"; }
tr() { printf '{"type":"user","uuid":"r%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t%s","content":"ok"}]}}\n' "$1" "$1"; }
bash_call() { printf '{"type":"assistant","uuid":"a%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"t%s","name":"Bash","input":{"command":%s}}]}}\n' "$1" "$1" "$(node -e 'console.log(JSON.stringify(process.argv[1]))' "$2")"; }
say() { printf '{"type":"assistant","uuid":"s%s","message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}\n' "$1" "$2"; }

ACT="5dive browser act _public https://www.example-shop.com/s?q=boots --steps='[{\"op\":\"click\",\"selector\":\"ref=button/Search\"}]'"

# T1 — the manifest wires a Stop hook to an executable file that exists.
t "T1 hooks.json names a Stop command" "1" "$(node -e 'const h=require(process.argv[1]);console.log(h.hooks.Stop.length)' "$PLUG/hooks/hooks.json")"
[[ -x "$PLUG/hooks/applied-check.cjs" ]]; t "T1 hook file is executable" "0" "$?"
tc "T1 command is plugin-root relative" '${CLAUDE_PLUGIN_ROOT}/hooks/applied-check.cjs' "$(cat "$PLUG/hooks/hooks.json")"
# A manifest "hooks" key naming the default file makes Claude Code load it twice
# and refuse the plugin ("duplicate hooks file"); auto-discovery is the path.
t "T1 plugin.json does not re-declare hooks/hooks.json" "" "$(node -e 'const m=require(process.argv[1]);console.log(m.hooks??"")' "$PLUG/.claude-plugin/plugin.json")"

# A1 — a turn with no browser call is never touched.
{ u p1 "what is 2+2"; bash_call 1 "echo 4"; tr 1; say 1 "4"; } > "$TMP/a1.jsonl"
out="$(run s-a1 "$TMP/a1.jsonl")"; t "A1 no browser call: no block" "" "$out"; t "A1 exit 0" "0" "$(rc)"

# A2 — a turn that drove the browser is blocked once, with the checklist.
{ u p1 "find boots under 50 sorted by price low to high"; bash_call 1 "$ACT"; tr 1; say 1 "Found them."; } > "$TMP/a2.jsonl"
out="$(run s-a2 "$TMP/a2.jsonl")"
t  "A2 decision is block" "block" "$(printf '%s' "$out" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).decision))')"
tc "A2 reason carries the tag" "[browser applied-check]" "$out"
tc "A2 reason names the sort label" "sort control" "$out"
tc "A2 reason reads in place, no reload" "(no URL)" "$out"
tc "A2 reason lets a no-filter task answer" "names no filter, sort or condition" "$out"
t  "A2 exit 0 (JSON decision, not exit 2)" "0" "$(rc)"

# A3 — Claude Code's stop_hook_active: the continuation it forced is never blocked again.
out="$(run s-a3 "$TMP/a2.jsonl" true)"; t "A3 stop_hook_active: no block" "" "$out"

# A4 — second stop in the same owner message, a harness that drops stop_hook_active
# and records no feedback: the state file still lets it through.
run s-a4 "$TMP/a2.jsonl" >/dev/null
{ cat "$TMP/a2.jsonl"; bash_call 2 "5dive browser act _public --steps='[{\"op\":\"eval\",\"expr\":\"location.href\"}]'"; tr 2; say 2 "Sorted by price, chip Under 50 on."; } > "$TMP/a4.jsonl"
out="$(run s-a4 "$TMP/a4.jsonl")"; t "A4 once per owner message (state file)" "" "$out"

# A5 — the feedback is in the transcript (any shape) on a fresh state: still once.
{ cat "$TMP/a2.jsonl"; printf '{"type":"user","isMeta":true,"uuid":"f1","message":{"role":"user","content":"Stop hook feedback:\\n[browser applied-check] Before you answer…"}}\n'; say 2 "Checked."; } > "$TMP/a5.jsonl"
out="$(run s-a5 "$TMP/a5.jsonl")"; t "A5 tag already in the turn: no block" "" "$out"
{ cat "$TMP/a2.jsonl"; printf '{"type":"attachment","uuid":"f2","attachment":{"type":"hook_blocking_error","blockingError":"[browser applied-check] Before you answer…"}}\n'; say 2 "Checked."; } > "$TMP/a5b.jsonl"
out="$(run s-a5b "$TMP/a5b.jsonl")"; t "A5 tag as an attachment entry: no block" "" "$out"

# A6 — a NEW owner message that drives the browser again is checked again.
{ cat "$TMP/a4.jsonl"; u p2 "now the same for sandals, newest first"; bash_call 3 "$ACT"; tr 3; say 3 "Done."; } > "$TMP/a6.jsonl"
out="$(run s-a4 "$TMP/a6.jsonl")"; tc "A6 next owner message is checked again" "[browser applied-check]" "$out"

# A7 — browser calls only in an EARLIER turn do not count for this one.
{ cat "$TMP/a2.jsonl"; u p2 "thanks, and what time is it"; bash_call 4 "date"; tr 4; say 4 "12:00"; } > "$TMP/a7.jsonl"
out="$(run s-a7 "$TMP/a7.jsonl")"; t "A7 browser only in a past turn: no block" "" "$out"

# A8 — the off switch (a control arm can run the same build without the check).
out="$(FIVEDIVE_BROWSER_APPLIED_CHECK=0 run s-a8 "$TMP/a2.jsonl")"; t "A8 FIVEDIVE_BROWSER_APPLIED_CHECK=0: no block" "" "$out"

# A9 — fails open.
out="$(printf 'not json' | $HOOK; echo "rc=$?")"; t "A9 garbage stdin: exit 0" "rc=0" "$out"; out="${out%rc=0}"; t "A9 garbage stdin: silent" "" "$out"
out="$(run s-a9 "$TMP/missing.jsonl")"; t "A9 missing transcript: silent" "" "$out"; t "A9 missing transcript: exit 0" "0" "$(rc)"
{ cat "$TMP/a2.jsonl"; printf '{"type":"assist'; } > "$TMP/a9.jsonl"
out="$(run s-a9b "$TMP/a9.jsonl")"; tc "A9 torn last line is skipped, not fatal" "[browser applied-check]" "$out"

# A10 — what counts as a browser call.
cnt() { node -e 'const {BROWSER_CALL}=require(process.argv[1]);console.log(BROWSER_CALL.test(process.argv[2])?1:0)' "$PLUG/hooks/applied-check.cjs" "$1"; }
t "A10 5dive browser snapshot counts" 1 "$(cnt '5dive browser snapshot _public https://x.com/ --interactive')"
t "A10 5dive browser act (no URL) counts" 1 "$(cnt "5dive browser act _public --steps='[]'")"
t "A10 bin/browser read counts" 1 "$(cnt '/var/lib/5dive/plugins/cache/5dive-browser/browser/1.95.0/bin/browser read _public https://x.com/')"
t "A10 after a cd && counts" 1 "$(cnt 'cd /tmp && 5dive browser links _public https://x.com/')"
t "A10 status does not count" 0 "$(cnt '5dive browser status _public')"
t "A10 connect-request does not count" 0 "$(cnt '5dive browser connect-request x.com')"
t "A10 a bare browser does not count" 0 "$(cnt 'browser act foo')"
t "A10 a longer word starting with a verb does not count" 0 "$(cnt '5dive browser actions')"

# M — mutants. Cut guard 1 + guard 3 and a harness that records no feedback MUST
# loop (block on the second stop); cut the turn scoping and A7 MUST block.
mkdir -p "$TMP/m1/hooks" "$TMP/m2/hooks"
sed -e 's/if (input.stop_hook_active === true) return null;/\/\/ cut/' -e 's/if (input.session_id) {/if (false) {/' \
  "$PLUG/hooks/applied-check.cjs" > "$TMP/m1/hooks/applied-check.cjs"
HOOK="node $TMP/m1/hooks/applied-check.cjs"
run m1 "$TMP/a2.jsonl" >/dev/null; out="$(run m1 "$TMP/a4.jsonl" true)"
tc "M1 mutant without guards 1+3 blocks a second time (A3/A4 are live)" "[browser applied-check]" "$out"
sed -e 's/const turn = entries.slice(start + 1);/const turn = entries;/' "$PLUG/hooks/applied-check.cjs" > "$TMP/m2/hooks/applied-check.cjs"
HOOK="node $TMP/m2/hooks/applied-check.cjs"
out="$(run m2 "$TMP/a7.jsonl")"; tc "M2 mutant without turn scoping blocks A7 (A7 is live)" "[browser applied-check]" "$out"
HOOK="$CMD"

printf 'applied-check: %d pass, %d fail\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
