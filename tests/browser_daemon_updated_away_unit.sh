#!/usr/bin/env bash
# DIVE-8696 — a box browser that outlived its own plugin install steps aside,
# and a brokered caller says "did not answer" instead of a false busy/free.
#
# Box report 1134 (exact-swallow, 2026-11-18): the group browser was started
# through `enabled/browser@5dive-browser`, a link the nightly update moves. Node
# resolved it at start, so the daemon's own bin/browser was in the VERSIONED
# directory, and once that version was pruned every brokered lease call was
# ENOENT with no words. Other seats read "busy: somebody else holds it" while
# `lease --status` read "free", for ~4 days, until a hand `serve --stop`.
#
# The served daemon here is the real bin/session-daemon on the main suite's
# playwright stub, started through a symlinked copy of the plugin
# ($TMP/enabled/browser -> $TMP/cache/1.0.0-test), exactly as a box starts it.
# "The update" is `rm -rf` of that versioned copy. One uid plays both seats: the
# box seat is this user, the agent is FIVEDIVE_BROWSER_SEAT=agent-borrower.
#
#   U1  before the prune, a brokered lease acquire answers a token
#   U2  after the prune: exit 69, the words "updated away" and the version,
#       and NOT the old wordless refusal
#   U3  ...and the daemon exits and its socket goes (it stepped aside)
#   U4  any other brokered request on a pruned daemon steps aside the same way
#   C1  the caller: `lease --take` on a pruned daemon starts the current version
#       (the wake seam) and takes the lease on it, no "busy"
#   C2  the caller: `lease --status` on a daemon that does not answer says so,
#       not "free"
#   C3  the caller: `lease --take` whose daemon call fails with no words says
#       "did not answer", not "busy: somebody else holds it"
#   C4  owner `lease --release` with no lease says "nothing to release"
#   N1  NEGATIVE CONTROL: origin/main's session-daemon in the same install gives
#       U2's case exit 69 with no words at all (the report's state)
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
DAEMON="$ROOT/browser/bin/session-daemon"

TMP="$(mktemp -d)"
PIDS=()
trap 'rc=$?; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; [[ -f "$TMP/woken.pid" ]] && kill "$(cat "$TMP/woken.pid")" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0
arm() {  # arm <name> <expected> <got>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi
}
has() { if grep -qF -- "$1" <<<"$2"; then echo yes; else echo no; fi; }

export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/profiles"
export FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/adapters"; mkdir -p "$FIVEDIVE_BROWSER_ADAPTER_DIR"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/rv"
export FIVEDIVE_BROWSER_SESSION_DAEMON="$DAEMON"     # the CALLER's client: the current version
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli"
export FIVEDIVE_BROWSER_TMP_ROOT="$TMP/tmproot"
export FIVEDIVE_BROWSER_SERVE_MIN_MB=0
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
export FIVEDIVE_BROWSER_STEP_ASIDE_WAIT=15
export PWREC="$TMP/rec.jsonl"
ME="$(id -un)"
AG=agent-borrower
export FIVEDIVE_BROWSER_BOX_SEAT="$ME"
SITE=example.com
DIR="$FIVEDIVE_BROWSER_PROFILE_ROOT/$ME/$SITE"
RVS="$FIVEDIVE_BROWSER_SESSION_ROOT/$ME/$SITE.sock"
mkdir -p "$DIR" "$FIVEDIVE_BROWSER_SESSION_ROOT/$ME" "$FIVEDIVE_BROWSER_TMP_ROOT"
chmod 700 "$FIVEDIVE_BROWSER_PROFILE_ROOT/$ME" "$DIR"
: > "$FIVEDIVE_BROWSER_SESSION_ROOT/$ME/$SITE.offered"

# The main suite's daemon playwright stub.
DSTUB="$TMP/dpw"; mkdir -p "$DSTUB/node_modules/playwright-core"
printf '{ "name": "playwright-core", "version": "0.0.0-daemon-stub", "main": "index.js" }\n' > "$DSTUB/node_modules/playwright-core/package.json"
sed -n "/^cat > \"\$DSTUB\/node_modules\/playwright-core\/index.js\" <<'DPWJS'$/,/^DPWJS$/p" tests/browser_plugin_unit.sh \
  | sed '1d;$d' > "$DSTUB/node_modules/playwright-core/index.js"
arm 'U0 (anchor) the daemon stub was extracted from the main suite' yes \
  "$(grep -q 'launchPersistentContext' "$DSTUB/node_modules/playwright-core/index.js" && echo yes || echo no)"

# A versioned install behind an `enabled/` link, as a box has it.
install() {  # install <version> [<session-daemon to put in it>]
  local v="$1" d="$TMP/cache/$1"
  rm -rf "$d"; mkdir -p "$TMP/cache" "$TMP/enabled"
  cp -a "$ROOT/browser" "$d"
  [[ -n "${2:-}" ]] && cp "$2" "$d/bin/session-daemon"
  jq --arg v "$v" '.version = $v' "$ROOT/browser/.claude-plugin/plugin.json" > "$d/.claude-plugin/plugin.json"
  ln -sfn "$d" "$TMP/enabled/browser"
}
DPID=""
serve_from() {  # serve_from <session-daemon path> <socket>: up and ready, pid in DPID
  rm -f "$2" "$TMP/d.ready"
  env NODE_PATH="$DSTUB/node_modules" FIVEDIVE_BROWSER_CHROME=/bin/true FIVEDIVE_BROWSER_HEADLESS=1 \
    node "$1" serve "$DIR" "$2" --broker > "$TMP/d.ready" 2> "$TMP/d.err" </dev/null &
  DPID=$!; PIDS+=("$DPID")
  for _ in $(seq 80); do grep -q '^ready' "$TMP/d.ready" 2>/dev/null && return 0; sleep 0.1; done
  cat "$TMP/d.err" >&2; return 1
}
gone_within() {  # gone_within <pid> <socket> <seconds> -> yes|no
  local i=0
  while (( i < $3 * 10 )); do
    if ! kill -0 "$1" 2>/dev/null && [[ ! -S "$2" ]]; then echo yes; return; fi
    sleep 0.1; i=$((i + 1))
  done
  echo no
}
call() {  # call <sock> <json> -> OUT ERR RC
  local e="$TMP/call.err"; RC=0
  OUT=$(node "$DAEMON" call "$1" <<<"$2" 2>"$e") || RC=$?
  ERR=$(cat "$e")
}
ACQ='{"op":"lease","act":"acquire","purpose":"harness"}'

# ================================================================ U  the daemon
install 1.0.0-test
serve_from "$TMP/enabled/browser/bin/session-daemon" "$RVS"
arm 'U0 (anchor) the daemon is up, started through the enabled/ link' yes "$(grep -q '^ready' "$TMP/d.ready" && echo yes || echo no)"
call "$RVS" "$ACQ"
arm 'U1 before the prune: a brokered acquire answers a token' '0 yes' "$RC $([[ -n "$OUT" ]] && echo yes || echo no)"
call "$RVS" '{"op":"lease","act":"release","token":"'"$(printf %s "$OUT" | tr -d '\n')"'"}'

rm -rf "$TMP/cache/1.0.0-test"     # the nightly update prunes this version
call "$RVS" "$ACQ"
arm 'U2 after the prune: the acquire exits 69' 69 "$RC"
arm 'U2 ...and says the install was updated away' yes "$(has 'updated away' "$ERR")"
arm 'U2 ...and names the version it was started from' yes "$(has 'plugin 1.0.0-test' "$ERR")"
arm 'U2 ...and hands back no token' '' "$OUT"
arm 'U3 the daemon steps aside: it exits and its socket goes' yes "$(gone_within "$DPID" "$RVS" 15)"

install 1.0.1-test
serve_from "$TMP/enabled/browser/bin/session-daemon" "$RVS"
rm -rf "$TMP/cache/1.0.1-test"
call "$RVS" '{"op":"snapshot","url":"https://example.com/"}'
arm 'U4 any brokered request on a pruned daemon: 69 and "updated away"' '69 yes' "$RC $(has 'updated away' "$ERR")"
arm 'U4 ...and it steps aside' yes "$(gone_within "$DPID" "$RVS" 15)"

# ================================================================ C  the caller (bin/browser)
# The root hop (`sudo -n … _serve-offered`) is the wake seam: it starts the
# CURRENT session-daemon on the rendezvous socket, as the real one would.
cat > "$TMP/wake" <<EOF
#!/usr/bin/env bash
cat >/dev/null
echo woken >> "$TMP/woken.log"
rm -f "$TMP/w.ready"
env FIVEDIVE_BROWSER_SEAT="$ME" NODE_PATH="$DSTUB/node_modules" FIVEDIVE_BROWSER_CHROME=/bin/true FIVEDIVE_BROWSER_HEADLESS=1 \\
  setsid node "$DAEMON" serve "$DIR" "$RVS" --broker > "$TMP/w.ready" 2> "$TMP/w.err" </dev/null &
echo \$! > "$TMP/woken.pid"
for _ in \$(seq 80); do grep -q '^ready' "$TMP/w.ready" 2>/dev/null && exit 0; sleep 0.1; done
exit 1
EOF
chmod +x "$TMP/wake"
export FIVEDIVE_BROWSER_WAKE_PRIV="$TMP/wake"

install 1.0.2-test
serve_from "$TMP/enabled/browser/bin/session-daemon" "$RVS"
OLD=$DPID
rm -rf "$TMP/cache/1.0.2-test"
o1=$(FIVEDIVE_BROWSER_SEAT="$AG" timeout 90 "$BROWSER" lease "$SITE" --take 2>&1); r1=$?
arm 'C1 lease --take on a pruned daemon: exit 0 (taken on the current version)' 0 "$r1"
arm 'C1 ...the current version was started once' 1 "$(grep -c woken "$TMP/woken.log" 2>/dev/null || echo 0)"
arm 'C1 ...and says it restarted the browser after the update' yes "$(has "$SITE was updated; started the current box browser" "$o1")"
arm 'C1 ...no "busy"' no "$(has 'busy' "$o1")"
arm 'C1 ...the old daemon is gone' no "$(kill -0 "$OLD" 2>/dev/null && echo yes || echo no)"
[[ "$r1" == 0 ]] || printf '   C1 output: %s\n' "$o1"

# A daemon that answers ping but fails every lease call with no words: the
# report's state, as the caller saw it, made with a session-daemon client stub.
cat > "$TMP/mute-daemon" <<EOF
#!/usr/bin/env bash
# call <sock>: ping answers; anything else is a wordless 69
[[ "\$1" == call ]] || exit 64
req=\$(cat)
[[ "\$req" == *'"op":"ping"'* ]] && { echo pong; exit 0; }
exit 69
EOF
chmod +x "$TMP/mute-daemon"
o2=$(FIVEDIVE_BROWSER_SEAT="$AG" FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/mute-daemon" "$BROWSER" lease "$SITE" --status 2>&1); r2=$?
arm 'C2 lease --status, daemon gives no answer: not "free"' no "$(has 'free' "$o2")"
arm 'C2 ...says the box browser did not answer, exit 69' 'yes 69' "$(has "the $SITE box browser did not answer" "$o2") $r2"
[[ "$(has "did not answer" "$o2")" == yes ]] || printf "   C2 output: %s\n" "$o2"
o3=$(FIVEDIVE_BROWSER_SEAT="$AG" FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/mute-daemon" "$BROWSER" lease "$SITE" --take 2>&1); r3=$?
arm 'C3 lease --take, daemon gives no answer: not "busy: somebody else holds it"' no "$(has 'somebody else holds it' "$o3")"
arm 'C3 ...says the box browser did not answer, exit 69' 'yes 69' "$(has "the $SITE box browser did not answer" "$o3") $r3"
[[ "$(has "did not answer" "$o3")" == yes ]] || printf "   C3 output: %s\n" "$o3"

# A real holder still reads as busy (the change must not swallow that).
kill "$(cat "$TMP/woken.pid")" 2>/dev/null; sleep 0.3
serve_from "$DAEMON" "$RVS"
# A holder that stays alive: the lease is anchored to a process of this seat.
sleep 600 >/dev/null 2>&1 </dev/null & ANCHOR=$!; PIDS+=("$ANCHOR")
call "$RVS" '{"op":"lease","act":"acquire","purpose":"harness","anchor":'"$ANCHOR"'}'; HELD="$OUT"
o5=$(FIVEDIVE_BROWSER_SEAT="$AG" "$BROWSER" lease "$SITE" --take 2>&1); r5=$?
arm 'C5 (control) a live holder: --take still refuses 69 naming the holder' '69 yes' "$r5 $(has 'busy: held by' "$o5")"
[[ "$r5" == 69 ]] || printf '   C5 output: %s (held=%s)\n' "$o5" "$HELD"
o6=$(FIVEDIVE_BROWSER_SEAT="$AG" "$BROWSER" lease "$SITE" --status 2>&1)
arm 'C6 (control) --status names the holder' yes "$(has 'busy: held by' "$o6")"
call "$RVS" '{"op":"lease","act":"release","token":"'"$(printf %s "$HELD" | tr -d '\n')"'"}'
o7=$(FIVEDIVE_BROWSER_SEAT="$AG" "$BROWSER" lease "$SITE" --status 2>&1)
arm 'C7 (control) released: --status reads free' yes "$(has 'free: nothing holds' "$o7")"

o4=$("$BROWSER" lease "$SITE" --release 2>&1)
arm 'C4 owner --release with no lease: "nothing to release", not "released the stale"' 'yes no' \
  "$(has 'nothing to release' "$o4") $(has 'released the stale' "$o4")"

# ================================================================ N  negative control
if git -C "$ROOT" cat-file -e origin/main:browser/bin/session-daemon 2>/dev/null; then
  git -C "$ROOT" show origin/main:browser/bin/session-daemon > "$TMP/old-daemon"
  if ! grep -q 'updated away' "$TMP/old-daemon"; then
    install 0.9.0-old "$TMP/old-daemon"
    serve_from "$TMP/enabled/browser/bin/session-daemon" "$RVS"
    rm -rf "$TMP/cache/0.9.0-old"
    call "$RVS" "$ACQ"
    arm 'N1 NEGATIVE CONTROL origin/main daemon, pruned: 69 with no words and no token (the report)' '69||' "$RC|$ERR|$OUT"
  else
    printf 'SKIP: N1 origin/main already carries the fix\n'
  fi
else
  printf 'SKIP: N1 no origin/main in this checkout\n'
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
