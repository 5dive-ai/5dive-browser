#!/usr/bin/env bash
# DIVE-7204 — no Chrome "Restore pages?" bubble after a served browser was stopped.
#
#   B1 lib/clean-exit.cjs marks a crashed profile cleanly exited, keeps every
#      other key and the file's mode; twice is once; a new profile is left
#      alone; a corrupt Preferences is left byte for byte
#   B2 every kept-profile launcher passes --hide-crash-restore-bubble: the
#      daemon's launchArgs and plainArgs and the driver's launchArgs, run as
#      code (with and without the sandbox), not grepped
#   B3 the daemon and the driver mark the profile before they launch
#   B4 through the real bin/browser: `auth` with a display hands a fake Chrome
#      the flag, and the profile it opens already says it exited cleanly
#   L  LIVE, when this machine has Xvfb and Chrome (GitHub's ubuntu runner does):
#      the real session daemon serves a page in input mode, Chrome is killed
#      with -9, and then (control) plain Chrome with the old flags on a copy of
#      that profile shows a second window, the bubble, while (fix) the daemon
#      serving it again shows the browser window alone. RESTORE_BUBBLE_ARTIFACTS
#      keeps both screens.
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
LIB="$ROOT/browser/lib/clean-exit.cjs"
FLAG=--hide-crash-restore-bubble

REAL_XVFB="$(command -v Xvfb || true)"
REAL_CHROME="$(command -v google-chrome || command -v chromium || command -v chromium-browser || true)"
[[ -n "${RESTORE_BUBBLE_SKIP_LIVE:-}" ]] && REAL_CHROME=""
ART="${RESTORE_BUBBLE_ARTIFACTS:-}"; [[ -n "$ART" ]] && mkdir -p "$ART"

TMP="$(mktemp -d)"
_KILL=()
cleanup() {
  local rc=$? p i
  for p in "${_KILL[@]}"; do kill "$p" 2>/dev/null; done
  pkill -f -- "$TMP/" 2>/dev/null   # a daemon started inside $(serve …) is in no list
  pkill -KILL -f -- "--user-data-dir=$TMP/" 2>/dev/null
  for i in $(seq 1 50); do pgrep -f -- "--user-data-dir=$TMP/" >/dev/null || break; sleep 0.1; done
  for i in 1 2 3 4 5; do rm -rf "${TMP:-}" 2>/dev/null && break; sleep 0.2; done
  echo "HARNESS-RC=$rc"
}
trap cleanup EXIT

PASS=0; FAIL=0
arm() {  # arm <name> <expected> <got>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi
}
yn() { if "$@"; then echo yes; else echo no; fi; }
crashed() {  # crashed <profile>: the Preferences Chrome leaves after a kill -9
  mkdir -p "$1/Default"
  printf '%s' '{"profile":{"exit_type":"Crashed","exited_cleanly":false,"name":"Person 1"},"session":{"restore_on_startup":1}}' > "$1/Default/Preferences"
  chmod 600 "$1/Default/Preferences"
}
pref() { node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1]+"/Default/Preferences","utf8")); console.log(process.argv[2].split(".").reduce((o,k)=>o&&o[k],p))' "$1" "$2"; }

# --- B1 ----------------------------------------------------------------------
P="$TMP/p1"; crashed "$P"
arm 'B1 a crashed profile is marked' marked "$(node "$LIB" "$P")"
arm 'B1 ...exit_type is Normal' Normal "$(pref "$P" profile.exit_type)"
arm 'B1 ...exited_cleanly is true' true "$(pref "$P" profile.exited_cleanly)"
arm 'B1 ...the profile name is kept' 'Person 1' "$(pref "$P" profile.name)"
arm 'B1 ...the startup setting is kept (no tabs restored or changed)' 1 "$(pref "$P" session.restore_on_startup)"
arm 'B1 ...the file stays 0600' 600 "$(stat -c %a "$P/Default/Preferences")"
arm 'B1 ...no temp file is left beside it' 1 "$(ls -A "$P/Default" | wc -l)"
arm 'B1 a second run changes nothing' clean "$(node "$LIB" "$P")"
arm 'B1 a new profile is left alone' absent "$(node "$LIB" "$TMP/new")"
arm 'B1 ...and nothing is created for it' no "$(yn test -e "$TMP/new")"
P="$TMP/p2"; mkdir -p "$P/Default"; printf '{"profile": {"exit_type": "Crash' > "$P/Default/Preferences"
sum=$(sha256sum < "$P/Default/Preferences")
arm 'B1 a corrupt Preferences is reported' unreadable "$(node "$LIB" "$P")"
arm 'B1 ...and left byte for byte' "$sum" "$(sha256sum < "$P/Default/Preferences")"

# --- B2 ----------------------------------------------------------------------
# Each launcher's own function body, cut out of the file and run with the two
# names it reads stubbed: the arm grades the args the code builds.
argsof() {  # argsof <file> <function> <call>
  node -e '
    const src = require("fs").readFileSync(process.argv[1], "utf8");
    const m = src.match(new RegExp("^function " + process.argv[2] + "\\([^]*?^}", "m"));
    if (!m) { console.log("NO-FUNCTION"); process.exit(0); }
    const aria = { unmarkedArgs: () => [] }, die = (c, s) => { throw new Error(s); };
    const fn = new Function("aria", "die", "E_NOTHING_RAN", m[0] + "; return " + process.argv[3] + ";");
    console.log(fn(aria, die, 64).join(" "));' "$1" "$2" "$3"
}
D="$ROOT/browser/bin/session-daemon" DR="$ROOT/browser/bin/driver-playwright"
for c in 'launchArgs(true)' 'launchArgs(false)'; do
  arm "B2 the session daemon's $c carries $FLAG" yes "$(yn grep -qw -- "$FLAG" <<<"$(argsof "$D" launchArgs "$c")")"
done
for c in 'plainArgs("/p", true)' 'plainArgs("/p", false)'; do
  arm "B2 input mode's $c carries $FLAG" yes "$(yn grep -qw -- "$FLAG" <<<"$(argsof "$D" plainArgs "$c")")"
done
arm "B2 the driver's launchArgs() carries $FLAG" yes "$(yn grep -qw -- "$FLAG" <<<"$(argsof "$DR" launchArgs 'launchArgs()')")"
arm 'B2 ...and input mode still refuses an automation flag' yes \
  "$(yn grep -q 'refusing' <<<"$(FIVEDIVE_BROWSER_CHROME_ARGS=--enable-automation argsof "$D" plainArgs 'plainArgs("/p", true)' 2>&1)")"

# --- B3 ----------------------------------------------------------------------
# The mark sits in front of the launch: the line number of the call is below
# that of the first launch it guards, in the same function.
before() {  # before <file> <launch pattern>
  local mk ln; mk=$(grep -n 'cleanExit.markCleanExit(profile)' "$1" | head -1 | cut -d: -f1)
  ln=$(grep -n -- "$2" "$1" | awk -F: -v m="${mk:-999999}" '$1>m{print $1; exit}')
  [[ -n "$mk" && -n "$ln" && $((ln - mk)) -lt 40 ]]
}
arm 'B3 the session daemon marks the profile before either launch' yes "$(yn before "$D" 'ctx = await inputLaunch(profile, chrome)')"
arm 'B3 the driver marks the profile before it launches' yes "$(yn before "$DR" 'chromium.launchPersistentContext(profile')"

# --- B4 ----------------------------------------------------------------------
export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/profiles"
export FIVEDIVE_BROWSER_ADAPTER_DIR="$ROOT/browser/adapters"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/no-rendezvous"
export FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/no-session-daemon"
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli"
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
export FIVEDIVE_BROWSER_X11_DIR="$TMP/x11"; mkdir -p "$FIVEDIVE_BROWSER_X11_DIR"
export STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
unset FIVEDIVE_BROWSER_SEAT FIVEDIVE_BROWSER_CHROME
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
# The fake Chrome records its argv and the profile's exit_type AT LAUNCH.
cat > "$FAKEBIN/google-chrome" <<EOF
#!/bin/sh
[ "\$1" = --version ] && { echo "Google Chrome 153.0.8010.36"; exit 0; }
printf '%s\n' "\$@" > "$TMP/argv"
for a in "\$@"; do case "\$a" in --user-data-dir=*) d="\${a#--user-data-dir=}" ;; esac; done
grep -o '"exit_type":"[A-Za-z]*"' "\$d/Default/Preferences" > "$TMP/at-launch" 2>/dev/null
exit 0
EOF
chmod +x "$FAKEBIN/google-chrome"
export PATH="$FAKEBIN:$PATH"
H="$TMP/home"; mkdir -p "$H"; export HOME="$H"
SEATDIR="$FIVEDIVE_BROWSER_PROFILE_ROOT/$(id -un)"
mkdir -p "$SEATDIR"; chmod 700 "$FIVEDIVE_BROWSER_PROFILE_ROOT" "$SEATDIR"
crashed "$SEATDIR/example.com"; chmod -R go-rwx "$SEATDIR/example.com"
out=$(DISPLAY=:99 "$BROWSER" auth example.com 2>&1); rc=$?
arm 'B4 auth with a display opens the browser (rc 0)' 0 "$rc"
arm "B4 ...with $FLAG" yes "$(yn grep -qx -- "$FLAG" "$TMP/argv")"
arm 'B4 ...on a profile already marked cleanly exited' '"exit_type":"Normal"' "$(cat "$TMP/at-launch" 2>/dev/null)"
[[ $rc == 0 ]] || printf '%s\n' "$out" | tail -5

# --------------------------------------------------------------- L: live
SKIP=0
if [[ -z "$REAL_XVFB" || -z "$REAL_CHROME" ]]; then
  SKIP=1; printf 'SKIP: L live arms — this machine has no Xvfb (%s) or no Chrome (%s)\n' "${REAL_XVFB:-none}" "${REAL_CHROME:-none}"
else
  unset FIVEDIVE_BROWSER_CHROME_ARGS
  X11LIB="$ROOT/browser/lib/x11.cjs"
  disp=""
  for n in $(seq 770 820); do [[ -e "/tmp/.X11-unix/X$n" ]] || { disp=$n; break; }; done
  "$REAL_XVFB" ":$disp" -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 & _KILL+=("$!")
  for i in $(seq 1 100); do [[ -e "/tmp/.X11-unix/X$disp" ]] && break; sleep 0.05; done
  PAGE="$TMP/page.html"
  printf '<!doctype html><title>restore-check</title><body style="margin:0;background:#fff">page</body>\n' > "$PAGE"
  # wins <pid> — the viewable top-level windows that pid owns (_NET_WM_PID).
  wins() { DISPLAY=":$disp" node -e '
    require(process.argv[1]).open(process.env.DISPLAY).then(async (x) => {
      let n = 0;
      for (const w of await x.children(x.root)) {
        try { if ((await x.viewable(w)) && (await x.prop32(w, "_NET_WM_PID")) === Number(process.argv[2])) n++; } catch (e) {}
      }
      console.log(n); x.close(); })' "$X11LIB" "$1" 2>/dev/null || echo 0; }
  # settle <pid> — wait for the browser window (20s), then 5s for a bubble to draw.
  settle() { local i; for i in $(seq 1 100); do [[ "$(wins "$1")" -ge 1 ]] && break; sleep 0.2; done; sleep 5; }
  shot() { [[ -n "$ART" ]] || return 0; node -e '
    require(process.argv[1]).open(process.argv[2]).then(async (x) => { require("fs").writeFileSync(process.argv[3], await x.screenshotPNG()); x.close(); })' \
    "$X11LIB" ":$disp" "$ART/$1.png" 2>/dev/null; }
  serve() {  # serve <profile> — the real daemon, input mode; prints its Chrome's pid
    DISPLAY=":$disp" FIVEDIVE_BROWSER_CHROME="$REAL_CHROME" FIVEDIVE_BROWSER_START_URL="file://$PAGE" \
      "$D" serve "$1" "$1/s.sock" --input > "$TMP/ready" 2> "$TMP/serve.err" &
    _KILL+=("$!")
    for i in $(seq 1 600); do grep -q '^ready' "$TMP/ready" 2>/dev/null && break; sleep 0.05; done
    pgrep -o -f -- "--user-data-dir=$1( |$)"
  }
  LP="$TMP/live"; mkdir -m 700 "$LP"
  cpid=$(serve "$LP")
  # Chrome writes "Crashed" into its own Preferences while it runs; that is
  # what a kill -9 leaves behind. Wait for it on disk (Chrome batches writes).
  for i in $(seq 1 150); do grep -q '"exit_type":"Crashed"' "$LP/Default/Preferences" 2>/dev/null && break; sleep 0.2; done
  arm 'L the served Chrome is running' yes "$(yn test -n "$cpid")"
  arm 'L ...and its profile says Crashed while it runs' yes "$(yn grep -q '"exit_type":"Crashed"' "$LP/Default/Preferences")"
  kill -9 "$cpid" 2>/dev/null; pkill -f -- "$LP/s.sock" 2>/dev/null
  for i in $(seq 1 100); do pgrep -f -- "--user-data-dir=$LP( |$)" >/dev/null || break; sleep 0.1; done
  pkill -KILL -f -- "--user-data-dir=$LP( |$)" 2>/dev/null; sleep 0.5
  rm -f "$LP/s.sock" "$LP"/Singleton*

  # CONTROL: the same crashed profile, copied, opened the way 1.63.1 opened it.
  CP="$TMP/control"; cp -a "$LP" "$CP"
  old=$(argsof "$D" plainArgs "plainArgs(\"$CP\", false)" | tr ' ' '\n' | grep -vx -- "$FLAG")
  # shellcheck disable=SC2086
  DISPLAY=":$disp" "$REAL_CHROME" $old "file://$PAGE" >/dev/null 2>&1 & ccpid=$!; _KILL+=("$ccpid")
  settle "$ccpid"; control=$(wins "$ccpid"); shot control-restore-bubble
  DISPLAY=":$disp" node "$ROOT/tests/x11_stack.cjs" control 1200 80 "$ccpid" | sed 's/^/   /'
  arm 'L control: 1.63.1 flags on a killed profile show a second window (the bubble)' yes "$(yn test "$control" -ge 2)"
  kill -9 "$ccpid" 2>/dev/null

  # FIX: the daemon serves the killed profile again.
  fpid=$(serve "$LP")
  settle "$fpid"; fixed=$(wins "$fpid"); shot fixed-no-bubble
  DISPLAY=":$disp" node "$ROOT/tests/x11_stack.cjs" fix 1200 80 "$fpid" | sed 's/^/   /'
  arm 'L fix: the daemon reopens the killed profile with the browser window alone' 1 "$fixed"
  arm 'L ...the daemon reported nothing wrong' '' "$(grep -v '^$' "$TMP/serve.err" | grep -iv 'dbus' | head -2)"
  printf '   windows: control=%s fix=%s (Chrome %s)\n' "$control" "$fixed" "$("$REAL_CHROME" --version 2>/dev/null)"
fi

printf '\n%d pass, %d fail, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
