#!/usr/bin/env bash
# DIVE-8595 — an input-mode status that cannot look NOW keeps the owner's Done.
#
# Box report 1071 (google.com, input mode, 2026-11-16): the owner's Done at
# 13:06Z read `connected (… loaded as "Google Account")`; the agent's next
# `status google.com` read `unconfirmed` (nothing was loaded; the window showed
# a Chrome extensions page) and the agent stopped on a site signed in minutes
# earlier. _input_probe had three branches that never read the Done:
#   A  the group's browser is serving another site as the automated browser
#   B  not checked now: a person in the viewer, a handoff, an agent's lease, or
#      no tab opened for the check (a daemon from before title_probe)
#   C  the probe page did not finish loading (its title is still its address)
#
#   U1-U6  a Done on file + each not-checked branch -> connected, rc 0, and the
#          line says why nothing was checked; nothing is stamped
#   U7     no Done -> unconfirmed, as before; a signed-in read adds "last seen"
#   U8     fail-closed: a sign-in title in front, a challenge title in front, or
#          an unfinished load redirected to a sign-in address -> never connected
#   U9     a Done, then the probe page loads with a sign-in title -> expired, the
#          Done is forgotten, and a later not-checked read is unconfirmed again
#   U10    report 1071's shape with the shipped google.com adapter
#   U11    NEGATIVE CONTROL: origin/main's bin/browser says unconfirmed in B
#
# Driven through the real bin/browser with a FAKE session daemon (the
# browser_served_probe_unit.sh shape: answers title / title_probe from files,
# the client half is the REAL daemon's `call`).
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="${FIVEDIVE_TEST_BROWSER:-$ROOT/browser/bin/browser}"
REAL_DAEMON="$ROOT/browser/bin/session-daemon"

TMP="$(mktemp -d)"
_KILL=()
trap 'rc=$?; for p in "${_KILL[@]}"; do kill -KILL "$p" 2>/dev/null; done; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0
arm() {  # arm <name> <expected> <got>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n   out: %s\n' "$1" "$2" "$3" "${out:-}"; fi
}
has() { if grep -qF -- "$1" <<<"$2"; then echo yes; else echo no; fi; }

export FIVEDIVE_BROWSER_TMP_ROOT="$TMP/tmproot"
export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/profiles"
export FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/adapters"; mkdir -p "$FIVEDIVE_BROWSER_ADAPTER_DIR"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/rv"
export FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/fake-daemon"
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli"
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
export FIVEDIVE_BROWSER_X11_DIR="$TMP/x11"; mkdir -p "$FIVEDIVE_BROWSER_X11_DIR"
unset FIVEDIVE_BROWSER_OWNER_DONE
SEAT="$(id -un)"
mkdir -p "$TMP/profiles/$SEAT" "$TMP/rv/$SEAT"; chmod 711 "$TMP/profiles"; chmod 700 "$TMP/profiles/$SEAT"

FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == --version ]] && { echo "Google Chrome 153.0.8010.36"; exit 0; }\necho "<html></html>"\n' > "$FAKEBIN/google-chrome"
chmod +x "$FAKEBIN/google-chrome"; export PATH="$FAKEBIN:$PATH"

DREC="$TMP/daemon.rec"; : > "$DREC"
cat > "$TMP/fake-daemon" <<DAEMON
#!/usr/bin/env node
'use strict';
const fs = require('fs'), net = require('net'), path = require('path');
const [, , mode, a1, a2] = process.argv;
if (mode === 'call') { const r = require('child_process').spawnSync('$REAL_DAEMON', ['call', a1], { stdio: 'inherit' }); process.exit(r.status === null ? 1 : r.status); }
const profile = a1, sock = a2, input = process.argv[5] === 'input';
const rd = (f, d) => { try { return fs.readFileSync(path.join(profile, f), 'utf8'); } catch (e) { return d; } };
const srv = net.createServer((c) => {
  let buf = '';
  c.on('data', (d) => {
    buf += d; const nl = buf.indexOf('\n'); if (nl < 0) return;
    const req = JSON.parse(buf.slice(0, nl));
    fs.appendFileSync('$DREC', JSON.stringify({ site: path.basename(profile), ...req }) + '\n');
    const send = (o) => c.write(JSON.stringify(o) + '\n');
    const end = (rc) => { send({ t: 'end', rc }); c.end(); };
    const out = (o) => send({ t: 'out', data: JSON.stringify(o) + '\n' });
    if (req.op === 'ping') { send({ t: 'out', data: 'pong\n' }); return end(0); }
    if (input && req.op === 'title') {
      out({ drive: 'input', title: rd('.fake-title-now', 'Whatever Was Left'), handoff: rd('.fake-handoff', '') === '1', viewer: rd('.fake-viewer', '') === '1' });
      return end(0);
    }
    if (input && req.op === 'title_probe' && rd('.fake-old-daemon', '') !== '1') {
      const unloaded = rd('.fake-unloaded', '') === '1';
      out({ drive: 'input', navigated: true, url_requested: req.url, title: rd('.fake-title', ''), loaded: !unloaded }); return end(0);
    }
    send({ t: 'err', msg: "unknown op '" + req.op + "'" }); end(70);
  });
});
try { fs.unlinkSync(sock); } catch (e) {}
srv.listen(sock, () => process.stdout.write('ready\n'));
DAEMON
chmod +x "$TMP/fake-daemon"

P() { echo "$TMP/profiles/$SEAT/$1"; }
# mk <site> <daemon-mode: input|cdp> — an input-mode serve record and a live daemon.
# A cdp daemon answers no `title` in input mode: the group's browser is on another site.
mk() {
  local d; d=$(P "$1"); mkdir -p "$d"; chmod 700 "$d"
  sleep 600 & local xp=$!; _KILL+=("$xp")
  local m=""; [[ "$2" == input ]] && m=input
  "$TMP/fake-daemon" listen "$d" "$d/.5dive-session.sock" $m > "$TMP/d.$1.out" 2>&1 & local dp=$!; _KILL+=("$dp")
  for _ in $(seq 50); do [[ -S "$d/.5dive-session.sock" ]] && break; sleep 0.1; done
  ( umask 077; printf 'display=150\nxvfb_pid=%s\ndaemon_pid=%s\nsock=%s\nstarted_at=%s\ndrive=input\n' \
      "$xp" "$dp" "$d/.5dive-session.sock" "$(date -u +%s)" > "$d/.5dive-serve" )
  printf 'authenticated-from-before' > "$d/.5dive-liveness"
}
done_at() { printf '2026-11-16T13:06Z\n' > "$(P "$1")/.5dive-owner-done"; chmod 600 "$(P "$1")/.5dive-owner-done"; }
st() { out=$("$BROWSER" status "$1" 2>&1); rc=$?; out=$(grep -F "$1" <<<"$out" | head -1); }
stampnow() { cat "$(P "$1")/.5dive-liveness" 2>/dev/null || echo none; }
connected() {  # connected <arm> <site> <why-fragment>
  arm "$1: connected, led by the Done" yes "$(has 'connected (signed in by the owner 2026-11-16T13:06Z; not checked now — ' "$out")"
  arm "$1 ...names why nothing was checked" yes "$(has "$3" "$out")"
  arm "$1 ...tells agents to use it, rc 0" "yes 0" "$(has 'Agents: use it.' "$out") $rc"
  arm "$1 ...stamps nothing (the last verdict stands)" authenticated-from-before "$(stampnow "$2")"
}
lease() {  # an agent holds the browser
  sleep 600 & local lp=$!; _KILL+=("$lp")
  mkdir -p "$(P "$1")/.5dive-lease"
  printf 'token=abc\nholder_pid=%s\nexpires_at=%s\nkind=agent\npurpose=x\n' "$lp" "$(( $(date -u +%s) + 600 ))" > "$(P "$1")/.5dive-lease/meta"
}

# ------------------------------------------------- U1-U6: a Done + each branch
mk ua.test cdp; done_at ua.test; st ua.test
connected 'U1 (A) group browser on another site' ua.test 'serving another site as the automated browser'
mk uv.test input; done_at uv.test; printf 1 > "$(P uv.test)/.fake-viewer"; printf 'Extensions' > "$(P uv.test)/.fake-title-now"; st uv.test
connected 'U2 (B) a person in the viewer' uv.test 'a person is in the viewer; the window shows "Extensions"'
arm 'U2 ...and no title_probe moved the window' 0 "$(jq -s '[.[]|select(.op=="title_probe" and .site=="uv.test")]|length' "$DREC")"
mk uh.test input; done_at uh.test; printf 1 > "$(P uh.test)/.fake-handoff"; st uh.test
connected 'U3 (B) a handoff' uh.test 'the owner has the window (handoff)'
mk ul.test input; done_at ul.test; lease ul.test; st ul.test
connected 'U4 (B) an agent holds the lease' ul.test 'an agent holds the browser'
mk uo.test input; done_at uo.test; printf 1 > "$(P uo.test)/.fake-old-daemon"; st uo.test
connected 'U5 (B) no tab opened for the check' uo.test 'the window shows "Whatever Was Left"'
mk uu.test input; done_at uu.test; printf 1 > "$(P uu.test)/.fake-unloaded"; printf 'uu.test/' > "$(P uu.test)/.fake-title"; st uu.test
connected 'U6 (C) the probe page did not finish loading' uu.test 'did not finish loading, its title is still its address'

# ------------------------------------------------- U7: no Done, as before
for s in ua uv uh ul uo uu; do rm -f "$(P $s.test)/.5dive-owner-done"; done
for s in ua uv uh ul uo uu; do
  st $s.test
  arm "U7 $s, no Done: unconfirmed as before, rc 0, never connected" "yes no 0" \
    "$(has 'unconfirmed (input mode: ' "$out") $(has 'connected (' "$out") $rc"
done
printf '2026-11-15T10:00Z input\n' > "$(P uv.test)/.5dive-signed-in"; st uv.test
arm 'U7 viewer, no Done, a signed-in read: unconfirmed with last seen' "yes yes" \
  "$(has 'unconfirmed (' "$out") $(has 'last seen signed in 2026-11-15T10:00Z' "$out")"
printf '2026-11-15T10:00Z input\n' > "$(P uu.test)/.5dive-signed-in"; st uu.test
arm 'U7 unfinished load, no Done, a signed-in read: unconfirmed with last seen' "yes yes" \
  "$(has 'unconfirmed (' "$out") $(has 'last seen signed in 2026-11-15T10:00Z' "$out")"

# ------------------------------------------------- U8: fail-closed stays
mk us.test input; done_at us.test; printf 1 > "$(P us.test)/.fake-viewer"; printf 'Log in to Us' > "$(P us.test)/.fake-title-now"; st us.test
arm 'U8 a Done, a sign-in title in front: unconfirmed, not connected' "yes no 0" \
  "$(has 'unconfirmed (' "$out") $(has 'connected (' "$out") $rc"
arm 'U8 ...and the Done is kept (that tab may not be this site)' kept "$([[ -e "$(P us.test)/.5dive-owner-done" ]] && echo kept || echo gone)"
mk uc.test input; done_at uc.test; printf 1 > "$(P uc.test)/.fake-viewer"; printf 'Just a moment...' > "$(P uc.test)/.fake-title-now"; st uc.test
arm 'U8 a Done, a challenge title in front: CHALLENGE still wins' "yes 75" "$(has 'CHALLENGE' "$out") $rc"
mk ur.test input; done_at ur.test; printf 1 > "$(P ur.test)/.fake-unloaded"; printf 'ur.test/login?next=/' > "$(P ur.test)/.fake-title"; st ur.test
arm 'U8 a Done, an unfinished load redirected to a sign-in address: unconfirmed' "yes no" \
  "$(has 'unconfirmed (' "$out") $(has 'connected (' "$out")"

# ------------------------------------------------- U9: a sign-in title after a Done
mk ux.test input; done_at ux.test; printf 'Log in to Ux' > "$(P ux.test)/.fake-title"; st ux.test
arm 'U9 a Done, then the probe page loads titled "Log in": expired, rc 75' "yes 75" "$(has 'session expired' "$out") $rc"
arm 'U9 ...the Done is forgotten' gone "$([[ -e "$(P ux.test)/.5dive-owner-done" ]] && echo kept || echo gone)"
printf 1 > "$(P ux.test)/.fake-viewer"; printf 'Ux - Home' > "$(P ux.test)/.fake-title-now"; st ux.test
arm 'U9 ...a later not-checked read is unconfirmed, not connected' "yes no" \
  "$(has 'unconfirmed (' "$out") $(has 'connected (' "$out")"

# ------------------------------------------------- U10: report 1071's shape
cp "$ROOT/browser/adapters/google.com.json" "$FIVEDIVE_BROWSER_ADAPTER_DIR/"
mk google.com input; done_at google.com; printf 1 > "$(P google.com)/.fake-old-daemon"
printf 'Extensions' > "$(P google.com)/.fake-title-now"; st google.com
arm 'U10 google.com, Done at 13:06Z, nothing loaded, extensions page in front: connected' "yes 0" \
  "$(has 'connected (signed in by the owner 2026-11-16T13:06Z' "$out") $rc"
printf 'Sign in - Google Accounts' > "$(P google.com)/.fake-title-now"; st google.com
arm 'U10 ...but "Sign in - Google Accounts" in front is never connected' "yes no" \
  "$(has 'unconfirmed (' "$out") $(has 'connected (' "$out")"

# ------------------------------------------------- U11: negative control
OLD="$TMP/old"
if [[ -z "${FIVEDIVE_TEST_BROWSER:-}" ]] && git -C "$ROOT" cat-file -e origin/main:browser/bin/browser 2>/dev/null \
   && ! git -C "$ROOT" grep -q '_input_unchecked_done' origin/main -- browser/bin/browser 2>/dev/null; then
  mkdir -p "$OLD/bin" "$OLD/lib"
  git -C "$ROOT" show origin/main:browser/bin/browser > "$OLD/bin/browser"; chmod +x "$OLD/bin/browser"
  cp -r "$ROOT/browser/lib/." "$OLD/lib/"; cp "$REAL_DAEMON" "$OLD/bin/"
  mk un.test input; done_at un.test; printf 1 > "$(P un.test)/.fake-viewer"
  out=$("$OLD/bin/browser" status un.test 2>&1 | grep -F un.test | head -1)
  arm 'U11 NEGATIVE CONTROL: origin/main says unconfirmed with a Done on file' "yes no" \
    "$(has 'unconfirmed (' "$out") $(has 'connected (' "$out")"
else
  printf 'SKIP: U11 (origin/main already carries the fix, or is not fetched)\n'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
