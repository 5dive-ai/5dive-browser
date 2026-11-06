#!/usr/bin/env bash
# DIVE-7822 — a page verb is not refused while the scheduled login check holds
# the profile.
#
# DIVE-7804 trial (the bench rig, 2026-11-06): `5dive-browser-probe@<seat>.timer`
# (every 6 h, `5dive browser probe-all`) ran 12:16-12:38Z. Every site of the rig's
# sign-in group is a link to ONE profile (.group-main, ~300 sites), so the sweep
# held that Chrome --user-data-dir for 22 minutes, and a page verb that had to
# start a Chrome in the window died on Chrome's exit 21 ("profile in use"): nfl.com
# lost outright, accuweather.com twice.
#
# Driven through the real bin/browser with a FAKE google-chrome first on PATH that
# keeps Chrome's one-instance-per-profile rule (a SingletonLock naming a live pid
# refuses the launch with exit 21, as the real one does). A sweep step holds the
# profile STEP_S seconds (FAKE_SLOW, set only in probe-all's environment).
#
#   Y0  control: with no sweep, `read` on a group site returns its page
#   Y1  mid-sweep (a sweep step holding the group profile): `read` returns the page,
#       rc 0, not exit 69 / Chrome 21
#   Y2  ...within the bound: one sweep step plus its own work, not the sweep
#   Y3  ...and says in words why it waited (the scheduled login check)
#   Y4  the sweep steps aside while the page verb holds the browser: at least one
#       site is skipped with the reason, none fails, probe-all exits 0
#   Y5  no Chrome was ever refused the profile (the fake's own refusal log), and
#       the sweep leaves no mark behind
#   Y6  a sweep mark whose process is gone is ignored: no wait, no message
#   Y7  a check that never lets go: the wait is bounded (PROBE_YIELD_S) and the
#       failure names the scheduled check instead of a bare Chrome exit
#   Y8  `shot` (a second page verb, the --screenshot launch) mid-sweep: rc 0
#
# NEGATIVE CONTROL: FIVEDIVE_TEST_BROWSER=<pre-fix bin/browser>; the mid-sweep arms
# go red (the read dies on Chrome exit 21; nothing steps aside).
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="${FIVEDIVE_TEST_BROWSER:-$ROOT/browser/bin/browser}"

TMP="$(mktemp -d)"
_KILL=()
trap 'rc=$?; for p in "${_KILL[@]}"; do pkill -KILL -P "$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null; done; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0
arm() {  # arm <name> <expected> <got>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi
}
yn() { if "$@"; then echo yes; else echo no; fi; }

export FIVEDIVE_BROWSER_TMP_ROOT="$TMP/tmproot"
export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/profiles"
export FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/adapters"; mkdir -p "$FIVEDIVE_BROWSER_ADAPTER_DIR"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/no-rendezvous"
export FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/no-session-daemon"
export FIVEDIVE_BROWSER_NO_DAEMON=1
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli"
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
export FIVEDIVE_BROWSER_X11_DIR="$TMP/x11"; mkdir -p "$FIVEDIVE_BROWSER_X11_DIR"
export FIVEDIVE_BROWSER_CHROME_SLACK_S=5
export TMP
STEP_S=3

# --- the fake chrome -------------------------------------------------------------
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/google-chrome" <<'CHROME'
#!/usr/bin/env bash
[[ "${1:-}" == --version ]] && { echo 'Google Chrome 153.0.8010.36'; exit 0; }
ud="" url="" shot=""
for a in "$@"; do
  case "$a" in
    --user-data-dir=*) ud="${a#*=}" ;;
    --screenshot=*) shot="${a#*=}" ;;
    http*) url="$a" ;;
  esac
done
ud="${ud%/}"
# Chrome's one-instance rule, as the real one keeps it on Linux.
if t=$(readlink "$ud/SingletonLock" 2>/dev/null); then
  p="${t##*-}"
  if [[ -d "/proc/$p" ]]; then
    echo "$(date +%s) REFUSED $url" >> "$TMP/launches.log"
    echo "[ERROR:process_singleton_posix.cc(358)] Failed to create $ud/SingletonLock: File exists (17)" >&2
    exit 21
  fi
  rm -f "$ud/SingletonLock"
fi
ln -s "$(uname -n)-$$" "$ud/SingletonLock"
echo "$(date +%s) START $url" >> "$TMP/launches.log"
case "$url" in */feed) [[ -n "${FAKE_SLOW:-}" ]] && sleep "$FAKE_SLOW" ;; esac
case "$url" in */page) [[ -n "${FAKE_PAGE_SLOW:-}" ]] && sleep "$FAKE_PAGE_SLOW" ;; esac
if [[ -n "$shot" ]]; then printf 'PNG' > "$shot"; fi
case "$url" in
  */feed) echo '<html><body><div id="feed">posts</div></body></html>' ;;
  *)      echo '<html><head><title>the page</title></head><body><main><h1>the page itself</h1><p>words on the page</p></main></body></html>' ;;
esac
rm -f "$ud/SingletonLock"
CHROME
chmod +x "$FAKEBIN/google-chrome"
export PATH="$FAKEBIN:$PATH"

ME="$(id -un)"
SEAT="$FIVEDIVE_BROWSER_PROFILE_ROOT/$ME"
G="$SEAT/.group-main"
mkdir -p "$G"; chmod 700 "$FIVEDIVE_BROWSER_PROFILE_ROOT" "$SEAT" "$G"
SITES=(a.test b.test c.test d.test e.test f.test)
for s in "${SITES[@]}"; do
  ln -s .group-main "$SEAT/$s"
  cat > "$FIVEDIVE_BROWSER_ADAPTER_DIR/$s.json" <<JSON
{ "site": "$s", "probe": { "url": "https://$s/feed", "logged_out_when_dom_matches": "action=\"/login\"" } }
JSON
done

sweep_start() {  # starts probe-all in the background; waits until a sweep step holds the profile
  : > "$TMP/launches.log"
  ( FAKE_SLOW=$STEP_S timeout -k 2 120 "$BROWSER" probe-all >"$TMP/sweep.out" 2>&1; echo "$?" > "$TMP/sweep.rc" ) &
  SWEEP=$!; _KILL+=("$SWEEP")
  local i
  for (( i = 0; i < 100; i++ )); do [[ -L "$G/SingletonLock" ]] && return 0; sleep 0.1; done
  echo "sweep never took the profile" >&2; return 1
}
sweep_wait() { wait "$SWEEP" 2>/dev/null; SWEEP_RC=$(cat "$TMP/sweep.rc" 2>/dev/null || echo none); }
verb() {  # verb <args...> -> OUT RC SECS
  local t0; t0=$(date +%s)
  OUT=$(timeout -k 2 90 "$BROWSER" "$@" 2>&1); RC=$?
  SECS=$(( $(date +%s) - t0 ))
}

# --- Y0 control ------------------------------------------------------------------
verb read e.test https://e.test/page
arm 'Y0 (control) no sweep: read returns the page' '0 yes' "$RC $(yn grep -q 'the page itself' <<<"$OUT")"
[[ "$RC" == 0 ]] || printf '   read said: %s\n' "$(tail -n3 <<<"$OUT")"

# --- Y1-Y5 a read in the middle of the sweep -------------------------------------
sweep_start
FAKE_PAGE_SLOW=$(( STEP_S + 2 )) verb read e.test https://e.test/page
sweep_wait
arm 'Y1 mid-sweep: read returns the page (rc 0), not a Chrome exit 21' '0 yes' "$RC $(yn grep -q 'the page itself' <<<"$OUT")"
[[ "$RC" == 0 ]] || printf '   read said: %s\n' "$(tail -n3 <<<"$OUT")"
# One step (STEP_S) + its own two launches (check + a STEP_S+2 render) + slack.
arm "Y2 ...within one sweep step plus its own work (<= $(( 3 * STEP_S + 6 ))s)" yes "$(yn test "$SECS" -le $(( 3 * STEP_S + 6 )))"
arm 'Y3 ...and it said the scheduled login check had the browser' yes "$(yn grep -q 'scheduled login check is using the e.test browser' <<<"$OUT")"
arm 'Y4a the sweep stepped aside for the read (a site skipped, with the reason)' yes \
  "$(yn grep -q 'skipped: a browser call is using it now' "$TMP/sweep.out")"
arm 'Y4b ...no site failed and probe-all exited 0' '0 no' \
  "$SWEEP_RC $(yn grep -qE 'UNKNOWN|status 21' "$TMP/sweep.out")"
arm 'Y5a no Chrome was refused the profile (fake Chrome refusal log)' 0 "$(grep -c REFUSED "$TMP/launches.log")"
arm 'Y5b the sweep left no mark behind' no "$(yn test -e "$G/.5dive-probe")"

# --- Y6 a dead mark is no holder ------------------------------------------------
sleep 0 & DEAD=$!; wait "$DEAD"
printf 'pid=%s\nsite=a.test\nat=%s\n' "$DEAD" "$(date -u +%s)" > "$G/.5dive-probe"
verb read e.test https://e.test/page
arm 'Y6 a mark whose process is gone: read goes straight on, no wait message' '0 no' \
  "$RC $(yn grep -q 'scheduled login check' <<<"$OUT")"
rm -f "$G/.5dive-probe"

# --- Y7 a check that never lets go ------------------------------------------------
bash -c 'sleep 100000; :' google-chrome --headless --dump-dom --user-data-dir="$SEAT/a.test" https://a.test/feed >/dev/null 2>&1 &
HOLD=$!; _KILL+=("$HOLD")
ln -s "$(uname -n)-$HOLD" "$G/SingletonLock"
printf 'pid=%s\nsite=a.test\nat=%s\n' "$HOLD" "$(date -u +%s)" > "$G/.5dive-probe"
FIVEDIVE_BROWSER_PROBE_YIELD_S=2 verb read e.test https://e.test/page
arm 'Y7a a check that never lets go: the wait is bounded (<= 12s) and the read fails' 'yes no' \
  "$(yn test "$SECS" -le 12) $(yn test "$RC" == 0)"
arm 'Y7b ...and the refusal itself names the scheduled check, not a bare Chrome exit' yes \
  "$(yn grep -q 'Refusing' <<<"$(grep 'The scheduled login check is using this browser right now' <<<"$OUT")")"
kill -KILL "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null
rm -f "$G/SingletonLock" "$G/.5dive-probe"

# --- Y8 shot mid-sweep -------------------------------------------------------------
sweep_start
verb shot c.test https://c.test/page --out="$TMP/c.png"
sweep_wait
arm 'Y8 mid-sweep: shot returns its picture (rc 0)' '0 yes' "$RC $(yn test -s "$TMP/c.png")"
[[ "$RC" == 0 ]] || printf '   shot said: %s\n' "$(tail -n3 <<<"$OUT")"

printf '\n%d pass, %d fail\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
