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
#   B5 negative control: the pre-fix bin/browser (pinned commit) leaves the B1 seats storeless.
#   B6 DIVE-7156: root, a person and a hire each also make the box seat's (claude,
#      the owner's logins) store; one it has is untouched; no claude account, no store.
#   B7 negative control: origin/main before DIVE-7156 leaves claude storeless.
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
[[ -n "${FAKE_NO_CLAUDE:-}" && "$u" == claude ]] && exit 1
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
    ${FAKE_NO_CLAUDE:+FAKE_NO_CLAUDE=1} \
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

# --- B6 DIVE-7156: every setup makes the owner's (box seat's) store -------------
# `claude` holds the owner's logins (a login link redeems as it) and is in no
# registry, so neither the back-fill nor a hire made its store before this.
fresh; AS=root go
t  'B6 root setup: the box seat claude has its store'            yes "$(has claude)"
tc 'B6 ...owned by claude'                                     "chown claude $PROFILES/claude" "$(cat "$CALL_LOG")"
tc "B6 ...and says so"                                           "browser store made for the owner's logins (claude)" "$OUT"
t  'B6 ...the ready line is still last'                          'browser ready: agents you hire get a browser' "$(tail -n1 <<<"$OUT")"
fresh; AS=hire go
t  'B6 a hire (agent create, the path every box runs): claude has its store' yes "$(has claude)"
t  'B6 ...and its own'                                           yes "$(has agent-alpha)"
fresh; AS=person go
t  'B6 a person from a sudo user: claude has its store'          yes "$(has claude)"
mkdir -p "$PROFILES/claude"; echo keep > "$PROFILES/claude/marker"; : > "$CALL_LOG"; AS=root go
t  'B6 a store claude already has is untouched'                  keep "$(cat "$PROFILES/claude/marker")"
tn "B6 ...and not re-made"                                       "chown claude" "$(cat "$CALL_LOG")"
fresh; FAKE_NO_CLAUDE=1 AS=root go
t  'B6 a box with no claude account: setup still exits 0'        0 "$RC"
t  'B6 ...and makes no store for it'                             no "$(has claude)"

# --- B5 negative control: the tree before the fix ----------------------------
# Pinned to 1d31aad1's first parent, not origin/main: once the fix merged,
# origin/main IS the fix and the control could not go red (DIVE-7095). A shallow
# CI checkout lacks the pin, so fetch that one commit; if it still does not
# resolve, the control has not run and that is a FAIL, never a skip.
B5_BASE=14a8317d4ca5803e6374dccccefde5aa9d5e54fa
git -C "$ROOT" cat-file -e "$B5_BASE^{commit}" 2>/dev/null \
  || git -C "$ROOT" fetch -q --depth=1 origin "$B5_BASE" >/dev/null 2>&1
OLD="$TMP/old"
if git -C "$ROOT" cat-file -e "$B5_BASE:browser/bin/browser" 2>/dev/null; then
  rm -rf "$OLD"; cp -r "$ROOT/browser" "$OLD"
  git -C "$ROOT" show "$B5_BASE:browser/bin/browser" > "$OLD/bin/browser"; chmod +x "$OLD/bin/browser"
  t  'B5 the pinned tree has no back-fill (anchor)'            0 "$(grep -c '_setup_backfill_seats' "$OLD/bin/browser")"
  fresh "$OLD"; AS=root go
  P0=$PASS F0=$FAIL; b1_arms B5m >/dev/null; RED=$((FAIL-F0)); PASS=$P0; FAIL=$F0
  t  'B5 pre-fix tree: the B1 arms go red (>= 4)'              yes "$( (( RED >= 4 )) && echo yes || echo no)"
  t  'B5 ...it leaves agent-alpha storeless'                   no "$(has agent-alpha)"
else
  t  "B5 the pinned pre-fix tree $B5_BASE resolves (fetch failed: control NOT run)" yes no
fi

# --- B7 negative control: the tree before DIVE-7156 ---------------------------
B7_BASE=a64e495c99d5a2fec8f960492c0de9e2279e5f4e   # 5dive-browser main before DIVE-7156 (1.59.0)
git -C "$ROOT" cat-file -e "$B7_BASE^{commit}" 2>/dev/null \
  || git -C "$ROOT" fetch -q --depth=1 origin "$B7_BASE" >/dev/null 2>&1
if git -C "$ROOT" cat-file -e "$B7_BASE:browser/bin/browser" 2>/dev/null; then
  rm -rf "$OLD"; cp -r "$ROOT/browser" "$OLD"
  git -C "$ROOT" show "$B7_BASE:browser/bin/browser" > "$OLD/bin/browser"; chmod +x "$OLD/bin/browser"
  t  'B7 the pre-7156 tree has no box-seat store step (anchor)'  0 "$(grep -c '_setup_box_seat_store' "$OLD/bin/browser")"
  fresh "$OLD"; AS=root go
  t  'B7 pre-7156 tree: root setup leaves claude storeless'      no "$(has claude)"
  fresh "$OLD"; AS=hire go
  t  'B7 ...and so does a hire'                                  no "$(has claude)"
else
  t  "B7 the pre-7156 tree $B7_BASE resolves (fetch failed: control NOT run)" yes no
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
