#!/usr/bin/env bash
# DIVE-9500: a failed page fetch tells the agent, on the spot, that 5dive browser
# can open the page. Drives the real hook (browser/hooks/fetch-nudge) with the
# hook input Claude Code sends, built with the real WebFetch result shapes seen in
# fleet transcripts: {code:403, result:"The server returned HTTP 403 ..."}.
#
#   403 / JS wall / timeout / Cloudflare page   -> one line of context
#   a page that came back                       -> nothing
#   API calls, local addresses, non-curl Bash   -> nothing
set -uo pipefail
cd "$(dirname "$0")/.."
HOOK=browser/hooks/fetch-nudge
HINT_RE='^This page needs a real browser: run 5dive browser read https?://[^ ]+ \(or the matching verb\)\.$'
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }

# fixture <event> <tool> <tool_input-json> <response-json-or-error-string-json>
fixture() {
  node -e '
    const [ev, tool, ti, resp] = process.argv.slice(1);
    const o = { session_id: "s", transcript_path: "/dev/null", cwd: "/", hook_event_name: ev,
                tool_name: tool, tool_input: JSON.parse(ti), tool_use_id: "t1" };
    if (ev === "PostToolUseFailure") { o.error = JSON.parse(resp); o.is_interrupt = false; }
    else o.tool_response = JSON.parse(resp);
    process.stdout.write(JSON.stringify(o));
  ' "$@"
}

# expect <name> hint|none [<event>] <fixture args...>
expect() {
  local name=$1 want=$2; shift 2
  local out rc ctx ev
  out=$(fixture "$@" | "$HOOK"); rc=$?
  if [ "$rc" != 0 ]; then bad "$name: exit $rc"; return; fi
  if [ "$want" = none ]; then
    [ -z "$out" ] && ok "$name: silent" || bad "$name: wanted silence, got: $out"
    return
  fi
  ctx=$(printf '%s' "$out" | node -e 'let b="";process.stdin.on("data",c=>b+=c).on("end",()=>{const o=JSON.parse(b);process.stdout.write(o.hookSpecificOutput.hookEventName+"\t"+o.hookSpecificOutput.additionalContext)})' 2>/dev/null)
  ev=${ctx%%$'\t'*}; ctx=${ctx#*$'\t'}
  if [[ "$ctx" =~ $HINT_RE ]] && [ "$ev" = "$1" ]; then ok "$name: hint ($ctx)"; else bad "$name: wanted hint for $1, got: $out"; fi
}

WF='{"url":"https://www.statista.com/statistics/1/x/","prompt":"numbers"}'
# --- WebFetch ---------------------------------------------------------------
expect "W1 WebFetch 403" hint PostToolUse WebFetch "$WF" \
  '{"bytes":0,"code":403,"codeText":"Forbidden","result":"The server returned HTTP 403 Forbidden.\n\nThe response body was not retrieved.","durationMs":234,"url":"https://www.statista.com/statistics/1/x/"}'
expect "W2 WebFetch JS wall (200)" hint PostToolUse WebFetch "$WF" \
  '{"bytes":5463,"code":200,"codeText":"OK","result":"The page only shows: Just a moment... Enable JavaScript and cookies to continue","durationMs":900}'
expect "W3 WebFetch 429" hint PostToolUse WebFetch "$WF" '{"bytes":0,"code":429,"codeText":"Too Many Requests","result":"The server returned HTTP 429 Too Many Requests."}'
expect "W4 WebFetch OK" none PostToolUse WebFetch "$WF" \
  '{"bytes":81234,"code":200,"codeText":"OK","result":"The page lists smartphone shipments for 2025: 1.2 billion units. The site uses JavaScript for its charts.","durationMs":1200}'
expect "W5 WebFetch timeout (failure event)" hint PostToolUseFailure WebFetch "$WF" '"Error: timeout of 60000ms exceeded"'
expect "W6 WebFetch bad input (failure event)" none PostToolUseFailure WebFetch "$WF" '"InputValidationError: The required parameter `prompt` is missing"'
expect "W7 WebFetch 403 on localhost" none PostToolUse WebFetch '{"url":"http://127.0.0.1:3000/x","prompt":"p"}' '{"code":403,"result":"The server returned HTTP 403 Forbidden."}'

# --- Bash curl / wget -------------------------------------------------------
CF='<!DOCTYPE html><html lang="en-US"><head><title>Just a moment...</title><meta http-equiv="Content-Type" content="text/html">'
expect "B1 curl Cloudflare page" hint PostToolUse Bash '{"command":"curl -sL https://linux.do/latest | head -c 400"}' \
  "$(node -e 'process.stdout.write(JSON.stringify({stdout:process.argv[1],stderr:"",interrupted:false}))' "$CF")"
expect "B2 curl -f 403 (failure event)" hint PostToolUseFailure Bash '{"command":"curl -fsS https://opencorporates.com/companies/gb/1"}' \
  '"Exit code 22\ncurl: (22) The requested URL returned error: 403"'
expect "B3 curl -I 403" hint PostToolUse Bash '{"command":"curl -sI https://www.wales247.co.uk/news"}' '{"stdout":"HTTP/2 403 \ndate: Fri, 28 Nov 2026 09:00:00 GMT\nserver: cloudflare\n","stderr":""}'
expect "B4 curl write-out 403" hint PostToolUse Bash "{\"command\":\"curl -s -o /dev/null -w '%{http_code}' https://www.bdaily.co.uk/\"}" '{"stdout":"403","stderr":""}'
expect "B5 wget 403" hint PostToolUseFailure Bash '{"command":"wget -q -O- https://alphasignal.ai/"}' '"Exit code 8\nHTTP request sent, awaiting response... 403 Forbidden\n2026-11-28 09:00:00 ERROR 403: Forbidden."'
expect "B6 curl timeout" hint PostToolUseFailure Bash '{"command":"curl -s --max-time 10 https://hn.algolia.com/?q=x"}' '"Exit code 28\ncurl: (28) Operation timed out after 10001 milliseconds with 0 bytes received"'
expect "B7 curl page OK" none PostToolUse Bash '{"command":"curl -sL https://example.com/"}' '{"stdout":"<!doctype html><html><head><title>Example Domain</title></head><body><h1>Example Domain</h1></body></html>","stderr":""}'
expect "B8 curl API with auth header 403" none PostToolUse Bash "{\"command\":\"curl -s -H 'Authorization: Bearer x' https://example.com/v1/me -i\"}" '{"stdout":"HTTP/2 403 \n","stderr":""}'
expect "B9 curl local 403" none PostToolUse Bash '{"command":"curl -si http://localhost:3001/health"}' '{"stdout":"HTTP/1.1 403 Forbidden\n","stderr":""}'
expect "B10 no curl, wall text in output" none PostToolUse Bash '{"command":"grep -r \"Just a moment\" notes/"}' \
  "$(node -e 'process.stdout.write(JSON.stringify({stdout:"notes/a.md: <title>Just a moment...</title>",stderr:""}))')"
expect "B11 curl api.* host 403" none PostToolUse Bash '{"command":"curl -si https://api.example.com/v1/x"}' '{"stdout":"HTTP/2 403 \n","stderr":""}'
expect "B12 wget -U user agent still a page" hint PostToolUse Bash '{"command":"wget -U Mozilla -O- https://letsdatascience.com/x"}' '{"stdout":"","stderr":"<title>Just a moment...</title> Enable JavaScript and cookies to continue"}'
expect "B13 loop: names the page that failed, not the first" hint PostToolUse Bash \
  "{\"command\":\"for u in https://buffer.com/a https://www.dscca.com/b; do curl -s -o /dev/null -w '%{http_code} \$u\\\\n' \$u; done\"}" \
  '{"stdout":"200 https://buffer.com/a\n403 https://www.dscca.com/b\n","stderr":""}'
out=$(fixture PostToolUse Bash "{\"command\":\"for u in https://buffer.com/a https://www.dscca.com/b; do curl -s -o /dev/null -w '%{http_code} \$u\\\\n' \$u; done\"}" \
  '{"stdout":"200 https://buffer.com/a\n403 https://www.dscca.com/b\n","stderr":""}' | "$HOOK")
case $out in *dscca.com/b*) ok "B13b hint names https://www.dscca.com/b" ;; *) bad "B13b wrong page named: $out" ;; esac
expect "B14 curl -I 503 (server down, not a wall)" none PostToolUse Bash '{"command":"curl -sI https://example.org/"}' '{"stdout":"HTTP/2 503 \nserver: nginx\n","stderr":""}'
expect "B15 URL built from a shell variable" none PostToolUse Bash '{"command":"for h in a b; do curl -si https://$h.example.net/; done"}' '{"stdout":"HTTP/2 403 \n","stderr":""}'

# --- Cheap path: a Bash call without curl/wget never starts node --------------
FAKE=$(mktemp -d); trap 'rm -rf "$FAKE"' EXIT
printf '#!/bin/sh\necho started >> "%s/node.log"\nexec %s "$@"\n' "$FAKE" "$(command -v node)" > "$FAKE/node"; chmod +x "$FAKE/node"
fixture PostToolUse Bash '{"command":"ls -la"}' '{"stdout":"total 0","stderr":""}' | PATH="$FAKE:$PATH" "$HOOK" >/dev/null
[ ! -s "$FAKE/node.log" ] && ok "C1 non-curl Bash: node not started" || bad "C1 non-curl Bash started node"
fixture PostToolUse Bash '{"command":"curl -s https://example.com/"}' '{"stdout":"ok","stderr":""}' | PATH="$FAKE:$PATH" "$HOOK" >/dev/null
[ -s "$FAKE/node.log" ] && ok "C2 curl Bash: node started (the fake is live)" || bad "C2 fake node never ran: C1 proves nothing"
# No node on the box (browser setup not run): silent, exit 0.
out=$(fixture PostToolUse WebFetch "$WF" '{"code":403,"result":"x"}' | PATH=/nonexistent /bin/bash "$HOOK"); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "C3 no node: silent, exit 0" || bad "C3 no node: rc=$rc out=$out"
# Garbage on stdin: silent, exit 0.
out=$(printf 'not json WebFetch' | "$HOOK"); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "C4 bad input: silent, exit 0" || bad "C4 bad input: rc=$rc out=$out"

# --- Wiring: hooks.json is what Claude Code loads ----------------------------
node -e '
  const h = require("./browser/hooks/hooks.json").hooks;
  for (const ev of ["PostToolUse", "PostToolUseFailure"]) {
    const e = (h[ev] || []).find((x) => /WebFetch/.test(x.matcher) && /Bash/.test(x.matcher));
    if (!e || e.hooks[0].command !== "${CLAUDE_PLUGIN_ROOT}/hooks/fetch-nudge") process.exit(1);
  }' && ok "H1 hooks.json wires PostToolUse + PostToolUseFailure on WebFetch|Bash" || bad "H1 hooks.json wiring"
[ -x "$HOOK" ] && ok "H2 hook is executable" || bad "H2 hook not executable"

# --- Mutant: a hook that hints on every fetch must go red here ---------------
MUT=$(mktemp -d); cp -r browser/hooks/. "$MUT/"
sed -i 's/^  if (input.tool_name === .WebFetch.) return webfetch(input);/  if (input.tool_name === "WebFetch") return HINT(String(input.tool_input?.url));/' "$MUT/fetch-nudge.cjs"
out=$(fixture PostToolUse WebFetch "$WF" '{"code":200,"result":"fine"}' | "$MUT/fetch-nudge")
[ -n "$out" ] && ok "M1 mutant (hint always) fires on an OK page, so W4 can catch it" || bad "M1 mutant did not change behaviour: sed missed"
rm -rf "$MUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
