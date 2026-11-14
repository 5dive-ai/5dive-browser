#!/usr/bin/env bash
# DIVE-8331 — an agent whose on-demand start finds the owner's sign-in window
# still open is told so, not "no browser answers on its socket".
#
# Box report 933 (wry-rune, 2026-11-13): an API deploy cut the owner's Done for
# vk.com in half, so the sign-in browser (a `serve --login`, plain Chrome) stayed
# up with its view live. The agent's `snapshot vk.com` woke the box browser
# through `_serve-offered`, whose `serve vk.com --no-switch` answered "already
# serving", exited 0 and left no daemon, so the agent was told "it started, but
# no browser answers on its socket" twice and could not tell the owner anything.
#
# Driven through the real bin/browser. One uid plays both seats: the box seat is
# this user, the agent is FIVEDIVE_BROWSER_SEAT=agent-borrower, and the root hop
# (`sudo -n … _serve-offered`) is the FIVEDIVE_BROWSER_WAKE_PRIV seam pointed at
# the same binary. The sign-in browser is a pidfile naming live `sleep`s.
#
#   L1  login serve up, its view live: the brokered snapshot exits 69 and says
#       vk.com is still open in the owner's sign-in window, press Done
#   L1b ...and does NOT say the socket catch-all, nor send anyone to `serve`
#   L1c DIVE-8450: ...and names the admin stop (`serve <site> --stop`, which keeps
#       the login), for a Done that never arrives
#   L2  `_serve-offered` itself fails (non-zero) with the same words, instead of
#       the 0 that started nothing
#   L3  login serve up, NO view, no session daemon on the box: "no warm session
#       on this box: playwright-core is not installed"
#   L4  nothing served at all and nothing can start: the old words still stand
#       (this change only names the two states root can see)
#   N1  NEGATIVE CONTROL: origin/main's bin/browser gives L1's case the socket
#       catch-all (run with BROKER_LOGIN_BIN=<old bin/browser>; L1/L1b/L2 go red)
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="${BROKER_LOGIN_BIN:-$ROOT/browser/bin/browser}"

TMP="$(mktemp -d)"
PIDS=()
trap 'rc=$?; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0
arm() {  # arm <name> <expected> <got>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi
}
has() { if grep -qF -- "$1" <<<"$2"; then echo yes; else echo no; fi; }

export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/profiles"
export FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/adapters"; mkdir -p "$FIVEDIVE_BROWSER_ADAPTER_DIR"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/rv"
export FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/no-session-daemon"
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli"
export FIVEDIVE_BROWSER_TMP_ROOT="$TMP/tmproot"
export FIVEDIVE_BROWSER_SERVE_MIN_MB=0
export FIVEDIVE_BROWSER_WAKE_PRIV="$BROWSER"
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
ME="$(id -un)"
AG=agent-borrower
export FIVEDIVE_BROWSER_BOX_SEAT="$ME"
SITE=vk.com
DIR="$FIVEDIVE_BROWSER_PROFILE_ROOT/$ME/$SITE"

mkdir -p "$DIR" "$FIVEDIVE_BROWSER_SESSION_ROOT/$ME" "$FIVEDIVE_BROWSER_TMP_ROOT"
chmod 700 "$FIVEDIVE_BROWSER_PROFILE_ROOT/$ME" "$DIR"
# The box offers vk.com to the box's other seats (what Connect leaves behind).
: > "$FIVEDIVE_BROWSER_SESSION_ROOT/$ME/$SITE.offered"

# Never inside $( ): the sleep would hold the substitution's pipe open.
LIVE=""; live() { sleep 600 >/dev/null 2>&1 </dev/null & LIVE=$!; PIDS+=("$LIVE"); }
login_serve() {  # a `serve --login` that is up: Xvfb and plain Chrome, no daemon
  local x c; live; x=$LIVE; live; c=$LIVE
  printf 'site=%s\ndisplay=496\nxvfb_pid=%s\nchrome_pid=%s\nlogin=1\n' "$SITE" "$x" "$c" > "$DIR/.5dive-serve"
}
view_live() { live; printf 'vnc_pid=%s\n' "$LIVE" > "$DIR/.5dive-viewer"; }
unserve() { rm -f "$DIR/.5dive-serve" "$DIR/.5dive-viewer"; }

snap() { FIVEDIVE_BROWSER_SEAT="$AG" timeout "${SNAP_T:-60}" ${SNAP_TRACE:+bash -x} "$BROWSER" snapshot "$SITE" "https://$SITE/" --no-shot 2>&1; }

# L1: the report's state.
login_serve; view_live
out=$(snap); rc=$?
arm "L1 exit is 69 (unavailable)" 69 "$rc"
arm "L1 says the owner's sign-in window is still open" yes "$(has "$SITE is still open in the owner's sign-in window" "$out")"
arm "L1 asks for the owner's Done" yes "$(has "ask them to press Done on $SITE" "$out")"
arm "L1b not the socket catch-all" no "$(has "no browser answers on its socket" "$out")"
arm "L1b does not send anyone to \`serve\` (it only answers 'already serving')" no "$(has "5dive browser serve $SITE" "${out//5dive browser serve $SITE --stop/}")"
# DIVE-8450 (report 975): a Done that never arrives must not be the only way out.
arm "L1c names the admin stop that needs nobody at the window" yes "$(has "sudo 5dive browser serve $SITE --stop" "$out")"
arm "L1c ... and says the login is kept" yes "$(has "the login is kept" "$out")"
[[ "$FAIL" == 0 ]] || printf '   L1 output: %s\n' "$out"

# L2: the root hop itself.
o2=$(printf '%s\0' "$SITE" | FIVEDIVE_BROWSER_SEAT="$AG" "$BROWSER" _serve-offered 2>&1); rc2=$?
arm "L2 _serve-offered fails instead of exiting 0 with nothing started" 69 "$rc2"
arm "L2 with the same words" yes "$(has "still open in the owner's sign-in window" "$o2")"

# L3: the view has ended, but this box cannot start a warm session at all.
unserve; login_serve
o3=$(snap); rc3=$?
arm "L3 exit is 69" 69 "$rc3"
arm "L3 names it: no warm session on this box" yes "$(has "$SITE: no warm session on this box:" "$o3")"
arm "L3 and why: no session daemon" yes "$(has "playwright-core is not installed" "$o3")"
arm "L3 not the socket catch-all" no "$(has "no browser answers on its socket" "$o3")"
[[ "$rc3" == 69 ]] || printf '   L3 output: %s\n' "$o3"

# L4: nothing served. Unchanged: the root hop's own failure is the reason.
unserve
o4=$(snap); rc4=$?
arm "L4 still refused (69)" 69 "$rc4"
arm "L4 does not claim a sign-in window" no "$(has "sign-in window" "$o4")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
