#!/usr/bin/env bash
# DIVE-6345 — Claude in Chrome for an agent, opt-in.
#
# Driven through the real bin/browser with a fake `claude` and a fake Chrome:
#   C1 connect on a box without the extension refuses (69), names the owner's
#      one command, and creates nothing
#   C2 enable/disable patch the box's Chrome policy: the extension joins the
#      allowlist and forcelist next to uBlock Origin Lite, twice is once, off
#      takes out only its own keys; a box with no policy file gets the blocklist
#      too (root arms: skipped without passwordless sudo)
#   C3 enable as a seat is refused (77): the policy file is root's
#   C4 connect links ~/.config/google-chrome to the agent's claude.ai profile,
#      and leaves a directory already there alone, with a warning
#   C5 the agent's own login counts only with a scope Chrome accepts (a setup
#      token is user:inference only), and connected needs the connect mark too
#   C6 the route: every sign-in stop carries the Claude in Chrome sentence, and
#      it is empty unless connected
#   C7 claude.ai is an input-mode site, and input mode keeps background tabs painting
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"

TMP="$(mktemp -d)"
trap 'rc=$?; sudo -n rm -rf "${TMP:-/nonexistent}" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0
arm() {  # arm <name> <expected> <got>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi
}
yn() { if "$@"; then echo yes; else echo no; fi; }

ID=fcoeoabgfenejglbffodgkkbkcdhcgfn
UBOL=bjnapnkpiihibhjaehecmpbpeejnloib
export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/profiles"
export FIVEDIVE_BROWSER_ADAPTER_DIR="$ROOT/browser/adapters"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/no-rendezvous"
export FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/no-session-daemon"
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli"
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
export FIVEDIVE_BROWSER_X11_DIR="$TMP/x11"; mkdir -p "$FIVEDIVE_BROWSER_X11_DIR"
export STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
export CHROME_POLICY_DIR="$TMP/policy"; mkdir -p "$CHROME_POLICY_DIR"
POL="$CHROME_POLICY_DIR/5dive-browser.json"
unset FIVEDIVE_BROWSER_SEAT
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
printf '#!/bin/sh\n[ "$1" = --version ] && echo "Google Chrome 153.0.8010.36"\nexit 0\n' > "$FAKEBIN/google-chrome"
printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/claude"
chmod +x "$FAKEBIN"/*
export PATH="$FAKEBIN:$PATH"
H="$TMP/home"; mkdir -p "$H"; export HOME="$H"
SEATDIR="$FIVEDIVE_BROWSER_PROFILE_ROOT/$(id -un)"
mkdir -p "$SEATDIR"; chmod 700 "$FIVEDIVE_BROWSER_PROFILE_ROOT" "$SEATDIR"

# --- C1 ----------------------------------------------------------------------
out=$("$BROWSER" claude connect 2>&1); rc=$?
arm 'C1 connect with no extension in the box policy exits 69' 69 "$rc"
arm 'C1 ...and names the owner'"'"'s one command' yes "$(yn grep -q "sudo 5dive agent config $(id -un) set chrome=on" <<<"$out")"
arm 'C1 ...and creates no claude.ai profile' no "$(yn test -e "$SEATDIR/claude.ai")"
arm 'C1 ...and no ~/.config/google-chrome link' no "$(yn test -e "$H/.config/google-chrome")"

# --- C3 ----------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  "$BROWSER" claude enable >/dev/null 2>&1; rc=$?
  arm 'C3 claude enable as a seat is refused (77)' 77 "$rc"
fi
arm 'C3 claude enable|disable stay root under sudo (not dropped to the seat)' yes \
  "$(yn grep -q '"$_v1" == claude && "${2:-}" =~ ^(enable|disable)$ ]] && _v1=claude-box' "$BROWSER")"

# --- C2 (root) ---------------------------------------------------------------
asroot() { sudo -n env PATH="$PATH" STATE_DIR="$STATE_DIR" CHROME_POLICY_DIR="$CHROME_POLICY_DIR" \
  FIVEDIVE_BROWSER_PROFILE_ROOT="$FIVEDIVE_BROWSER_PROFILE_ROOT" "$BROWSER" "$@"; }
if sudo -n true 2>/dev/null; then
  jq -n --arg u "$UBOL" '{ExtensionInstallBlocklist:["*"], ExtensionInstallAllowlist:[$u],
    ExtensionInstallForcelist:[$u+";https://x/ubol.xml"],
    ExtensionSettings:{($u):{installation_mode:"force_installed", runtime_blocked_hosts:["*://a.com"]}}}' > "$POL"
  asroot claude enable >/dev/null 2>&1; rc=$?
  arm 'C2 enable exits 0' 0 "$rc"
  arm 'C2 ...the extension is allowlisted next to uBOL' "$UBOL $ID" "$(jq -r '.ExtensionInstallAllowlist | join(" ")' "$POL")"
  arm 'C2 ...and force-installed from the Web Store' "$ID;https://clients2.google.com/service/update2/crx" "$(jq -r '.ExtensionInstallForcelist[1]' "$POL")"
  arm 'C2 ...uBOL'"'"'s own settings untouched' '*://a.com' "$(jq -r --arg u "$UBOL" '.ExtensionSettings[$u].runtime_blocked_hosts[0]' "$POL")"
  arm 'C2 ...the box mark is written for the nightly converge' yes "$(yn test -f "$STATE_DIR/browser/claude-ext/enabled")"
  arm 'C2 ...the file stays world-readable (every seat'"'"'s Chrome reads it)' 644 "$(stat -c %a "$POL")"
  asroot claude enable >/dev/null 2>&1
  arm 'C2 enable twice is once' 1 "$(jq --arg id "$ID" '[.ExtensionInstallForcelist[] | select(startswith($id))] | length' "$POL")"
  asroot claude disable >/dev/null 2>&1; rc=$?
  arm 'C2 disable exits 0' 0 "$rc"
  arm 'C2 ...takes out only its own keys' "$UBOL|1|null|*" "$(jq -r --arg id "$ID" '[(.ExtensionInstallAllowlist|join(" ")), (.ExtensionInstallForcelist|length|tostring), (.ExtensionSettings[$id]|tostring), .ExtensionInstallBlocklist[0]] | join("|")' "$POL")"
  arm 'C2 ...and removes the mark' no "$(yn test -e "$STATE_DIR/browser/claude-ext/enabled")"
  sudo -n rm -f "$POL"
  asroot claude enable >/dev/null 2>&1
  arm 'C2 a box with no policy file gets one that still blocks every other extension' '*' "$(jq -r '.ExtensionInstallBlocklist[0]' "$POL")"
  sudo -n rm -f "$POL"
  asroot claude disable >/dev/null 2>&1
  arm 'C2 disable on a box with no policy file writes none' no "$(yn test -e "$POL")"
else
  printf 'SKIP: C2 needs passwordless sudo (the policy file is root'"'"'s)\n'
fi

# --- C4 ----------------------------------------------------------------------
jq -n --arg id "$ID" '{ExtensionInstallBlocklist:["*"], ExtensionInstallAllowlist:[$id], ExtensionInstallForcelist:[$id+";https://clients2.google.com/service/update2/crx"]}' > "$POL"
out=$("$BROWSER" claude connect 2>&1); rc=$?
arm 'C4 connect makes the agent'"'"'s claude.ai profile' yes "$(yn test -d "$SEATDIR/claude.ai")"
arm 'C4 ...and links ~/.config/google-chrome to it' "$SEATDIR/claude.ai" "$(readlink "$H/.config/google-chrome")"
arm 'C4 ...and stops honestly when the browser cannot start here (no daemon in this rig)' yes "$(yn test "$rc" -ne 0)"
rm -f "$H/.config/google-chrome"; mkdir -p "$H/.config/google-chrome/Default"
out=$("$BROWSER" claude connect 2>&1)
arm 'C4 an existing ~/.config/google-chrome is left alone' no "$(yn test -L "$H/.config/google-chrome")"
arm 'C4 ...with a warning that says what to do' yes "$(yn grep -q 'move it aside and run connect again' <<<"$out")"

# --- C5 ----------------------------------------------------------------------
# Captured first: under pipefail a `grep -q` that exits early would SIGPIPE the verb.
st() { local o; o=$("$BROWSER" claude status 2>&1); printf '%s\n' "$o"; }
mkdir -p "$H/.claude"
jq -n '{claudeAiOauth:{accessToken:"t", scopes:["user:inference"]}}' > "$H/.claude/.credentials.json"
arm 'C5 a token-only login (user:inference) is not the agent'"'"'s own login' yes "$(st | grep -q '^own login:  no' && echo yes || echo no)"
jq -n '{claudeAiOauth:{accessToken:"t", scopes:["user:inference","user:profile"]}}' > "$H/.claude/.credentials.json"
arm 'C5 a /login with user:profile is' yes "$(st | grep -q '^own login:  yes' && echo yes || echo no)"
arm 'C5 ...but connected needs the connect mark too' yes "$(st | grep -q '^connected:  no' && echo yes || echo no)"
: > "$SEATDIR/.claude-in-chrome"
arm 'C5 with the mark: connected' yes "$(st | grep -q '^connected:  yes' && echo yes || echo no)"
arm 'C5 status reads the box as on' yes "$(st | grep -q '^box:        on' && echo yes || echo no)"

# --- C6 ----------------------------------------------------------------------
arm 'C6 the sign-in redirect stop starts with the route' 1 "$(grep -c 'die "$E_COLD" "$(_cic_route)the page redirected to a sign-in' "$BROWSER")"
arm 'C6 the sign-in form stop starts with the route' 1 "$(grep -c 'die "$E_COLD" "$(_cic_route)the page that came back is a sign-in form' "$BROWSER")"
arm 'C6 Google'"'"'s hard stop starts with the route' 1 "$(grep -c 'die "$E_COLD" "$(_cic_route)STOP: $why ($kind)' "$BROWSER")"
arm 'C6 a consent the owner must judge does NOT route (it stays theirs)' 0 "$(grep -c '$(_cic_route)STOP, ask your owner' "$BROWSER")"
arm 'C6 a robot check does NOT route (never solved by an agent)' 0 "$(grep -c 'robot) die "$E_COLD" "$(_cic_route)' "$BROWSER")"
arm 'C6 the use-browser skill says when, and only then' yes "$(yn grep -q 'Then, and only then, finish that one sign-in step with your Claude in Chrome tools' "$ROOT/browser/skills/use-browser/SKILL.md")"

# --- C7 ----------------------------------------------------------------------
arm 'C7 claude.ai is an input-mode site (plain Chrome keeps extensions)' input "$(jq -r .drive "$ROOT/browser/adapters/claude.ai.json")"
for f in --disable-background-timer-throttling --disable-renderer-backgrounding --disable-backgrounding-occluded-windows; do
  arm "C7 input mode starts Chrome with $f" 1 "$(sed -n '/^function plainArgs/,/^}/p' "$ROOT/browser/bin/session-daemon" | grep -c -- "'$f'")"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
