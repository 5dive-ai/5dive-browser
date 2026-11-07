#!/usr/bin/env bash
# DIVE-6317 — lib/aria.cjs waitInterstitial: Cloudflare's "Just a moment..." is
# watched in the SAME page load before anything calls it a stop.
#
# Round 5 (1.41.0) stopped gamma.app at the first sight of that title; the agent
# then slept 20 s and loaded the page again, which starts the check over. The
# executors (bin/driver-playwright, bin/session-daemon) now call waitInterstitial
# right after each goto. A fake page stands in for Playwright's: its title()
# answers from a script of titles, waitForTimeout only advances a clock.
set -uo pipefail
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
t() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
# w <timeout ms> <title>... -> the JSON waitInterstitial returned, and how long the fake clock ran
w() { node -e '
  const aria = require("./browser/lib/aria.cjs");
  const [timeoutMs, ...titles] = process.argv.slice(1);
  let clock = 0, i = 0;
  const page = {
    title: async () => { const v = titles[Math.min(i++, titles.length - 1)]; if (v === "THROW") throw new Error("navigating"); return v; },
    waitForTimeout: async (ms) => { clock += ms; },
  };
  // "default": the shipped bound, as the executors call it (no timeoutMs).
  aria.waitInterstitial(page, timeoutMs === "default" ? { pollMs: 1000 } : { timeoutMs: Number(timeoutMs), pollMs: 1000 })
    .then((r) => console.log(JSON.stringify(r) + " clock=" + clock));
' "$@"; }

t 'I1 an ordinary page is not waited on at all' 'null clock=0' "$(w 30000 'Gamma')"
t 'I2 "Just a moment..." that clears on the 3rd look: cleared, 3 s' \
  '{"title":"Just a moment...","cleared":true,"waited_ms":3000} clock=3000' \
  "$(w 30000 'Just a moment...' 'Just a moment...' 'Just a moment...' 'Gamma')"
t 'I3 a title read mid-navigation (it throws) is not taken as cleared' \
  '{"title":"Just a moment...","cleared":true,"waited_ms":2000} clock=2000' \
  "$(w 30000 'Just a moment...' 'THROW' 'Gamma')"
t 'I4 one that never clears: not cleared, bounded by the timeout' \
  '{"title":"Just a moment...","cleared":false,"waited_ms":30000} clock=30000' \
  "$(w 30000 'Just a moment...')"
t 'I5 "Checking your browser before accessing" is the same interstitial' 'true' \
  "$(w 5000 'Checking your browser before accessing x' 'X' | sed 's/ clock=.*//' | jq -r '.cleared')"
t 'I6 NEGATIVE: "Attention Required!" (a block) is not waited on' 'null clock=0' "$(w 30000 'Attention Required! | Cloudflare')"
t 'I7 NEGATIVE: "Access denied" is not waited on' 'null clock=0' "$(w 30000 'Access denied')"

# DIVE-6334: round 6's Gamma did not clear in 30 s from cic-arm-a, so the bound
# went to 90 s. DIVE-7303: on the fresh-100 bench none of ten cleared in 90 s and
# they were a fifth of snapshot time, so the shipped bound is 20 s: a check that
# clears by itself (5-15 s) is still waited out, one that stays costs 20 s.
held() { local n="$1" a=(); for ((k = 0; k < n; k++)); do a+=('Just a moment...'); done; a+=('Gamma'); w default "${a[@]}"; }
t 'I13 a challenge held 15 s then cleared: the default bound waits it out' \
  '{"title":"Just a moment...","cleared":true,"waited_ms":15000} clock=15000' "$(held 15)"
t 'I13b a challenge held 45 s: the default bound stops at 20 s, not cleared (DIVE-7303)' \
  '{"title":"Just a moment...","cleared":false,"waited_ms":20000} clock=20000' "$(held 45)"
t 'I14 one that never clears: stops at the 20 s default, then the STOP (handoff) applies' \
  '{"title":"Just a moment...","cleared":false,"waited_ms":20000} clock=20000' "$(w default 'Just a moment...')"
t 'I15 FIVEDIVE_BROWSER_INTERSTITIAL_WAIT_MS still sets the bound (the old 90 s)' \
  '{"title":"Just a moment...","cleared":true,"waited_ms":45000} clock=45000' \
  "$(FIVEDIVE_BROWSER_INTERSTITIAL_WAIT_MS=90000 held 45)"

# Every executor goto calls it: the two snapshot paths, render, both act gotos, and readMode's goto.
t "I8 driver-playwright calls it after its snapshot goto, its act goto and readMode's goto" 3 "$(grep -c 'aria.waitInterstitial(page)' browser/bin/driver-playwright)"
t 'I9 session-daemon calls it after snapshot, render, read (DIVE-6771) and the act goto' 4 "$(grep -cE 'aria\.waitInterstitial\(page[,)]' browser/bin/session-daemon)"

# bin/browser's hint says the wait happened when the payload says it did not clear.
# DIVE-7881 (1.72.0): an ungated robot check is handed back to the agent to clear
# (no STOP); only an owner's `gate on <site|all> robot` turns the STOP back on.
HTML=$(mktemp); trap 'rm -f "$HTML"' EXIT
printf '<html><head><title>Just a moment...</title></head><body></body></html>' > "$HTML"
# GATED=1 stands in for an owner who ran `sudo 5dive browser gate on gamma.app robot`.
hint() { GATED="${GATED:-0}" bash -c 'PROG="5dive browser"; CHALLENGE_TITLE_MARKER='"'"'(captcha|just a moment)'"'"'
  _render_title() { grep -oiE "<title[^>]*>[^<]{1,200}" "$1" | head -n1 | sed -E "s/<title[^>]*>//"; }
  [[ "$GATED" == 1 ]] && _gate_on() { [[ "$1" == robot && "$2" == gamma.app ]]; }
  eval "$(sed -n "/^_challenge_hint() {/,/^}/p" browser/bin/browser)"; _challenge_hint "$@"' _ "$@" 2>&1; }
has() { grep -qF -- "$1" <<<"$2" && echo yes || echo no; }
H=$(hint "$HTML" https://gamma.app/ '' 30000)   # captured: grep -q on a pipe would SIGPIPE it under pipefail
t 'I10 after a wait the hint says how long, and that a reload starts the check over' yes \
  "$(has 'watched "Just a moment..." for 30 s in this same page load' "$H")"
t 'I11 ungated: the page is handed back to the agent, no STOP' 'yes no' \
  "$(has 'It is yours to clear, like a person would' "$H") $(has 'STOP' "$H")"
t 'I11b ungated after a wait: the two lines agree (no "wait and look again" after a wait that did not clear)' 'yes no' \
  "$(has 'do not wait on it longer' "$H") $(has 'look again' "$H")"
H0=$(hint "$HTML" https://gamma.app/)
t 'I12 ungated with no wait reported: one line, the hand-back, which still offers the short wait' '1 yes no' \
  "$(wc -l <<<"$H0" | tr -d ' ') $(has 'wait 5-10 s and look again' "$H0") $(has 'STOP' "$H0")"
HG=$(GATED=1 hint "$HTML" https://gamma.app/ '' 30000)
t 'I16 gated (gate on gamma.app robot): still prints the STOP, not the hand-back' 'yes no' \
  "$(has 'STOP — this page is a security check' "$HG") $(has 'It is yours to clear' "$HG")"
t 'I16b gated: the STOP names the gate and the connect-request for that site' 'yes yes' \
  "$(has '(gate robot)' "$HG") $(has 'connect-request gamma.app --challenge --url=https://gamma.app/' "$HG")"
t 'I16c a gate on another site does not stop this one' 'no' \
  "$(has 'STOP' "$(GATED=1 hint "$HTML" https://example.com/)")"

printf 'interstitial: %d pass, %d fail\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
