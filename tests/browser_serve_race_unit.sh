#!/usr/bin/env bash
# DIVE-5528 — two serves of one site must not leave a browser nobody tracks.
#
# On hale-hawk (2026-10-04) a partner cabinet retried a Connect that the API's
# proxy had cut at 30 s, while the first was still starting. Both serves read
# "not running" and launched; the loser's daemon found the profile taken, its
# plain-Chrome fallback exited, and its failure path removed the WINNER's
# pidfile. The winner's browser then held the profile with nothing pointing at
# it: `served` listed nothing, and every later serve of either site failed
# with "chrome exited immediately" until the box was touched by hand.
#
# Driven through the real bin/browser with a FAKE session daemon and a FAKE
# google-chrome that keeps Chrome's one-instance-per-profile rule (a
# SingletonLock naming a live pid refuses the launch).
#
#   R1 two serves started together both succeed, and the site is served by
#      exactly one live daemon that the pidfile names (`served` lists it)
#   R2 the per-site lock is not inherited by the daemon: once serve returns,
#      the lock is free
#   R3 a daemon serving the profile with NO pidfile (the race's leftover) is
#      stopped by the next serve, which then serves the site
#   R4 a holder that is not a session daemon (a person's plain Chrome) is NEVER
#      touched: the serve fails as before and the holder lives
#
# NEGATIVE CONTROL: FIVEDIVE_TEST_BROWSER=<pre-fix bin/browser> bash this file;
# R1 (served lists nothing) and R3 (the serve fails) go red.
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="${FIVEDIVE_TEST_BROWSER:-$ROOT/browser/bin/browser}"

TMP="$(mktemp -d)"
_KILL=()
cleanup() {
  local p
  for p in "${_KILL[@]}"; do pkill -KILL -P "$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null; done
  # Anything the fakes started under this harness's tree.
  pkill -KILL -f "$TMP/" 2>/dev/null
  rm -rf "${TMP:-}"
}
trap 'rc=$?; cleanup; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0
arm() {  # arm <name> <expected> <got>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi
}
yn() { if "$@"; then echo yes; else echo no; fi; }
alive() { [[ -n "$1" && -d "/proc/$1" ]] && [[ "$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null)" != Z ]]; }

export FIVEDIVE_BROWSER_TMP_ROOT="$TMP/tmproot"
export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/profiles"
export FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/adapters"; mkdir -p "$FIVEDIVE_BROWSER_ADAPTER_DIR"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/no-rendezvous"
export FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/session-daemon"
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli"
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
export FIVEDIVE_BROWSER_X11_DIR="$TMP/x11"; mkdir -p "$FIVEDIVE_BROWSER_X11_DIR"
export DISPLAY= TMP

FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
# Chrome's one-instance rule as the real one keeps it on Linux: a live holder
# means this launch hands off and exits 0, which is what serve's fallback saw.
cat > "$FAKEBIN/google-chrome" <<'CHROME'
#!/usr/bin/env bash
[[ "${1:-}" == --version ]] && { echo 'Google Chrome 153.0.8010.36'; exit 0; }
ud=""
for a in "$@"; do case "$a" in --user-data-dir=*) ud="${a#*=}" ;; esac; done
ud="${ud%/}"
if t=$(readlink "$ud/SingletonLock" 2>/dev/null) && [[ -d "/proc/${t##*-}" ]]; then
  echo "Opening in existing browser session." >&2
  exit 0
fi
rm -f "$ud/SingletonLock"
# Atomic, like Chrome's: of two launches racing for a free profile, one wins.
ln -s "$(uname -n)-$$" "$ud/SingletonLock" 2>/dev/null || { echo "Opening in existing browser session." >&2; exit 0; }
exec sleep 100000
CHROME
# The daemon stays a bash process (no exec) so its cmdline is what the real
# node one's is: `<interp> <path>/session-daemon serve <dir> <sock>`.
cat > "$TMP/session-daemon" <<'DAEMON'
#!/usr/bin/env bash
[[ "$1" == serve ]] || exit 1
dir="$2"
sleep "${FAKE_DAEMON_DELAY:-1}"
google-chrome --user-data-dir="$dir" --remote-debugging-pipe about:blank &
c=$!
trap 'kill "$c" 2>/dev/null; exit 0' TERM
sleep 0.3
if ! [[ -d "/proc/$c" ]] || [[ "$(awk '{print $3}' "/proc/$c/stat" 2>/dev/null)" == Z ]]; then
  echo "browserType.launchPersistentContext: Opening in existing browser session." >&2
  exit 1
fi
echo "ready sock=$3 pid=$$ broker=no"
while kill -0 "$c" 2>/dev/null; do sleep 0.2; done
DAEMON
cat > "$FAKEBIN/Xvfb" <<'XVFB'
#!/usr/bin/env bash
: > "$TMP/x11/X${1#:}"
exec sleep 300
XVFB
chmod +x "$FAKEBIN/google-chrome" "$FAKEBIN/Xvfb" "$TMP/session-daemon"
export PATH="$FAKEBIN:$PATH"

SEAT="$(id -un)"
mkprofile() {
  local d="$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT/$1"
  mkdir -p "$d"; chmod 700 "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT" "$d"
  echo "$d"
}
pidkv() { sed -n "s/^$2=//p" "$1/.5dive-serve" 2>/dev/null | head -1; }
stopall() {  # stopall <dir> — tear a served site down between arms
  local d="$1" p
  for p in $(pidkv "$d" daemon_pid) $(pidkv "$d" xvfb_pid); do pkill -KILL -P "$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null; done
  rm -f "$d/.5dive-serve" "$d/SingletonLock"
}

# --- R1/R2 two serves at once ------------------------------------------------
D1="$(mkprofile race.test)"
"$BROWSER" serve race.test >"$TMP/r1a.out" 2>"$TMP/r1a.err" & a=$!
sleep 0.3
"$BROWSER" serve race.test >"$TMP/r1b.out" 2>"$TMP/r1b.err" & b=$!
wait "$a"; ra=$?; wait "$b"; rb=$?
dp="$(pidkv "$D1" daemon_pid)"; [[ -n "$dp" ]] && _KILL+=("$dp")
xp="$(pidkv "$D1" xvfb_pid)"; [[ -n "$xp" ]] && _KILL+=("$xp")
arm 'R1 both serves exit 0' '0 0' "$ra $rb"
arm 'R1 ...the second one found the first'"'"'s browser' yes "$(yn grep -q '^already serving race.test' "$TMP/r1b.out")"
arm 'R1 the pidfile names a live daemon' yes "$(yn alive "$dp")"
arm 'R1 served lists the site' race.test "$("$BROWSER" served 2>/dev/null | tr -d '\n')"
arm 'R1 exactly one daemon serves the profile' 1 "$(pgrep -fc "session-daemon serve $D1" 2>/dev/null || echo 0)"
arm 'R2 the serve lock is free once serve has returned (no child kept it)' yes \
  "$(yn flock -n "$D1/.5dive-serve.lock" true)"
stopall "$D1"

# --- R3 a daemon nobody tracks ----------------------------------------------
D3="$(mkprofile orphan.test)"
FAKE_DAEMON_DELAY=0 "$TMP/session-daemon" serve "$D3" "$D3/.orphan.sock" >/dev/null 2>&1 & op=$!
_KILL+=("$op")
for _ in $(seq 40); do [[ -L "$D3/SingletonLock" ]] && break; sleep 0.1; done
oc="$(readlink "$D3/SingletonLock" 2>/dev/null)"; oc="${oc##*-}"
arm 'R3 (control) the orphan daemon holds the profile, with no pidfile' 'yes no' \
  "$(yn alive "$oc") $(yn test -e "$D3/.5dive-serve")"
FAKE_DAEMON_DELAY=0 "$BROWSER" serve orphan.test >"$TMP/r3.out" 2>"$TMP/r3.err"; r3=$?
dp3="$(pidkv "$D3" daemon_pid)"; [[ -n "$dp3" ]] && _KILL+=("$dp3")
xp3="$(pidkv "$D3" xvfb_pid)"; [[ -n "$xp3" ]] && _KILL+=("$xp3")
sleep 0.2
arm 'R3 the serve succeeds' 0 "$r3"
arm 'R3 ...the untracked daemon and its Chrome are gone' 'no no' "$(yn alive "$op") $(yn alive "$oc")"
arm 'R3 ...and the new daemon is the one the pidfile names' yes "$(yn alive "$dp3")"
arm 'R3 ...and it said why' yes "$(yn grep -q 'nothing tracking it' "$TMP/r3.err")"
stopall "$D3"

# --- R4 a holder that is not a daemon is left alone ---------------------------
D4="$(mkprofile person.test)"
google-chrome --user-data-dir="$D4" "https://person.test/" >/dev/null 2>&1 & pc=$!
_KILL+=("$pc")
for _ in $(seq 40); do [[ -L "$D4/SingletonLock" ]] && break; sleep 0.1; done
FAKE_DAEMON_DELAY=0 "$BROWSER" serve person.test >"$TMP/r4.out" 2>"$TMP/r4.err"; r4=$?
arm 'R4 a person'"'"'s plain Chrome is still running' yes "$(yn alive "$pc")"
arm 'R4 ...and the serve refused rather than take the profile' 69 "$r4"
stopall "$D4"

# --- R5 a lock wait that runs out refuses, and reaps nothing ------------------
D5="$(mkprofile held.test)"
FAKE_DAEMON_DELAY=0 "$TMP/session-daemon" serve "$D5" "$D5/.held.sock" >/dev/null 2>&1 & op5=$!
_KILL+=("$op5")
for _ in $(seq 40); do [[ -L "$D5/SingletonLock" ]] && break; sleep 0.1; done
: >>"$D5/.5dive-serve.lock"
flock "$D5/.5dive-serve.lock" sleep 30 & hold=$!
_KILL+=("$hold")
sleep 0.3
FIVEDIVE_BROWSER_SERVE_LOCK_WAIT=1 FAKE_DAEMON_DELAY=0 "$BROWSER" serve held.test >"$TMP/r5.out" 2>"$TMP/r5.err"; r5=$?
arm 'R5 a serve that cannot get the lock refuses' 69 "$r5"
arm 'R5 ...and says another start is running' yes "$(yn grep -q 'another start of held.test is still running' "$TMP/r5.err")"
arm 'R5 ...and the daemon the lock holder may be starting is left alone' yes "$(yn alive "$op5")"
kill -KILL "$hold" 2>/dev/null
stopall "$D5"

printf '\n%s passed, %s failed (%s arms)\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[[ "$FAIL" -eq 0 ]]
