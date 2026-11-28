#!/usr/bin/env bash
# DIVE-9506: when the agent is about to stop a turn in which it drove a page with
# 5dive browser, the Stop hook sends it back once with the job's words and the
# three-point finish check. Drives the real hook (browser/hooks/finish-check) with
# the Stop input Claude Code sends and transcripts in Claude Code's JSONL shape
# (user prompt, assistant tool_use, user tool_result, isMeta skill text), as seen in
# the bench rig's nightly-20261128 sessions. Pure node, no Chrome.
#
#   page verb since the turn's prompt            -> {"decision":"block", reason with the job}
#   second stop, turned off, no page verb, a
#   page verb only in an EARLIER turn, bad input -> nothing
set -uo pipefail
cd "$(dirname "$0")/.."
HOOK=browser/hooks/finish-check
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0; LAST=
ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }

# line builders (one JSONL entry each)
prompt()  { node -e 'process.stdout.write(JSON.stringify({type:"user",message:{role:"user",content:process.argv[1]}})+"\n")' "$1"; }
prompt_blocks() { node -e 'process.stdout.write(JSON.stringify({type:"user",message:{role:"user",content:[{type:"text",text:process.argv[1]}]}})+"\n")' "$1"; }
meta()    { node -e 'process.stdout.write(JSON.stringify({type:"user",isMeta:true,message:{role:"user",content:[{type:"text",text:process.argv[1]}]}})+"\n")' "$1"; }
bash_call() { node -e 'process.stdout.write(JSON.stringify({type:"assistant",message:{role:"assistant",content:[{type:"thinking",thinking:""},{type:"tool_use",id:"t",name:"Bash",input:{command:process.argv[1]}}]}})+"\n")' "$1"; }
result()  { node -e 'process.stdout.write(JSON.stringify({type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"t",content:process.argv[1]}]}})+"\n")' "$1"; }
bigresult() { node -e 'process.stdout.write(JSON.stringify({type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"t",content:"x".repeat(+process.argv[1])}]}})+"\n")' "$1"; }
say()     { node -e 'process.stdout.write(JSON.stringify({type:"assistant",message:{role:"assistant",content:[{type:"text",text:process.argv[1]}]}})+"\n")' "$1"; }

stopin() { # stopin <transcript> [active]
  node -e 'process.stdout.write(JSON.stringify({session_id:"s",transcript_path:process.argv[1],cwd:"/",hook_event_name:"Stop",stop_hook_active:process.argv[2]==="1"}))' "$1" "${2:-0}"
}

# expect <name> block|none <transcript> [active [VAR=value...]]
expect() {
  local name=$1 want=$2 tx=$3 act=${4:-0}
  shift 3; [ $# -gt 0 ] && shift
  local out rc
  out=$(stopin "$tx" "$act" | env "$@" "$HOOK"); rc=$?
  [ "$rc" = 0 ] || { bad "$name: exit $rc"; return; }
  if [ "$want" = none ]; then
    [ -z "$out" ] && ok "$name: silent" || bad "$name: wanted silence, got: ${out:0:200}"
    return
  fi
  if LAST=$(printf '%s' "$out" | node -e 'let b="";process.stdin.on("data",c=>b+=c).on("end",()=>{const o=JSON.parse(b);if(o.decision!=="block")process.exit(3);process.stdout.write(o.reason)})' 2>/dev/null); then
    ok "$name: block"
  else bad "$name: wanted a block, got: ${out:0:200}"; fi
}

JOB='Find a nationwide nearest animal shelter for birds around zip 10012, sorted by distance.'
SKILL='Base directory for this skill: use-browser. `5dive browser snapshot <url> --interactive` ...'

# F1: one turn, page verbs, the bench shape (prompt, skill text, calls, results, answer)
{ prompt "$JOB"; meta "$SKILL"; bash_call "5dive browser snapshot https://www.adoptapet.com/ --interactive"; result "ok"
  bash_call "5dive browser act --steps='[{\"op\":\"click\",\"selector\":\"ref=button/Search\"}]'"; result "+ ref=link/x"
  say "ANSWER: Empty Cages Collective"; } > "$T/f1.jsonl"
expect "F1 page verbs this turn" block "$T/f1.jsonl"
case $LAST in *"The job was: \"$JOB\""*) ok "F1b reason quotes the job" ;; *) bad "F1b job not quoted: ${LAST:0:300}" ;; esac
for k in '1. List every condition' "site's own control" '5dive browser snapshot' '3. End with the answer' 'Do not send a message you already sent again'; do
  case $LAST in *"$k"*) ok "F1c reason has: $k" ;; *) bad "F1c reason lacks: $k" ;; esac
done
case $LAST in *'Base directory'*|*'ref=link/x'*) bad "F1d quoted a non-prompt entry" ;; *) ok "F1d skill text and tool results are not the job" ;; esac

# F2: the second stop of a turn (stop_hook_active) stops
expect "F2 second stop" none "$T/f1.jsonl" 1
out=$(stopin "$T/f1.jsonl" 1 | node browser/hooks/finish-check.cjs)
[ -z "$out" ] && ok "F2b cjs alone: stop_hook_active stops" || bad "F2b cjs blocked a second stop"

# F3: turned off
for v in 0 off false no; do expect "F3 FIVEDIVE_BROWSER_FINISH_CHECK=$v" none "$T/f1.jsonl" 0 FIVEDIVE_BROWSER_FINISH_CHECK=$v; done
out=$(stopin "$T/f1.jsonl" | FIVEDIVE_BROWSER_FINISH_CHECK=0 node browser/hooks/finish-check.cjs)
[ -z "$out" ] && ok "F3b cjs alone: off stops" || bad "F3b cjs ignored off"

# F4: a session that never ran 5dive browser
{ prompt "fix the failing test"; bash_call "npm test -- a.test.js"; result "1 passing"; say "Fixed."; } > "$T/f4.jsonl"
expect "F4 no browser in the session" none "$T/f4.jsonl"

# F5: browser used in an EARLIER turn only; this turn is something else
{ cat "$T/f1.jsonl"; prompt "thanks, now summarise the README"; bash_call "cat README.md"; result "# x"; say "Summary."; } > "$T/f5.jsonl"
expect "F5 browser only in an earlier turn" none "$T/f5.jsonl"

# F6: this turn ran only non-page browser verbs
{ prompt "is the browser connected to github?"; bash_call "5dive browser status github.com"; result "connected"; say "Yes."; } > "$T/f6.jsonl"
expect "F6 status only" none "$T/f6.jsonl"

# F7: the prompt arrives as text blocks (a channel message); a later browser turn blocks with ITS job
{ cat "$T/f5.jsonl"; prompt_blocks "Open https://news.ycombinator.com and tell me the top story, newest first."
  bash_call "5dive browser read https://news.ycombinator.com/newest"; result "1. x"; say "Top: x"; } > "$T/f7.jsonl"
expect "F7 later browser turn" block "$T/f7.jsonl"
case $LAST in *'tell me the top story, newest first.'*) ok "F7b quotes this turn's job, not the first" ;; *) bad "F7b wrong job: ${LAST:0:200}" ;; esac

# F8: a big turn — the prompt sits more than 1 MB (one read chunk) before the end
{ prompt "$JOB"; for i in 1 2 3 4 5; do bash_call "5dive browser shot https://example.com/$i"; bigresult 300000; done; say "done"; } > "$T/f8.jsonl"
sz=$(wc -c < "$T/f8.jsonl")
[ "$sz" -gt 1100000 ] && ok "F8a fixture is over one chunk ($sz bytes)" || bad "F8a fixture too small ($sz)"
expect "F8 prompt over a chunk boundary" block "$T/f8.jsonl"
case $LAST in *"$JOB"*) ok "F8b job found across chunks" ;; *) bad "F8b job lost across chunks: ${LAST:0:200}" ;; esac

# F9: a long job is cut to 700 characters
LONG=$(printf 'cheapest first %.0s' $(seq 80))
{ prompt "$LONG"; bash_call "5dive browser read https://example.com"; result ok; say ok; } > "$T/f9.jsonl"
expect "F9 long job" block "$T/f9.jsonl"
q=${LAST#*The job was: \"}; q=${q%%\"*}
if [ "${#q}" -le 700 ] && [ "${q: -1}" = "…" ]; then ok "F9b job cut to ${#q} chars"; else bad "F9b job ${#q} chars: ${q: -20}"; fi

# F10: missing transcript, bad input, no transcript_path
expect "F10 missing transcript" none "$T/nope.jsonl"
out=$(printf 'not json' | "$HOOK"); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "F10b bad input: silent, exit 0" || bad "F10b bad input: rc=$rc out=$out"
out=$(printf '{"stop_hook_active":false}' | node browser/hooks/finish-check.cjs)
[ -z "$out" ] && ok "F10c no transcript_path: silent" || bad "F10c blocked with no transcript"

# F11: a recorded stop-hook reason and a local command echo are not the prompt
{ prompt "$JOB"; bash_call "5dive browser snapshot https://www.adoptapet.com/"; result ok
  prompt "Stop hook feedback: Finish check (5dive browser), once before you stop."; bash_call "5dive browser snapshot"; result ok
  prompt "<local-command-stdout></local-command-stdout>"; say "ANSWER: x"; } > "$T/f11.jsonl"
out=$(stopin "$T/f11.jsonl" | node browser/hooks/finish-check.cjs)
case $out in *"$JOB"*) ok "F11 skips stop-hook feedback and command echoes" ;; *) bad "F11 wrong job: ${out:0:200}" ;; esac

# F12: wiring — hooks.json registers it on Stop, the script is executable, versions agree
node -e '
  const h=require("./browser/hooks/hooks.json").hooks.Stop;
  const c=h&&h[0]&&h[0].hooks[0];
  if(!c||c.type!=="command"||c.command!=="${CLAUDE_PLUGIN_ROOT}/hooks/finish-check") process.exit(1);' \
  && ok "F12a hooks.json: Stop runs finish-check" || bad "F12a hooks.json has no Stop finish-check"
[ -x "$HOOK" ] && ok "F12b hook is executable" || bad "F12b hook not executable"
v=$(node -p 'require("./browser/.claude-plugin/plugin.json").version')
grep -q "(DIVE-9506), $v\$" CHANGES.md && ok "F12c CHANGES names $v" || bad "F12c CHANGES does not name $v"

# M1 mutant: a hook with no page-verb scope blocks F5 — so F5 tests the scope
sed 's/if (!verbs) return null;/\/\/ mutant: no scope/' browser/hooks/finish-check.cjs > "$T/mut.cjs"
out=$(stopin "$T/f5.jsonl" | node "$T/mut.cjs")
[ -n "$out" ] && ok "M1 the no-scope mutant blocks F5 (arm is live)" || bad "M1 mutant silent: F5 does not test the scope"
# M2 mutant: no stop_hook_active check in node blocks a second stop — so F2b tests it
sed 's/if (input.stop_hook_active) return null;//' browser/hooks/finish-check.cjs > "$T/mut2.cjs"
out=$(stopin "$T/f1.jsonl" 1 | node "$T/mut2.cjs")
[ -n "$out" ] && ok "M2 the loop mutant blocks a second stop (F2b is live)" || bad "M2 mutant silent"

echo "finish check: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
