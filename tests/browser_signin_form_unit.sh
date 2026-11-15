#!/usr/bin/env bash
# DIVE-8523 — a signed-in page with a change-password form is not a sign-in, and
# the automated served browser opens at 1280x800.
#
# Box report 1004 (wappi.pro, browser 1.89.0): every `act` on the
# owner's signed-in cabinet exited 75 "the page that came back is a sign-in
# form". The generic guard grepped a bare type=password / current-password; the
# cabinet carries a change-password dialog and a hidden fake_pass decoy. The
# same report's clicks were refused "outside window 800x457": the served
# automated Chrome had no --window-size and took Chrome's default 800x600.
#
#   S1 lib/signin-form.cjs, pure: the measured cabinet shape, a change form
#      posting to /auth, a set-password field, a hidden decoy alone -> none;
#      wappi.pro's real /login form, a bare login password box, a form posting
#      to /login with no password box -> signin
#   S2 lib/generic-login.cjs (status): the cabinet reads `in`, /login `out`
#   S3 through the real bin/browser `read` on a no-adapter site (the guard
#      act, read and snapshot all run): the cabinet is handed back (rc 0);
#      /login is refused 75; with a node that fails the old grep stands (75)
#   S4 NEGATIVE CONTROL: origin/main's bin/browser refuses the cabinet (75)
#   S5 the session daemon's launchArgs, run as code: --window-size=1280,800
#      and --window-position=0,0 (with and without the sandbox); an operator's
#      own --window-size in FIVEDIVE_BROWSER_CHROME_ARGS is the only one
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
LIB="$ROOT/browser/lib/signin-form.cjs"
FX="$ROOT/tests/fixtures/dive-8523"

TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0
arm() {  # arm <name> <expected> <got>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n   last stderr: %s\n' "$1" "$2" "$3" "$(tail -c 300 "$TMP/err" 2>/dev/null)"; fi
}
verdict() { printf '%s' "$1" > "$TMP/page.html"; node "$LIB" "$TMP/page.html" | head -1; }

# --- S1 ----------------------------------------------------------------------
arm 'S1 the measured cabinet (change-password dialog + fake_pass) is not a sign-in' none "$(node "$LIB" "$FX/cabinet.html" | head -1)"
arm "S1 wappi.pro's real /login form is a sign-in" signin "$(node "$LIB" "$FX/login.html" | head -1)"
arm 'S1 a change form posting to /auth/... is not a sign-in' none \
  "$(verdict '<form action="/auth/change-password"><input type="password" name="current"><input type="password" name="newPassword"></form>')"
arm 'S1 a set-password field (autocomplete=new-password) is not a sign-in' none \
  "$(verdict '<div><input type="password" name="pw" autocomplete="new-password"></div>')"
arm 'S1 a hidden decoy alone is not a sign-in' none \
  "$(verdict '<input type="password" name="fake_pass" style="display:none">')"
arm 'S1 a login form inside a hidden block is not on the page' none \
  "$(verdict '<div hidden><form action="/login"><input type="password" name="password"></form></div><p>feed</p>')"
arm 'S1 a bare login password box (no form) is a sign-in' signin \
  "$(verdict '<div><input type="email" name="email"><input type="password" name="password" autocomplete="current-password"></div>')"
arm 'S1 a form posting to /login with no password box (identifier step) is a sign-in' signin \
  "$(verdict '<form action="/login"><input type="email" name="email"></form>')"
arm 'S1 a login box next to a change form elsewhere is still a sign-in' signin \
  "$(verdict '<form><input type="password" name="password"></form><form><input type="password" name="new-password"></form>')"

# --- S2 ----------------------------------------------------------------------
arm 'S2 status reads the cabinet signed in' in "$(node "$ROOT/browser/lib/generic-login.cjs" "$FX/cabinet.html" | head -1)"
arm 'S2 status reads /login signed out' out "$(node "$ROOT/browser/lib/generic-login.cjs" "$FX/login.html" | head -1)"

# --- S3 ----------------------------------------------------------------------
export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/profiles"
export FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/adapters"; mkdir -p "$FIVEDIVE_BROWSER_ADAPTER_DIR"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/no-rendezvous"
export FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/no-session-daemon"
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli"
export FIVEDIVE_BROWSER_TMP_ROOT="$TMP/tmproot"
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
export FIVEDIVE_BROWSER_GENERIC_MEMO_TTL=0
SEAT="$FIVEDIVE_BROWSER_PROFILE_ROOT/$(id -un)"
SITE=noad.example.com
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/google-chrome" <<'CHROME'
#!/usr/bin/env bash
[[ "${1:-}" == --version ]] && { echo 'Google Chrome 153.0.8010.36'; exit 0; }
d="" shot="" dump="" u=""
for a in "$@"; do
  case "$a" in
    --user-data-dir=*) d="${a#*=}" ;;
    --screenshot=*) shot="${a#*=}" ;;
    --dump-dom) dump=1 ;;
    -*) ;;
    *) u="$a" ;;
  esac
done
[[ -n "$shot" ]] && printf '\x89PNG fake\n' > "$shot"
if [[ -n "$dump" || -z "$shot" ]]; then
  if [[ "$u" =~ ^https?://[^/]+/?$ ]]; then printf '<html><body><div id="feed">posts</div></body></html>'
  else cat "$d/.fake-dom-page" 2>/dev/null; fi
fi
exit 0
CHROME
chmod +x "$FAKEBIN/google-chrome"
export PATH="$FAKEBIN:$PATH"

N=0
seat() {  # seat <page fixture>
  rm -rf "$FIVEDIVE_BROWSER_PROFILE_ROOT"
  mkdir -p "$SEAT"; chmod 711 "$FIVEDIVE_BROWSER_PROFILE_ROOT"; chmod 700 "$SEAT"
  mkdir -m 700 "$SEAT/$SITE"; cp "$1" "$SEAT/$SITE/.fake-dom-page"
}
readit() {  # readit <browser> <url> [env...]: sets RC ERR
  N=$((N+1)); mkdir -m 700 "$TMP/r$N"
  env "${@:3}" "$1" read "$2" --out="$TMP/r$N" >/dev/null 2>"$TMP/err"; RC=$?; ERR=$(cat "$TMP/err")
}
seat "$FX/cabinet.html"; readit "$BROWSER" "https://$SITE/dashboard/x"
arm 'S3 read: the signed-in cabinet is handed back' 0 "$RC"
arm '...and is not refused as a sign-in form' no "$(grep -q 'is a sign-in form' <<<"$ERR" && echo yes || echo no)"
seat "$FX/login.html"; readit "$BROWSER" "https://$SITE/dashboard/y"
arm 'S3 read: a page that is the /login form is refused 75' 75 "$RC"
arm '...as a sign-in form' yes "$(grep -q 'is a sign-in form' <<<"$ERR" && echo yes || echo no)"
# The check cannot run (a node that fails): the grep stands (fail closed).
BROKEN="$TMP/broken-node"; mkdir -p "$BROKEN"; printf '#!/bin/sh\nexit 1\n' > "$BROKEN/node"; chmod +x "$BROKEN/node"
seat "$FX/cabinet.html"; readit "$BROWSER" "https://$SITE/dashboard/x" "PATH=$BROKEN:$PATH"
arm 'S3 read with a node that fails: the cabinet is refused as a sign-in form (fail closed)' '75 yes' "$RC $(grep -q 'is a sign-in form' <<<"$ERR" && echo yes || echo no)"

# --- S4 ----------------------------------------------------------------------
BASE="$TMP/base"
if git -C "$ROOT" rev-parse -q --verify origin/main >/dev/null \
   && mkdir -p "$BASE" && git -C "$ROOT" archive origin/main browser | tar -x -C "$BASE" \
   && ! [[ -f "$BASE/browser/lib/signin-form.cjs" ]]; then
  seat "$FX/cabinet.html"; readit "$BASE/browser/bin/browser" "https://$SITE/dashboard/x"
  arm "S4 NEGATIVE CONTROL: origin/main refuses the signed-in cabinet" 75 "$RC"
else
  echo 'SKIP: S4 (no origin/main, or it already carries the fix)'
fi

# --- S5 ----------------------------------------------------------------------
argsof() {  # argsof <file> <function> <call>
  node -e '
    const src = require("fs").readFileSync(process.argv[1], "utf8");
    const m = src.match(new RegExp("^function " + process.argv[2] + "\\([^]*?^}", "m"));
    if (!m) { console.log("NO-FUNCTION"); process.exit(0); }
    const aria = { unmarkedArgs: () => [] }, die = (c, s) => { throw new Error(s); };
    const fn = new Function("aria", "die", "E_NOTHING_RAN", m[0] + "; return " + process.argv[3] + ";");
    console.log(fn(aria, die, 64).join(" "));' "$1" "$2" "$3"
}
D="$ROOT/browser/bin/session-daemon"
for c in 'launchArgs(true)' 'launchArgs(false)'; do
  a=$(unset FIVEDIVE_BROWSER_CHROME_ARGS; argsof "$D" launchArgs "$c")
  arm "S5 the served browser's $c opens a 1280x800 window" yes "$(grep -qw -- '--window-size=1280,800' <<<"$a" && echo yes || echo no)"
  arm "...at 0,0" yes "$(grep -qw -- '--window-position=0,0' <<<"$a" && echo yes || echo no)"
done
a=$(FIVEDIVE_BROWSER_CHROME_ARGS='--window-size=1600,900' argsof "$D" launchArgs 'launchArgs(true)')
arm "S5 an operator's own --window-size is the only one" '--window-size=1600,900' "$(grep -o -- '--window-size=[0-9,]*' <<<"$a" | paste -sd' ')"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
