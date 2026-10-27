#!/usr/bin/env bash
# DIVE-7075 — `sudo 5dive browser setup` run AFTER the hires gives every registered
# seat with no store its store. Before this, a store was made only at `agent create`
# with the plugin already enabled, so a team hired first and browser added after
# came up with no seat able to open a page ("browser ready" printed over all of it).
#
#   B1 root, five registry rows: the two plain seats get stores, the sandboxed one
#      is named and skipped, the one that has a store is untouched, a row with no
#      unix account is left alone. The serve grant stays on the box seat's group.
#   B2 a re-run makes nothing and says nothing new.
#   B3 a person (SUDO_USER) running the same line back-fills too.
#   B4 a hire (FIVEDIVE_BROWSER_SEAT, what agent create passes) never back-fills.
#   B5 negative control: origin/main's bin/browser leaves the B1 seats storeless.
#
# Driven through the real bin/browser as a subprocess, stack step off (the stack is
# browser_setup_stack_unit.sh's), with fakes for id/chown/systemctl/visudo so no
# unix account, unit or sudoers file on the runner is touched.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }
tn() { if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected NOT to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }

# --- the sandbox -------------------------------------------------------------
CORE="$TMP/core"; mkdir -p "$CORE"
for c in bash env sed head tail paste mkdir chmod cat rm cp mv ln stat grep awk timeout \
         tr sort date mktemp dirname basename readlink realpath uname wc cut tee touch sleep \
         jq getent printf ls find xargs flock pgrep sha256sum; do
  p=$(command -v "$c" 2>/dev/null) && [[ "$p" == /* ]] && ln -sf "$p" "$CORE/$c"
done
# id: euid 0; FAKE_USERS are the unix accounts that exist; a seat's primary group
# is its own private one (the 5dive shape that makes the group pin matter).
cat > "$CORE/id" <<'ID'
#!/usr/bin/env bash
case "$*" in
  -u)  echo 0; exit 0 ;;
  -un) echo "${FAKE_UN:-root}"; exit 0 ;;
esac
u="${!#}"
[[ " ${FAKE_USERS:-} claude root " == *" $u "* ]] || exit 1
case "$1" in
  -u)  echo 1000 ;;
  -gn) echo "$u" ;;
  *)   echo "uid=1000($u)" ;;
esac
ID
printf '#!/usr/bin/env bash\necho "chown $*" >> "$CALL_LOG"\n' > "$CORE/chown"
printf '#!/usr/bin/env bash\necho "systemctl $*" >> "$CALL_LOG"\n' > "$CORE/systemctl"
for c in visudo 5dive; do printf '#!/usr/bin/env bash\nexit 0\n' > "$CORE/$c"; done
chmod +x "$CORE/id" "$CORE/chown" "$CORE/systemctl" "$CORE/visudo" "$CORE/5dive"

STATE="$TMP/state"; PROFILES="$STATE/browser-profiles"
fresh() {
  rm -rf "$STATE" "$TMP/systemd" "$TMP/sudoers" "$TMP/pkg"
  mkdir -p "$STATE" "$TMP/systemd" "$TMP/sudoers"
  cp -r "${1:-$ROOT/browser}" "$TMP/pkg"
  cat > "$STATE/agents.json" <<'JSON'
{"agents":{
  "alpha":{"type":"claude","isolation":"standard"},
  "beta":{"type":"claude","isolation":"admin"},
  "gamma":{"type":"claude","isolation":"sandboxed"},
  "delta":{"type":"claude"},
  "ghost":{"type":"claude"}
}}
JSON
  mkdir -p "$PROFILES/agent-delta"; echo keep > "$PROFILES/agent-delta/marker"
  export CALL_LOG="$TMP/calls.log"; : > "$CALL_LOG"
}
go() {  # AS=root|person|hire
  local who=()
  case "${AS:-root}" in
    root)   who=(FAKE_UN=root) ;;
    person) who=(FAKE_UN=ubuntu SUDO_USER=ubuntu) ;;
    hire)   who=(FIVEDIVE_BROWSER_SEAT=agent-alpha) ;;
  esac
  env -i HOME="$TMP" PATH="$CORE" STATE_DIR="$STATE" "${who[@]}" \
    FAKE_USERS="agent-alpha agent-beta agent-gamma agent-delta ubuntu" CALL_LOG="$CALL_LOG" \
    FIVEDIVE_BROWSER_STACK=off FIVEDIVE_BROWSER_PROFILE_ROOT="$PROFILES" \
    FIVEDIVE_BROWSER_SYSTEMD_DIR="$TMP/systemd" FIVEDIVE_BROWSER_SYSTEMCTL=systemctl \
    FIVEDIVE_BROWSER_SUDOERS_DIR="$TMP/sudoers" FIVEDIVE_BROWSER_VISUDO="$CORE/visudo" \
    FIVEDIVE_BROWSER_HOSTED_CONVERGER="$TMP/none" \
    "$TMP/pkg/bin/browser" setup >"$TMP/.o" 2>"$TMP/.e"
  RC=$?; OUT=$(cat "$TMP/.o"); ERR=$(cat "$TMP/.e")
}
has() { [[ -d "$PROFILES/$1" ]] && echo yes || echo no; }

b1_arms() {  # b1_arms <label> — what a root setup after the hires must leave
  t  "$1 root after hires: exits 0"                            0 "$RC"
  t  "$1 ...agent-alpha (standard) has its store"              yes "$(has agent-alpha)"
  t  "$1 ...agent-beta (admin) has its store"                  yes "$(has agent-beta)"
  tc "$1 ...and says which seats it gave one"                  'browser store made for 2 seat(s) hired before the browser: agent-alpha agent-beta' "$OUT"
  tc "$1 ...each store is owned by its seat"                   "chown agent-alpha $PROFILES/agent-alpha" "$(cat "$CALL_LOG")"
  tc "$1 ...each new seat gets its probe timer"                'systemctl enable --now 5dive-browser-probe@agent-beta.timer' "$(cat "$CALL_LOG")"
  tc "$1 ...the serve grant is the box seat's group"           '%claude ALL=(root)' "$(cat "$TMP/sudoers/5dive-browser" 2>/dev/null)"
}

# --- B1 ----------------------------------------------------------------------
fresh; AS=root go
b1_arms B1
t  'B1 ...the sandboxed seat gets none'                        no "$(has agent-gamma)"
tc 'B1 ...and is named, with the command that makes it'        'no browser store for sandboxed agent-gamma: it cannot browse until it has one. Make it with: sudo env FIVEDIVE_BROWSER_SEAT=agent-gamma FIVEDIVE_BROWSER_AGENT_GROUP=claude sudo 5dive browser setup' "$ERR"
t  'B1 ...the seat that had a store is untouched'              keep "$(cat "$PROFILES/agent-delta/marker" 2>/dev/null)"
tn 'B1 ...and is not re-made'                                  'agent-delta' "$(cat "$CALL_LOG")"
tn 'B1 ...nor its timer re-enabled'                            'probe@agent-delta' "$(cat "$CALL_LOG")"
t  'B1 ...a registry row with no unix account gets nothing'    no "$(has agent-ghost)"
tn 'B1 ...nor a failure line'                                  'ghost' "$ERR"
t  'B1 ...root gets no store of its own'                       no "$(has root)"
t  'B1 ...the grant never moves to a seat'"'"'s private group' 0 "$(grep -c '%agent-' "$TMP/sudoers/5dive-browser" 2>/dev/null)"
t  'B1 ...it still ends on the ready line'                     'browser ready: agents you hire get a browser' "$(tail -n1 <<<"$OUT")"

# --- B2 ----------------------------------------------------------------------
: > "$CALL_LOG"; AS=root go
t  'B2 re-run: exits 0'                                        0 "$RC"
tn 'B2 ...makes nothing'                                       'browser store made' "$OUT"
tn 'B2 ...touches no seat'                                     'agent-' "$(cat "$CALL_LOG")"

# --- B3 ----------------------------------------------------------------------
fresh; AS=person go
t  'B3 a person from a sudo user: exits 0'                     0 "$RC"
t  'B3 ...agent-alpha has its store'                           yes "$(has agent-alpha)"
t  'B3 ...agent-beta has its store'                            yes "$(has agent-beta)"
t  'B3 ...and the person their own, as before'                 yes "$(has ubuntu)"

# --- B4 ----------------------------------------------------------------------
fresh; AS=hire go
t  'B4 a hire: its own store'                                  yes "$(has agent-alpha)"
t  'B4 ...and nobody else'"'"'s'                               no "$(has agent-beta)"
tn 'B4 ...says nothing about earlier hires'                    'hired before the browser' "$OUT"

# --- B5 negative control: today's main --------------------------------------
OLD="$TMP/old"; mkdir -p "$OLD/bin"
if git -C "$ROOT" cat-file -e origin/main:browser/bin/browser 2>/dev/null \
   && ! git -C "$ROOT" show origin/main:browser/bin/browser | grep -c '_setup_backfill_seats' >/dev/null; then
  rm -rf "$OLD"; cp -r "$ROOT/browser" "$OLD"
  git -C "$ROOT" show origin/main:browser/bin/browser > "$OLD/bin/browser"; chmod +x "$OLD/bin/browser"
  fresh "$OLD"; AS=root go
  P0=$PASS F0=$FAIL; b1_arms B5m >/dev/null; RED=$((FAIL-F0)); PASS=$P0; FAIL=$F0
  t  'B5 origin/main: the B1 arms go red (>= 4)'               yes "$( (( RED >= 4 )) && echo yes || echo no)"
  t  'B5 ...it leaves agent-alpha storeless'                   no "$(has agent-alpha)"
else
  echo 'B5 skipped: origin/main already carries the back-fill (or is not fetched)'
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
