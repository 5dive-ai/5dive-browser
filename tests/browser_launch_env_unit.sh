#!/usr/bin/env bash
# DIVE-5638 — a launch must not depend on what the seat's $HOME looks like.
#
# crystal-grove, 2026-10-05: after an owner connected instagram.com, every serve
# of the box seat's profile died rc 133 (`chrome_crashpad_handler: --database is
# required`), and on seat agent-diveteam-marcus every launch died `Socket path
# too long`. Both came from a path under $HOME: Chrome's crashpad database
# ($HOME/.config/google-chrome once XDG_CONFIG_HOME is unset — DIVE-4587) and
# its SingletonSocket (<TMPDIR>/.com.google.Chrome.XXXXXX/SingletonSocket, with
# TMPDIR under $HOME/.cache since DIVE-5190).
#
# Driven through the real bin/browser, with a FAKE google-chrome that fails the
# way the real one does: rc 133 when it cannot create its crash dir, and "Socket
# path too long" when its singleton socket would pass the 107-character limit.
#
#   L1 a seat whose home path is long still launches (socket path)
#   L2 a seat whose ~/.config is unwritable, under an unwritable shared
#      XDG_CONFIG_HOME, still launches (crash dir)
#   L3 the crash dir is the per-launch dir, and it is gone after the launch
#   L4 a root too long for the socket is not used; an inherited per-launch dir
#      of another uid is not inherited
#   L5 dirs an older version left under $HOME/.cache are still reaped
#   L6 the node launchers keep the crash dir bin/browser hands them, and still
#      drop a shared XDG_CONFIG_HOME
#   L7 (DIVE-6327) a throwaway profile's disk cache stays inside the profile, so
#      nothing is left in the cache home; and the caches older versions left
#      there are reaped — only those
#   L8 (DIVE-7432) a squatted per-launch root over a ~/.config/google-chrome the
#      seat cannot write still launches: the crash dir is a fresh dir, never the
#      home; a detached child's is reaped after it; with no dir to be had at all
#      the rc 133 message names the crash dir, its owner and why the claim
#      failed; the pre-fix tree traps on the same box (negative control)
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"

TMP="$(mktemp -d)"
_KILL=()
trap 'rc=$?; for p in "${_KILL[@]}"; do kill "$p" 2>/dev/null; done; chmod -R u+rwx "${TMP:-/nonexistent}" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0
arm() {  # arm <name> <expected> <got>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi
}
yn() { if "$@"; then echo yes; else echo no; fi; }
starttime() { local s; read -r s < "/proc/$1/stat" || return 1; s="${s##*) }"; local -a f; read -ra f <<<"$s"; echo "${f[19]}"; }

unset FIVEDIVE_BROWSER_TMP_ROOT XDG_CONFIG_HOME FIVEDIVE_BROWSER_CHROME_CONFIG
SYSTMP="$TMP/systmp"; mkdir -p "$SYSTMP"
export TMPDIR="$SYSTMP"
export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/profiles"
export FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/adapters"; mkdir -p "$FIVEDIVE_BROWSER_ADAPTER_DIR"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/no-rendezvous"
export FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/no-session-daemon"
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli"
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
export FIVEDIVE_BROWSER_X11_DIR="$TMP/x11"; mkdir -p "$FIVEDIVE_BROWSER_X11_DIR"
SEEN="$TMP/seen"; : > "$SEEN"
export SEEN

# --- the fake chrome: fails where the real one fails ---------------------------
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/google-chrome" <<'CHROME'
#!/usr/bin/env bash
[[ "${1:-}" == --version ]] && { echo 'Google Chrome 153.0.8010.36'; exit 0; }
t="${TMPDIR:-/tmp}"
crash="${XDG_CONFIG_HOME:-$HOME/.config}/google-chrome/Crash Reports"
printf 'tmp=%s\ncrash=%s\n' "$t" "$crash" >> "$SEEN"
# DIVE-6327: the disk cache goes where Linux Chrome puts it (GetUserCacheDirectory):
# $XDG_CACHE_HOME + the profile relative to $XDG_CONFIG_HOME when it is under it,
# else inside the profile.
udd=""; blank=0
for a in "$@"; do case "$a" in --user-data-dir=*) udd="${a#*=}" ;; about:blank) blank=1 ;; esac; done
if [[ -n "$udd" ]]; then
  cfg="${XDG_CONFIG_HOME:-$HOME/.config}"; cache="$udd"
  [[ "$udd" == "$cfg"/* ]] && cache="${XDG_CACHE_HOME:-$HOME/.cache}/${udd#"$cfg"/}"
  mkdir -p "$cache/Default/Cache" "$cache/Default/Code Cache" 2>/dev/null && : > "$cache/Default/Cache/data_0"
  (( blank )) && printf 'blankcache=%s\nblankudd=%s\n' "$cache" "$udd" >> "$SEEN"
fi
# A page that does not load: the probe then asks for an about:blank launch.
[[ -n "${FAKE_FAIL_PAGE:-}" ]] && (( ! blank )) && { echo 'net::ERR_TIMED_OUT' >&2; exit 1; }
# The singleton socket: Chrome's own temp dir name is 6 random characters.
sock="$t/.com.google.Chrome.XXXXXX/SingletonSocket"
if (( ${#sock} > 107 )); then
  echo "[0101/000000.000000:ERROR:process_singleton_posix.cc(1001)] Socket path too long: $sock" >&2; exit 1
fi
if ! mkdir -p "$crash" 2>/dev/null; then
  echo "chrome_crashpad_handler: --database is required" >&2; exit 133
fi
echo '<html><body><div id="feed">posts</div></body></html>'
CHROME
chmod +x "$FAKEBIN/google-chrome"
export PATH="$FAKEBIN:$PATH"

SEAT="$(id -un)"
mkdir -p "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT/launch.test"
chmod 700 "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT" "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT/launch.test"
cat > "$FIVEDIVE_BROWSER_ADAPTER_DIR/launch.test.json" <<'JSON'
{ "site": "launch.test", "probe": { "url": "https://launch.test/feed", "logged_out_when_dom_matches": "action=\"/login\"" } }
JSON
seen() { sed -n "s/^$1=//p" "$SEEN" | tail -1; }
OWNROOT="/tmp/.5dive-browser-$EUID"

# --- L1 a long seat name -------------------------------------------------------
# crystal-grove's seat, under a scratch "/home". Its legacy socket path is ~136.
LONGHOME="$TMP/home/agent-diveteam-marcus"; mkdir -p "$LONGHOME"
legacy="$LONGHOME/.cache/5dive-browser/tmp/4194304.18446744073709/.com.google.Chrome.XXXXXX/SingletonSocket"
arm 'L1 (control) the legacy layout is over the socket limit for this home' yes "$(yn test "${#legacy}" -gt 107)"
: > "$SEEN"
out=$(HOME="$LONGHOME" "$BROWSER" status launch.test 2>&1); rc=$?
arm 'L1 (control) the fake chrome ran' yes "$(yn test -s "$SEEN")"
arm 'L1 a seat with a long home launches: status reads the profile (rc 0)' 0 "$rc"
arm 'L1 ...and says nothing about a broken browser' no "$(yn grep -q BROKEN <<<"$out")"
t=$(seen tmp)
arm 'L1 the per-launch dir is under the per-uid /tmp root, not the home' yes "$(yn grep -qE "^$OWNROOT/[0-9]+\.[0-9]+\$" <<<"$t")"
worst="/tmp/.5dive-browser-4294967294/4194304.18446744073709551615/.org.chromium.Chromium.XXXXXX/SingletonSocket"
arm 'L1 the worst case of the new layout (max uid, pid, starttime, Chromium) fits 107' yes "$(yn test "${#worst}" -le 107)"
arm 'L1 the root is 0700 and ours' "700 $EUID" "$(stat -c '%a %u' "$OWNROOT" 2>/dev/null)"
arm 'L1 no per-launch dir is left after the launch' 0 "$(find "$OWNROOT" -mindepth 1 -maxdepth 1 -name "*.*" -newer "$SEEN" 2>/dev/null | wc -l | tr -d ' ')"

# --- L2 an unwritable crash dir under $HOME, and a shared XDG_CONFIG_HOME --------
# The two homes DIVE-4587 and DIVE-5199 measured: ~/.config the seat cannot write,
# and the box's shared XDG_CONFIG_HOME, whose google-chrome another seat owns.
SHORTHOME="$TMP/h"; mkdir -p "$SHORTHOME/.config" "$TMP/shared/google-chrome"
chmod 500 "$SHORTHOME/.config" "$TMP/shared/google-chrome"
arm 'L2 (control) this run cannot create a dir in the unwritable ~/.config (not root)' no \
  "$(yn mkdir "$SHORTHOME/.config/x" 2>/dev/null)"
: > "$SEEN"
out=$(HOME="$SHORTHOME" XDG_CONFIG_HOME="$TMP/shared" "$BROWSER" status launch.test 2>&1); rc=$?
arm 'L2 an unwritable ~/.config under a shared XDG_CONFIG_HOME still launches (rc 0)' 0 "$rc"
arm 'L2 ...and is not BROKEN' no "$(yn grep -q 'BROKEN\|exited 133' <<<"$out")"
c=$(seen crash); t=$(seen tmp)
arm 'L2 Chrome was not pointed at the shared XDG_CONFIG_HOME' no "$(yn grep -q "^$TMP/shared" <<<"$c")"
arm 'L2 ...nor at the home' no "$(yn grep -q "^$SHORTHOME" <<<"$c")"

# --- L3 the crash dir IS the per-launch dir ------------------------------------
arm 'L3 the crash dir lives inside the per-launch dir' "$t/.config/google-chrome/Crash Reports" "$c"
arm 'L3 ...which is gone with the launch' no "$(yn test -e "$t")"

# --- L4 a too-long root, and an inherited dir of another uid ---------------------
long="$TMP/$(printf 'r%.0s' $(seq 60))"
: > "$SEEN"
FIVEDIVE_BROWSER_TMP_ROOT="$long" HOME="$LONGHOME" XDG_CONFIG_HOME="$TMP/shared" "$BROWSER" status launch.test >/dev/null 2>&1; rc=$?
arm 'L4 a root too long for the socket is not used: Chrome gets the caller TMPDIR' "$SYSTMP" "$(seen tmp)"
# With no per-launch dir the crash dir is a FRESH dir (DIVE-7432), never the
# home (the DIVE-4587 fallback this replaced) and never the shared value.
arm 'L4 ...and the crash dir is a fresh dir under /tmp, never the home nor the shared value' yes \
  "$(yn grep -qE "^/tmp/\.5dive-browser-cfg-$EUID\.[0-9]+\.[0-9]+\.[A-Za-z0-9]{6}/google-chrome/Crash Reports\$" <<<"$(seen crash)")"
c=$(seen crash)
arm 'L4 ...which is gone with the launch' no "$(yn test -e "${c%/google-chrome/*}")"
arm 'L4 ...and launches' 0 "$rc"
: > "$SEEN"
FIVEDIVE_BROWSER_TMP_ROOT="$long" TMPDIR="/tmp/.5dive-browser-0/1.2" HOME="$LONGHOME" "$BROWSER" status launch.test >/dev/null 2>&1
arm 'L4 root'"'"'s per-launch dir handed down by runuser is not inherited' '/tmp' "$(seen tmp)"

# --- L5 the legacy root under $HOME is still reaped ------------------------------
LEG="$LONGHOME/.cache/5dive-browser/tmp"; mkdir -p "$LEG"; chmod 700 "$LEG"
sleep 300 & vp=$!; vs=$(starttime "$vp"); kill -9 "$vp"; wait "$vp" 2>/dev/null
mkdir -p "$LEG/$vp.$vs/scoped_dir1_1"
sleep 300 & lp=$!; _KILL+=("$lp"); ls_=$(starttime "$lp")
mkdir -p "$LEG/$lp.$ls_/scoped_dir1_1"
HOME="$LONGHOME" "$BROWSER" status launch.test >/dev/null 2>&1
arm 'L5 a dead owner'"'"'s dir in the legacy root is reaped' no "$(yn test -e "$LEG/$vp.$vs")"
arm 'L5 a live owner'"'"'s dir in the legacy root survives' yes "$(yn test -e "$LEG/$lp.$ls_")"
kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null

# --- L6 the node launchers --------------------------------------------------------
# The exact block each launcher runs at load, evaluated against three environments.
if command -v node >/dev/null; then
  for f in session-daemon driver-playwright; do
    blk=$(awk '/^if \(!process\.env\.FIVEDIVE_BROWSER_CHROME_CONFIG/{p=1} p{print} p&&/^}/{exit}' "$ROOT/browser/bin/$f")
    arm "L6 $f (control) carries the block" yes "$(yn test -n "$blk")"
    js="$blk"$'\n''process.stdout.write(String(process.env.XDG_CONFIG_HOME))'
    arm "L6 $f drops a shared XDG_CONFIG_HOME" undefined \
      "$(env -u FIVEDIVE_BROWSER_CHROME_CONFIG XDG_CONFIG_HOME=/home/claude/.config node -e "$js")"
    arm "L6 $f keeps the crash dir bin/browser named twice" /tmp/x/1.2 \
      "$(XDG_CONFIG_HOME=/tmp/x/1.2 FIVEDIVE_BROWSER_CHROME_CONFIG=/tmp/x/1.2 node -e "$js")"
    arm "L6 $f drops it when the two disagree" undefined \
      "$(XDG_CONFIG_HOME=/home/claude/.config FIVEDIVE_BROWSER_CHROME_CONFIG=/tmp/x/1.2 node -e "$js")"
  done
else
  arm 'L6 node is on PATH' yes no
fi

# --- L7 a throwaway profile's cache, and what older versions left -----------------
# chill-gorge, 2026-10-15: 473 ~/.cache/tmp.* dirs, 3.1G, each only Default/{Cache,
# Code Cache,...} of a `mktemp -d` profile the probe had already removed.
H7="$TMP/h7"; C7="$TMP/cache7"; mkdir -p "$H7" "$C7"
old() { find "$1" -exec touch -d '2 hours ago' {} +; }
mkleak() { mkdir -p "$C7/$1/Default/Cache" "$C7/$1/Default/Code Cache"; : > "$C7/$1/Default/Cache/data_0"; }
mkleak tmp.AAAAAAAAAA; old "$C7/tmp.AAAAAAAAAA"                       # a leak: reaped
mkleak playwright_chromiumdev_profile-BBBBBB; old "$C7/playwright_chromiumdev_profile-BBBBBB"
mkleak tmp.CCCCCCCCCC                                                    # fresh: a live old launch's
mkleak tmp.DDDDDDDDDD; : > "$C7/tmp.DDDDDDDDDD/notes"; old "$C7/tmp.DDDDDDDDDD"  # more than a cache
mkleak tmp.EEEEEEEEEE; mkdir -p "$C7/tmp.EEEEEEEEEE/Default/Bookmarks"; old "$C7/tmp.EEEEEEEEEE"
mkleak tmp.short; old "$C7/tmp.short"                                    # not a mktemp name
mkdir -p "$C7/fontconfig"; old "$C7/fontconfig"
: > "$SEEN"
out=$(FAKE_FAIL_PAGE=1 HOME="$H7" XDG_CACHE_HOME="$C7" "$BROWSER" status launch.test 2>&1); rc=$?
arm 'L7 (control) the page failed and the probe made its about:blank launch' yes "$(yn test -n "$(seen blankudd)")"
arm 'L7 (control) ...whose profile is a mktemp dir under the per-launch dir' yes \
  "$(yn grep -qE "^$OWNROOT/[0-9]+\.[0-9]+/tmp\.[A-Za-z0-9]{10}\$" <<<"$(seen blankudd)")"
arm 'L7 ...and the box is not called BROKEN' no "$(yn grep -q BROKEN <<<"$out")"
arm 'L7 the throwaway profile kept its cache inside itself' "$(seen blankudd)" "$(seen blankcache)"
arm 'L7 ...so the launch left no tmp.* in the cache home but the planted ones' \
  'tmp.CCCCCCCCCC tmp.DDDDDDDDDD tmp.EEEEEEEEEE tmp.short' "$(cd "$C7" && echo tmp.*)"
arm 'L7 ...and the throwaway profile is gone with its cache' no "$(yn test -e "$(seen blankudd)")"
arm 'L7 an hour-old cache an older version leaked is reaped' no "$(yn test -e "$C7/tmp.AAAAAAAAAA")"
arm 'L7 ...and a Playwright temp profile'"'"'s' no "$(yn test -e "$C7/playwright_chromiumdev_profile-BBBBBB")"
arm 'L7 a fresh one (a launch of an older version may hold it) stays' yes "$(yn test -e "$C7/tmp.CCCCCCCCCC")"
arm 'L7 one holding anything but Default/ stays' yes "$(yn test -e "$C7/tmp.DDDDDDDDDD/notes")"
arm 'L7 one whose Default/ holds more than cache stays' yes "$(yn test -e "$C7/tmp.EEEEEEEEEE/Default/Bookmarks")"
arm 'L7 a name mktemp never makes stays' yes "$(yn test -e "$C7/tmp.short")"
arm 'L7 the rest of the cache home is untouched' yes "$(yn test -d "$C7/fontconfig")"

# --- L8 (DIVE-7432) the claim fails AND the home's google-chrome is not ours ------
# witty-palm, report 604: the box seat's per-launch claim fell back and its
# ~/.config/google-chrome was another seat's (made when /home/claude/.config was
# every seat's shared config home), so every serve trapped rc 133. A squatted
# root (here a symlink, as a root-owned one fails the same -O/-L test) and an
# unwritable google-chrome under a short home stand in for the two.
H8="$TMP/h8"; mkdir -p "$H8/.config/google-chrome"; chmod 500 "$H8/.config/google-chrome"
mkdir -p "$TMP/elsewhere"; ln -s "$TMP/elsewhere" "$TMP/squat"
FB="$TMP/fb"; mkdir -p "$FB"
arm 'L8 (control) this run cannot create the crash dir in the foreign google-chrome' no \
  "$(yn mkdir "$H8/.config/google-chrome/Crash Reports" 2>/dev/null)"
l8() {  # l8 <bin/browser> [<fallback roots>] -> OUT, RC
  : > "$SEEN"
  OUT=$(FIVEDIVE_BROWSER_TMP_ROOT="$TMP/squat" FIVEDIVE_BROWSER_CFG_FALLBACK_ROOTS="${2-$FB}" \
        HOME="$H8" "$1" status launch.test 2>&1); RC=$?
}
l8 "$BROWSER"
arm 'L8 a squatted root and a foreign ~/.config/google-chrome: status launches (rc 0)' 0 "$RC"
arm 'L8 ...and is not BROKEN' no "$(yn grep -q 'BROKEN\|exited 133' <<<"$OUT")"
c=$(seen crash)
arm 'L8 ...Chrome'"'"'s crash dir was a fresh one in the fallback root, not the home' yes \
  "$(yn grep -qE "^$FB/\.5dive-browser-cfg-$EUID\.[0-9]+\.[0-9]+\.[A-Za-z0-9]{6}/google-chrome/Crash Reports\$" <<<"$c")"
arm 'L8 ...which is gone with the launch' no "$(yn test -e "${c%/google-chrome/*}")"
arm 'L8 ...and nothing was written under the squatted root' 0 "$(find "$TMP/elsewhere" -mindepth 1 | wc -l | tr -d ' ')"

# A detached child's fallback dir is reaped once its owner is gone, never before.
sleep 300 & vp=$!; vs=$(starttime "$vp"); kill -9 "$vp"; wait "$vp" 2>/dev/null
mkdir -p "$FB/.5dive-browser-cfg-$EUID.$vp.$vs.AAAAAA/google-chrome"
sleep 300 & lp=$!; _KILL+=("$lp"); ls_=$(starttime "$lp")
mkdir -p "$FB/.5dive-browser-cfg-$EUID.$lp.$ls_.BBBBBB/google-chrome"
mkdir -p "$FB/.5dive-browser-cfg-$EUID.$lp.0.CCCCCC"
l8 "$BROWSER"
arm 'L8 a dead owner'"'"'s fallback dir is reaped' no "$(yn test -e "$FB/.5dive-browser-cfg-$EUID.$vp.$vs.AAAAAA")"
arm 'L8 a live owner'"'"'s survives' yes "$(yn test -e "$FB/.5dive-browser-cfg-$EUID.$lp.$ls_.BBBBBB")"
arm 'L8 ...and one with no start time, while its pid lives' yes "$(yn test -e "$FB/.5dive-browser-cfg-$EUID.$lp.0.CCCCCC")"
kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null

# No fresh dir to be had either: the home is the last resort, and when Chrome
# traps there the message names the dir, its owner and why the claim failed.
l8 "$BROWSER" "$TMP/no-such-root"
arm 'L8 no fallback root at all: the launch traps in the home (rc 133 is said)' yes "$(yn grep -q 'BROKEN.*exited 133' <<<"$OUT")"
arm 'L8 ...the message names the crash dir and its owner' yes \
  "$(yn grep -qF "crash dir $H8/.config/google-chrome ($H8/.config/google-chrome belongs to $(id -un))" <<<"$OUT")"
arm 'L8 ...and why the per-launch claim failed' yes \
  "$(yn grep -qF "the per-launch dir could not be claimed: $TMP/squat is a symlink, and no fresh dir could be made" <<<"$OUT")"

# Negative control: the tree before DIVE-7432 traps on the first case.
# Pinned, not origin/main (once merged origin/main IS the fix). A shallow
# checkout fetches the one commit; if it does not resolve that is a FAIL.
L8_BASE=14959968f654cf578d78e76ffb46b63bfcd58dc4   # 5dive-browser main at 1.66.0
git -C "$ROOT" cat-file -e "$L8_BASE^{commit}" 2>/dev/null \
  || git -C "$ROOT" fetch -q --depth=1 origin "$L8_BASE" >/dev/null 2>&1
if git -C "$ROOT" cat-file -e "$L8_BASE:browser/bin/browser" 2>/dev/null; then
  OLD="$TMP/old"; rm -rf "$OLD"; cp -r "$ROOT/browser" "$OLD"
  git -C "$ROOT" show "$L8_BASE:browser/bin/browser" > "$OLD/bin/browser"; chmod +x "$OLD/bin/browser"
  l8 "$OLD/bin/browser"
  arm 'L8 (negative control) the pre-fix tree traps rc 133 on the same box' yes "$(yn grep -q 'BROKEN.*exited 133' <<<"$OUT")"
  arm 'L8 (negative control) ...with its crash dir in the foreign home dir' "$H8/.config/google-chrome/Crash Reports" "$(seen crash)"
else
  arm "L8 the pinned pre-fix tree $L8_BASE resolves (fetch failed: control NOT run)" yes no
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
