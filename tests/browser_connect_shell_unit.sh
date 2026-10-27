#!/usr/bin/env bash
# DIVE-7078 — a self-hosted box with nobody paired on Telegram: an agent's login
# or check request reaches the owner in their login shell, never "use the dashboard".
#
#   L  login links ON: connect-request (a login, and --challenge) exits 0 and the
#      ask waits in the shell; `asks open` is the tap and prints a working one-time
#      link (its bind registered with the box's own login-link server); `asks done`
#      is the Done, and the agent is told. The agent never sees the link or the code.
#   K  the code cannot be claimed any other way: not by a button tap, not by the
#      agent's own _connect, not twice
#   O  login links OFF: the same ask opens as the SSH steps to the window
#   H  an SSH handoff with nobody to message also waits in the shell, with a Done
#   W  criterion 2: no message on these paths, and no connect-site line for them,
#      says "dashboard"; a hosted box keeps its words
#   N  negative control: the pre-fix tree dies on the same fixture with the
#      dashboard words (skipped where the base commit is not in the checkout)
# Run unprivileged: every seam is honoured only without root.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
BASE=1d31aad   # 5dive-browser main before DIVE-7078
TMP=$(mktemp -d)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }
tn() { if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected NOT to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }

command -v jq >/dev/null || { echo "SKIP: needs jq"; exit 1; }

# ---- the relay seat's browser verbs, and the 5dive CLI's `agent send`, faked ----
cat >"$TMP/fake-browser" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG"
case "$1" in
  viewer)
    printf '/browser/viewer/%s/%s\n' "$2" "$(printf 'a%.0s' $(seq 64))"
    echo "one-time, expires 2099-01-01T00:00:00Z, bound to session ${3#--bind=}. Redeeming it consumes it." >&2
    [[ "$3" == --bind=local ]] \
      && echo "local view: VNC on 127.0.0.1:5917 of this box only, one connection; its one-time password: sudo cat /var/lib/5dive/browser-profiles/claude/$2/.5dive-viewer.pw" >&2 ;;
  snapshot)
    u=""; for a in "${@:2}"; do [[ "$a" =~ ^https?:// ]] && { u="$a"; break; }; done
    jq -nc --arg u "$u" '{url:$u, title:"Just a moment...", http_status:403, nodes:[]}' ;;
  status) echo "  $2 authenticated" ;;
esac
exit 0
SH
cat >"$TMP/fake-5dive" <<'SH'
#!/usr/bin/env bash
{ printf 'ARGS %s\n' "$*"; cat; printf '\n'; } >>"$SENT_LOG"
SH
chmod +x "$TMP/fake-browser" "$TMP/fake-5dive"

ME=$(id -un); WHO="${ME#agent-}"
mkdir -p "$TMP/home" "$TMP/connectors" "$TMP/req" "$TMP/profile.d" "$TMP/link"
printf 'FIVE_DOMAIN=box.example.5dive.ai\n' >"$TMP/hosted.env"
# NO channel: no access.json under the seat's home, no bot token.
export FIVEDIVE_BROWSER_CONNECT_DIR="$TMP/req" FIVEDIVE_CONNECTOR_DIR="$TMP/connectors"
export FIVEDIVE_BROWSER_CONNECT_HOME="$TMP/home" FIVEDIVE_CONNECTORD_ENV="$TMP/no-connectord.env"
export FIVEDIVE_PROVISIONING_ENV="$TMP/no-provisioning.env"
export FIVEDIVE_TELEGRAM_API="http://127.0.0.1:9" FIVEDIVE_SHELLD_URL="http://127.0.0.1:9"
export FIVEDIVE_BROWSER_CONNECT_SELF="$TMP/fake-browser" FIVEDIVE_BROWSER_CONNECT_PRIV="$BROWSER"
export FIVEDIVE_BROWSER_ASKS_DIR="$TMP/asks" FIVEDIVE_BROWSER_PROFILE_D="$TMP/profile.d/5dive-browser-asks.sh"
export FIVEDIVE_BROWSER_SAVED_CLI="$TMP/fake-5dive" FIVEDIVE_BROWSER_CONNECT_LOOK_S=20
export FIVEDIVE_BROWSER_SSH_USER=owner FIVEDIVE_BROWSER_SSH_ADDR=203.0.113.7
export FAKE_LOG="$TMP/fake.log" SENT_LOG="$TMP/sent.log"
export FIVEDIVE_BROWSER_LINK_CONF="$TMP/link/browser-link.env" FIVEDIVE_BROWSER_LINK_STATE="$TMP/link/state"
export FIVEDIVE_BROWSER_LINK_LIB="$TMP/link/lib" FIVEDIVE_BROWSER_LINK_SYSTEMD_DIR="$TMP/link/systemd"
links_on()  { printf 'LINK_MODE=ip\nLINK_HOST=192.0.2.10\nLINK_PORT=3111\n' >"$FIVEDIVE_BROWSER_LINK_CONF"; }
links_off() { rm -f "$FIVEDIVE_BROWSER_LINK_CONF"; }
reset() { : >"$FAKE_LOG"; : >"$SENT_LOG"; rm -rf "${TMP:?}/req" "${TMP:?}/asks" "${TMP:?}/link/state"; mkdir -p "$TMP/req"; }
priv() { printf '%s\0' "$@" | "$BROWSER" _connect; }
code_of() { sed -n "s/^$2=//p" "$TMP/req/shell/$ME.$1" 2>/dev/null; }
ALL_OUT="$TMP/all-out"; : >"$ALL_OUT"
keep() { printf '%s\n' "$1" >>"$ALL_OUT"; printf '%s' "$1"; }

# ---- L: login links on, a login ------------------------------------------------
links_on; reset
out=$(keep "$("$BROWSER" connect-request booking.com --reason="to check this week's orders" 2>&1)"); rc=$?
t  "L1 connect-request with no channel exits 0" 0 "$rc"
tc "L1 ... and says the ask waits in the owner's login shell" "asked in their login shell on this box" "$out"
tc "L1 ... naming what the owner runs" "sudo 5dive browser asks" "$out"
tn "L1 ... with no link in it" "https://" "$out"
tn "L1 ... and no request code in it" "$(code_of booking.com request)" "${out}x"
t  "L1 nothing was bound or served before the owner opens it" "" "$(cat "$FAKE_LOG")"
CODE=$(code_of booking.com request)
t  "L2 root's record holds a 48-hex request code" yes "$([[ "$CODE" =~ ^[0-9a-f]{48}$ ]] && echo yes || echo no)"
t  "L2 ... in a file only its owner can read" 600 "$(stat -c %a "$TMP/req/shell/$ME.booking.com")"
PUB="$TMP/asks/$ME.booking.com.ask"
t  "L2 the readable summary is 0644" 644 "$(stat -c %a "$PUB" 2>/dev/null)"
t  "L2 ... and carries no code" 0 "$(grep -cE '[0-9a-f]{48}' "$PUB")"
HOOK="$FIVEDIVE_BROWSER_PROFILE_D"
tc "L2 the login hook reads the readable summaries" "for _5d_f in $TMP/asks/*.ask" "$(cat "$HOOK" 2>/dev/null)"
t  "L2 ... with no 5dive command in it (a CLI that cannot run must not hide an ask)" 0 "$(grep -c '5dive browser\|command -v 5dive' <(grep -v '^#' "$HOOK"; sed -n 's/.*printf .5dive: .*//p' "$HOOK"))"
tc "L2 ... only for an interactive terminal" '[ -t 1 ] && case "$-" in *i*)' "$(cat "$HOOK")"
t  "L2 ... and it is valid sh" 0 "$(sh -n "$HOOK" 2>&1; echo $?)"
# The hook as a login shell runs it: as a person (a stub `id`), and as an agent
# seat. The terminal test is the one line swapped, since a harness has no tty.
mkdir -p "$TMP/as-owner" "$TMP/as-agent"
printf '#!/bin/sh\necho owner\n' >"$TMP/as-owner/id"; printf '#!/bin/sh\necho agent-clicker\n' >"$TMP/as-agent/id"
chmod +x "$TMP/as-owner/id" "$TMP/as-agent/id"
sed 's/\[ -t 1 \]/true/' "$HOOK" >"$TMP/hook.sh"
login_as() { PATH="$TMP/as-$1:$PATH" sh -ic ". '$TMP/hook.sh'" 2>/dev/null </dev/null; }
out=$(keep "$(login_as owner)")
t  "L3 the owner's login prints the ask, one line" "5dive: $WHO needs you to log in to booking.com in the browser on this box. See it: sudo 5dive browser asks" "$out"
t  "L3 ... and an agent seat's login prints nothing" "" "$(login_as agent)"
t  "L3 ... nor a non-interactive shell" "" "$(PATH="$TMP/as-owner:$PATH" sh -c ". '$TMP/hook.sh'" 2>&1)"
out=$(keep "$("$BROWSER" asks 2>&1)")
tc "L3 the owner's list says an agent is waiting" "5dive: an agent is waiting for you in the browser on this box." "$out"
tc "L3 ... what for" "$WHO needs you to log in to booking.com" "$out"
tc "L3 ... why" "Why: to check this week's orders" "$out"
tc "L3 ... and the command" "Open it:  sudo 5dive browser asks open booking.com" "$out"

# K: the code is the shell's alone.
out=$(priv tap "$CODE" 1234567890 2>&1); rc=$?
t  "K1 a button tap cannot claim a shell ask" 77 "$rc"
tc "K1 ... saying where it waits" "waits in the owner's login shell" "$out"
out=$(priv tap "$CODE" shell 2>&1); rc=$?
t  "K2 the agent's own _connect cannot claim it as 'shell' either" 77 "$rc"
t  "K2 ... and the code is still live for the owner" yes "$([[ -n "$(code_of booking.com request)" ]] && ls "$TMP/req" | grep -qE '^[0-9a-f]{64}$' && echo yes || echo no)"

out=$(keep "$("$BROWSER" asks open booking.com 2>&1)"); rc=$?
t  "L4 asks open exits 0" 0 "$rc"
tc "L4 ... prints a one-time link on the box's own login-link host" "https://192.0.2.10/browser/viewer/booking.com/$(printf 'a%.0s' $(seq 64))" "$out"
tc "L4 ... and the Done command" "sudo 5dive browser asks done booking.com" "$out"
tc "L4 the box browser was served for a person" "serve booking.com --login" "$(cat "$FAKE_LOG")"
t  "L4 the bind went to the login-link server" yes "$([[ -s "$TMP/link/state/binds/booking.com" ]] && echo yes || echo no)"
t  "L4 the request code is spent" "" "$(code_of booking.com request)"
out=$("$BROWSER" asks open booking.com 2>&1); rc=$?
t  "K3 a second open is refused" 77 "$rc"
tn "K3 ... and shows no link again" "https://" "$out"
out=$(keep "$("$BROWSER" asks 2>&1)")
tc "L5 an open ask's notice names the Done" "When you are finished:  sudo 5dive browser asks done booking.com" "$out"

: >"$FAKE_LOG"
out=$(keep "$("$BROWSER" asks done booking.com 2>&1)"); rc=$?
t  "L6 asks done exits 0" 0 "$rc"
tc "L6 ... with the login's verdict" "booking.com is connected. $WHO can use it now." "$out"
t  "L6 Done revokes, stops, then probes" "viewer-revoke booking.com|serve booking.com --stop|status booking.com" "$(tr '\n' '|' <"$FAKE_LOG" | sed 's/|$//')"
tc "L6 the agent is told, by name" "ARGS agent send $WHO --message-file=-" "$(cat "$SENT_LOG")"
tc "L6 ... that the owner finished" "[browser connect] The owner finished logging in to booking.com" "$(cat "$SENT_LOG")"
tc "L6 ... and the owner is told so" "$WHO was told." "$out"
t  "L6 nothing is left waiting" "nothing is waiting for you in the browser on this box." "$("$BROWSER" asks 2>&1)"
t  "L6 ... and no record or code file is left" "" "$(ls "$TMP/req" "$TMP/req/shell" "$TMP/asks" 2>/dev/null | grep -E '[0-9a-f]{64}|\.ask$|booking')"

# L, --challenge: the page is looked at first, then the same shell ask.
reset
PAGE="https://futuretools.io/tools/x"
out=$(keep "$("$BROWSER" connect-request futuretools.io --challenge --url="$PAGE" --reason="finding the tool page" 2>&1)"); rc=$?
t  "L7 connect-request --challenge with no channel exits 0" 0 "$rc"
tc "L7 ... and asks the owner to clear the check, in the shell" "need them to clear a check on futuretools.io" "$out"
tn "L7 ... with no link" "https://" "$(sed "s#$PAGE##g" <<<"$out")"
t  "L7 only the asking seat's look at the page ran" "snapshot $PAGE --json --no-shot" "$(cat "$FAKE_LOG")"
out=$(keep "$("$BROWSER" asks open futuretools.io 2>&1)"); rc=$?
t  "L8 asks open on a check exits 0" 0 "$rc"
tc "L8 ... with a one-time link" "https://192.0.2.10/browser/viewer/futuretools.io/" "$out"
tc "L8 ... on the page the agent stopped at" "serve futuretools.io --login --url=$PAGE" "$(cat "$FAKE_LOG")"
tc "L8 ... and says the agent never solves it" "never solves these" "$out"
out=$(keep "$("$BROWSER" asks done futuretools.io 2>&1)"); rc=$?
t  "L9 asks done on a check exits 0" 0 "$rc"
tc "L9 ... the owner is told the box still sees the check" "still sees a check on futuretools.io" "$out"
tc "L9 the agent gets the challenge note" "[browser challenge] The owner finished on futuretools.io" "$(cat "$SENT_LOG")"

# ---- O: login links off: the same ask opens as the SSH steps --------------------
links_off; reset
out=$(keep "$("$BROWSER" connect-request booking.com 2>&1)"); rc=$?
t  "O1 with login links off, connect-request still exits 0" 0 "$rc"
out=$(keep "$("$BROWSER" asks open booking.com 2>&1)"); rc=$?
t  "O2 asks open exits 0" 0 "$rc"
tc "O2 ... with the tunnel line" "ssh -N -L 5900:127.0.0.1:5917 owner@203.0.113.7" "$out"
tc "O2 ... the password command" "sudo cat /var/lib/5dive/browser-profiles/claude/booking.com/.5dive-viewer.pw" "$out"
tc "O2 ... the Done command" "run on the box: sudo 5dive browser asks done booking.com" "$out"
tc "O2 ... and how to get a link instead" "sudo 5dive browser login-link" "$out"
tc "O2 the view is the loopback one" "viewer booking.com --bind=local" "$(cat "$FAKE_LOG")"
out=$(keep "$("$BROWSER" asks open booking.com 2>&1)"); rc=$?
t  "O3 opening it again shows the same steps (no secret in them)" "0 yes" "$rc $(grep -q 'ssh -N -L' <<<"$out" && echo yes || echo no)"
out=$(keep "$("$BROWSER" asks done booking.com 2>&1)"); rc=$?
t  "O4 asks done exits 0" 0 "$rc"
tc "O4 ... and the agent is told" "[browser connect] The owner finished logging in to booking.com" "$(cat "$SENT_LOG")"

# ---- H: an SSH handoff with nobody to message ------------------------------------
reset
out=$(keep "$(priv handoff tiktok.com "post the draft" 2>&1)"); rc=$?
t  "H1 a handoff with nobody to message exits 0" 0 "$rc"
tc "H1 ... and says the steps wait in the owner's shell" "The steps wait in the owner's login shell on this box" "$out"
out=$(keep "$("$BROWSER" asks 2>&1)")
tc "H2 the owner's login prints the handoff" "5dive: $WHO needs you to take over in tiktok.com" "$(login_as owner)"
tc "H2 the owner's list lists the handoff" "$WHO needs you to take over in tiktok.com" "$out"
out=$(keep "$("$BROWSER" asks open tiktok.com 2>&1)"); rc=$?
t  "H3 asks open shows the steps" "0 yes" "$rc $(grep -q 'sudo 5dive browser asks done tiktok.com' <<<"$out" && echo yes || echo no)"
: >"$FAKE_LOG"
out=$(keep "$("$BROWSER" asks done tiktok.com 2>&1)"); rc=$?
t  "H4 asks done exits 0" 0 "$rc"
t  "H4 ... and hands the window back" "viewer-revoke tiktok.com|handoff tiktok.com --close|status tiktok.com" "$(tr '\n' '|' <"$FAKE_LOG" | sed 's/|$//')"
tc "H4 the agent gets the handoff note" "[browser handoff] The owner finished in tiktok.com" "$(cat "$SENT_LOG")"

# ---- W: no dashboard on these paths; a hosted box keeps its words ---------------
t  "W1 no message on the no-channel paths says 'dashboard'" 0 "$(grep -ci dashboard "$ALL_OUT")"
SKILL="$ROOT/browser/skills/connect-site/SKILL.md"
SELF=$(awk '/On a self-hosted box \(no 5dive domain\) with nobody paired on Telegram/{p=1} p&&/^$/{exit} p' "$SKILL")
tc "W2 the connect-site skill has the self-hosted, no-Telegram paragraph" "sudo 5dive browser asks open <site>" "$SELF"
t  "W2 ... and it does not say dashboard" 0 "$(grep -ci dashboard <<<"$SELF")"
t  "W2 the skill's title does not say dashboard" 0 "$(grep -m1 '^# connect-site' "$SKILL" | grep -ci dashboard)"
t  "W2 ... nor its don't-walk-them line" 0 "$(grep -c 'walk the owner through the dashboard' "$SKILL")"
out=$(FIVEDIVE_PROVISIONING_ENV="$TMP/hosted.env" "$BROWSER" connect-request booking.com 2>&1); rc=$?
t  "W3 a hosted box with no channel still refuses" 69 "$rc"
tc "W3 ... naming its dashboard" "Ask the owner to use Connected sites in the 5dive dashboard." "$out"
out=$("$BROWSER" asks open booking.com 2>&1); rc=$?
t  "W4 asks open with nothing waiting is a usage error" 64 "$rc"
out=$(env -u FIVEDIVE_BROWSER_CONNECT_DIR "$BROWSER" asks open booking.com 2>&1); rc=$?
t  "W5 asks open without root (and without the test seam) is refused" 77 "$rc"
tc "W5 ... naming the sudo command" "sudo 5dive browser asks open booking.com" "$out"

# ---- N: the pre-fix tree on the same fixture -------------------------------------
if git cat-file -e "$BASE:browser/bin/browser" 2>/dev/null; then
  OLD="$TMP/old-browser"; git show "$BASE:browser/bin/browser" >"$OLD"; chmod +x "$OLD"
  links_on; reset
  out=$(FIVEDIVE_BROWSER_CONNECT_PRIV="$OLD" "$OLD" connect-request booking.com 2>&1); rc=$?
  t  "N1 negative control: the pre-fix tree dies on this fixture" 69 "$rc"
  tc "N1 ... with the dashboard words" "Connected sites in the 5dive dashboard" "$out"
  out=$(FIVEDIVE_BROWSER_CONNECT_PRIV="$OLD" "$OLD" connect-request futuretools.io --challenge --url="$PAGE" 2>&1); rc=$?
  t  "N2 negative control: --challenge dies too" 69 "$rc"
else
  echo "SKIP N: $BASE is not in this checkout (a shallow clone)"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
