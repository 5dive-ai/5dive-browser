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

# DIVE-6334: round 6's Gamma did not clear in 30 s from cic-arm-a. A challenge
# that holds for 45 s and then clears is waited out by the SHIPPED bound (1.42.1:
# 30 s, so not cleared), and one that never clears is still bounded, at 90 s.
held() { local n="$1" a=(); for ((k = 0; k < n; k++)); do a+=('Just a moment...'); done; a+=('Gamma'); w default "${a[@]}"; }
t 'I13 a challenge held 45 s then cleared: the default bound waits it out' \
  '{"title":"Just a moment...","cleared":true,"waited_ms":45000} clock=45000' "$(held 45)"
t 'I14 one that never clears: stops at the 90 s default, then the STOP (handoff) applies' \
  '{"title":"Just a moment...","cleared":false,"waited_ms":90000} clock=90000' "$(w default 'Just a moment...')"
t 'I15 FIVEDIVE_BROWSER_INTERSTITIAL_WAIT_MS still sets the bound' \
  '{"title":"Just a moment...","cleared":false,"waited_ms":20000} clock=20000' \
  "$(FIVEDIVE_BROWSER_INTERSTITIAL_WAIT_MS=20000 w default 'Just a moment...')"

# Every executor goto calls it: the two snapshot paths, render, both act gotos, and readMode's goto.
t "I8 driver-playwright calls it after its snapshot goto, its act goto and readMode's goto" 3 "$(grep -c 'aria.waitInterstitial(page)' browser/bin/driver-playwright)"
t 'I9 session-daemon calls it after snapshot, render, read (DIVE-6771) and the act goto' 4 "$(grep -cE 'aria\.waitInterstitial\(page[,)]' browser/bin/session-daemon)"

# bin/browser's STOP says the wait happened when the payload says it did not clear.
HTML=$(mktemp); trap 'rm -f "$HTML"' EXIT
printf '<html><head><title>Just a moment...</title></head><body></body></html>' > "$HTML"
hint() { bash -c 'PROG="5dive browser"; CHALLENGE_TITLE_MARKER='"'"'(captcha|just a moment)'"'"'
  _render_title() { grep -oiE "<title[^>]*>[^<]{1,200}" "$1" | head -n1 | sed -E "s/<title[^>]*>//"; }
  eval "$(sed -n "/^_challenge_hint() {/,/^}/p" browser/bin/browser)"; _challenge_hint "$@"' _ "$@" 2>&1; }
H=$(hint "$HTML" https://gamma.app/ '' 30000)   # captured: grep -q on a pipe would SIGPIPE it under pipefail
t 'I10 the STOP after a wait says how long, and that a reload starts the check over' yes \
  "$(grep -q 'watched "Just a moment..." for 30 s in this same page load' <<<"$H" && echo yes || echo no)"
t 'I11 ...and still prints the STOP' yes "$(grep -q 'STOP — this page is a security check' <<<"$H" && echo yes || echo no)"
t 'I12 with no wait reported, only the STOP' 1 "$(hint "$HTML" https://gamma.app/ | wc -l | tr -d ' ')"

printf 'interstitial: %d pass, %d fail\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
