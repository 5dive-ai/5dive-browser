#!/usr/bin/env bash
# DIVE-9318 — a second site served on its group's RUNNING browser is shown on its
# own page, never on the first site's.
#
# chill-gorge, 11-25: group Main's one Chrome was up for a client's site. `serve
# bing.com` linked bing.com's socket to it and said "already serving", and nothing
# opened a bing.com tab: the owner's sign-in window for Bing showed that client's
# private account page, and the next act on bing.com read it.
#
# Through the real bin/browser with a FAKE session daemon that records every
# request (which browser it reached, the op, the URL) and the URL each browser was
# started on; x11vnc and websockify are stand-ins that only listen.
#
#   G  the automated browser up for reddit.com (site A), facebook (site B) joins it
#      G1 `serve B` brings B's tab forward: one front with B's URL, nothing stopped
#         or started
#      G2 another call holds the browser: nothing is moved, and serve says so
#      G3 a seat with a proxy (the daemon is kept for a login): Connect's serve,
#         viewer and redeem for B each front B in the automated browser, nothing restarted
#   I  the group's browser in input mode for CJ: `serve B` fronts B through it
#   P  a plain sign-in window open on A (no daemon, so no tab to bring forward)
#      P1 `viewer B` re-serves it on B's URL before minting
#      P2 `serve B --login` re-serves it on B's URL
#      P3 a person is in A's window: refused (69) by name, A's window untouched
#   T  lib/front-tab.cjs plan: a tab on A is never navigated or closed for B
#   N  the 1.97.5 tree on the same fixtures: G1 sends no front (the bug), P1 mints
#      the viewer on A's window
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
REAL_DAEMON="$ROOT/browser/bin/session-daemon"
BASE=e556ed3   # 5dive-browser main before DIVE-9318 (1.97.5)
TMP="$(mktemp -d /tmp/d9318.XXXXXX)"   # short: a unix socket path is capped at 108 bytes
trap 'rc=$?; pkill -f "$TMP/" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0; SKIP=0
arm() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
        else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
yn() { if "$@"; then echo yes; else echo no; fi; }
command -v jq >/dev/null && command -v node >/dev/null || { echo "SKIP: needs jq and node"; exit 1; }

export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/pr" FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/ad"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/rv" FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/fake-daemon"
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli" FIVEDIVE_BROWSER_TMP_ROOT="$TMP/tmproot"
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
export FIVEDIVE_BROWSER_APPROVAL_POLICY="$TMP/no-policy.json" FIVEDIVE_BROWSER_COOKIE_SETTLE=0
export FIVEDIVE_BROWSER_DRIVE_DEFAULT_FILE="$TMP/drive-default" FIVEDIVE_BROWSER_LOGIN_COOKIE_WAIT=0
export FIVEDIVE_BROWSER_WAKE_PRIV="$TMP/no-wake" FIVEDIVE_BROWSER_X11_DIR="$TMP/x11"
SEAT="$(id -un)"
G="$TMP/pr/$SEAT/.group-main"
mkdir -p "$G" "$TMP/ad" "$TMP/x11" "$TMP/rv/$SEAT"; chmod 711 "$TMP/pr"; chmod 700 "$TMP/pr/$SEAT" "$G"
printf 'Main\n' > "$G/.5dive-group-name"
cp "$ROOT/browser/adapters/cjdropshipping.com.json" "$ROOT/browser/adapters/reddit.com.json" "$TMP/ad/"
for s in cjdropshipping.com business.facebook.com reddit.com; do ln -s .group-main "$TMP/pr/$SEAT/$s"; done
PX="$TMP/pr/$SEAT/.5dive-proxy"
A=reddit.com FB=business.facebook.com FBURL=https://business.facebook.com/

FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\n: > "%s/x11/X${1#:}"\nexec sleep 300\n' "$TMP" > "$FAKEBIN/Xvfb"
# Plain Chrome (a sign-in window): records the URL it was opened on (the last
# argument, or the sign-in window's --app=<url>), then stays up.
printf '#!/usr/bin/env bash\nu="${@: -1}"; for a; do [[ $a == --app=* ]] && u=${a#--app=}; done\nprintf "plain %%s\\n" "$u" >> "%s/starts"\nexec sleep 300\n' "$TMP" > "$FAKEBIN/google-chrome"
cat > "$FAKEBIN/x11vnc" <<'X'
#!/usr/bin/env node
const a = process.argv, p = Number(a[a.indexOf('-rfbport') + 1]);
require('net').createServer(() => {}).listen(p, '127.0.0.1'); setTimeout(() => process.exit(0), 300000);
X
cat > "$FAKEBIN/websockify" <<'X'
#!/usr/bin/env node
const p = Number(String(process.argv[2]).split(':').pop());
require('net').createServer(() => {}).listen(p, '127.0.0.1'); setTimeout(() => process.exit(0), 300000);
X
DREC="$TMP/daemon.rec"; : > "$DREC"; : > "$TMP/starts"
cat > "$TMP/fake-daemon" <<DAEMON
#!/usr/bin/env node
'use strict';
const fs = require('fs'), net = require('net');
const [, , mode, profile, ...rest] = process.argv;
if (mode === 'call') { const r = require('child_process').spawnSync('$REAL_DAEMON', ['call', profile], { stdio: 'inherit' }); process.exit(r.status === null ? 1 : r.status); }
const input = rest.includes('--input');
const sock = rest.filter(a => !a.startsWith('--'))[0];
fs.appendFileSync('$TMP/starts', (input ? 'input' : 'cdp') + ' ' + (process.env.FIVEDIVE_BROWSER_START_URL || '') + '\n');
const srv = net.createServer((c) => {
  let buf = '';
  c.on('data', (d) => {
    buf += d; const nl = buf.indexOf('\n'); if (nl < 0) return;
    const req = JSON.parse(buf.slice(0, nl));
    fs.appendFileSync('$DREC', JSON.stringify({ via: input ? 'input' : 'cdp', op: req.op, url: req.url }) + '\n');
    const send = (o) => c.write(JSON.stringify(o) + '\n');
    const end = (rc) => { send({ t: 'end', rc }); c.end(); };
    if (req.op === 'ping') { send({ t: 'out', data: 'pong\n' }); return end(0); }
    if (req.op === 'shutdown') { end(0); srv.close(); try { fs.unlinkSync(sock); } catch (e) {} process.exit(0); }
    if (req.op === 'title') { send({ t: 'out', data: JSON.stringify({ drive: input ? 'input' : 'cdp', title: 'A', handoff: false, viewer: false }) + '\n' }); return end(0); }
    if (req.op === 'front') { send({ t: 'out', data: JSON.stringify({ moved: true, opened: true }) + '\n' }); return end(0); }
    send({ t: 'out', data: '{}\n' }); end(0);
  });
});
try { fs.unlinkSync(sock); } catch (e) {}
srv.listen(sock, () => process.stdout.write('ready sock=' + sock + '\n'));
process.on('SIGTERM', () => { try { fs.unlinkSync(sock); } catch (e) {} process.exit(0); });
DAEMON
chmod +x "$FAKEBIN"/* "$TMP/fake-daemon"
export PATH="$FAKEBIN:$PATH"
cd "$TMP"

served() {  # how the group's browser is served
  [[ -f "$G/.5dive-serve" ]] || { echo none; return; }
  local d; d=$(sed -n 's/^drive=//p' "$G/.5dive-serve")
  [[ -z "$d" ]] && grep -q '^login=1' "$G/.5dive-serve" && d=plain
  echo "${d:-cdp}"
}
servedfor() { sed -n 's/^site=//p' "$G/.5dive-serve" 2>/dev/null; }
lastop() { jq -r -s --arg op "$1" '[.[] | select(.op==$op)] | last | if . then .via + " " + (.url // "") else "none" end' "$DREC"; }
nops() { jq -s --arg op "$1" '[.[] | select(.op==$op)] | length' "$DREC"; }
starts() { wc -l < "$TMP/starts" | tr -d ' '; }
laststart() { tail -1 "$TMP/starts"; }
hold_lease() {  # another seat's call holds the group's browser
  sleep 60 & _HOLDER=$!
  mkdir -p "$G/.5dive-lease"
  printf 'token=%s\nholder=agent-other\non_behalf_of=agent-other\nholder_pid=%s\nkind=agent\npurpose=act\nacquired_at=%s\nexpires_at=%s\n' \
    0123456789abcdef0123456789abcdef "$_HOLDER" "$(date -u +%s)" "$(( $(date -u +%s) + 600 ))" > "$G/.5dive-lease/meta"
}
free_lease() { kill "$_HOLDER" 2>/dev/null; wait "$_HOLDER" 2>/dev/null; rm -rf "$G/.5dive-lease"; }
stop_all() { "$1" serve "$A" --stop >/dev/null 2>&1; "$1" viewer-revoke "$A" >/dev/null 2>&1; true; }
auto_a() { stop_all "$1"; "$1" serve "$A" >/dev/null 2>&1; }          # the automated browser, started for A
plain_a() { stop_all "$1"; "$1" serve "$A" --login >/dev/null 2>&1; }  # A's sign-in window, no daemon

# ================================================================ G  automated browser
rm -f "$PX"
auto_a "$BROWSER"
arm 'G0 (precondition) the group browser is the automated one, started for reddit.com' "cdp $A" "$(served) $(servedfor)"
n=$(starts); sd=$(nops shutdown); f=$(nops front)
o=$("$BROWSER" serve "$FB" 2>&1); rc=$?
arm 'G1 serve facebook on it: already serving, and ONE front with facebook'"'"'s URL in that browser' \
  "0 yes $((f + 1)) cdp $FBURL" "$rc $(yn grep -q '^already serving business.facebook.com' <<<"$o") $(nops front) $(lastop front)"
arm 'G1 ...nothing stopped, nothing started, still the browser started for reddit.com' "$sd $n cdp $A" \
  "$(nops shutdown) $(starts) $(served) $(servedfor)"

f=$(nops front); hold_lease
o=$("$BROWSER" serve "$FB" 2>&1); rc=$?
arm 'G2 another call holds it: serve still answers (0), and NO front is sent' "0 $f" "$rc $(nops front)"
arm 'G2 ...and says the tab was not brought forward, and why' yes "$(yn grep -q 'is in use (.*), so its tab was not brought forward' <<<"$o")"
free_lease

printf 'socks5://127.0.0.1:1080\n' > "$PX"; chmod 600 "$PX"
n=$(starts); f=$(nops front)
"$BROWSER" serve "$FB" --login >/dev/null 2>&1; src=$?
v=$("$BROWSER" viewer "$FB" --bind=s1 2>/dev/null); vrc=$?
rrc=x; (( vrc == 0 )) && { printf '%s' "${v##*/}" | "$BROWSER" viewer-redeem "$FB" --nonce=- --session=s1 >/dev/null 2>&1; rrc=$?; }
arm 'G3 proxy seat, Connect for facebook: serve, viewer and redeem each 0; a front from each (serve, the viewer'"'"'s serve, redeem), the last on facebook' \
  "0 0 0 $((f + 3)) cdp $FBURL" "$src $vrc $rrc $(nops front) $(lastop front)"
arm 'G3 ...and the browser was not restarted' "$n cdp" "$(starts) $(served)"
rm -f "$PX"; "$BROWSER" viewer-revoke "$FB" >/dev/null 2>&1

# ================================================================ I  input mode
stop_all "$BROWSER"; "$BROWSER" serve cjdropshipping.com >/dev/null 2>&1
n=$(starts); f=$(nops front)
o=$("$BROWSER" serve "$FB" 2>&1); rc=$?
arm 'I1 the group browser in input mode for CJ: serve facebook fronts facebook through it, nothing restarted' \
  "input 0 $((f + 1)) input $FBURL $n" "$(served) $rc $(nops front) $(lastop front) $(starts)"

# ================================================================ P  a sign-in window on A
plain_a "$BROWSER"
arm 'P0 (precondition) a plain sign-in window open on reddit.com, no daemon' "plain $A" "$(served) $(servedfor)"
n=$(starts)
v=$("$BROWSER" viewer "$FB" --bind=s1 2>"$TMP/v.err"); vrc=$?
arm 'P1 viewer for facebook: re-served on facebook'"'"'s URL before the link is minted' \
  "0 plain plain $FBURL $FB $((n + 1))" "$vrc $(served) $(laststart) $(servedfor) $(starts)"
[[ "$vrc" == 0 ]] || cat "$TMP/v.err"
"$BROWSER" viewer-revoke "$FB" >/dev/null 2>&1

plain_a "$BROWSER"; n=$(starts)
o=$("$BROWSER" serve "$FB" --login 2>&1); rc=$?
arm 'P2 serve facebook --login: the window open on reddit.com is re-served on facebook'"'"'s URL' \
  "0 plain plain $FBURL $FB $((n + 1))" "$rc $(served) $(laststart) $(servedfor) $(starts)"
arm 'P2 ...and says so' yes "$(yn grep -q 'was open on reddit.com; re-serving it on business.facebook.com' <<<"$o")"

plain_a "$BROWSER"
"$BROWSER" viewer "$A" --bind=s2 >/dev/null 2>&1   # a person is in reddit.com's window
n=$(starts)
o=$("$BROWSER" serve "$FB" --login 2>&1); rc=$?
arm 'P3 a person is in reddit.com'"'"'s window: refused (69), the window untouched' "69 plain $A $n" \
  "$rc $(served) $(servedfor) $(starts)"
arm 'P3 ...naming the other site, and that nothing is shown' yes \
  "$(yn grep -q 'is open on reddit.com and in use right now.*nobody sees reddit.com instead of business.facebook.com' <<<"$o")"
stop_all "$BROWSER"

# ================================================================ T  front-tab plan
t=$(node -e '
const t = require(process.argv[1]);
const pg = (u) => ({ url: () => u, isClosed: () => false });
const a = pg("https://www.reddit.com/r/x"), blank = pg("about:blank");
const p1 = t.plan([a], "business.facebook.com", a);
const p2 = t.plan([a, blank], "business.facebook.com", a);
console.log([p1.keep === null && p1.reuse === null, p1.close.length, p2.reuse === blank, p2.close.includes(a)].join(" "));
' "$ROOT/browser/lib/front-tab.cjs")
arm 'T1 a tab on reddit.com is never taken for facebook: a new tab (or a blank one) is, and reddit'"'"'s is not closed' \
  "true 0 true false" "$t"

# ================================================================ N  the 1.97.5 tree
if git -C "$ROOT" cat-file -e "$BASE:browser/bin/browser" 2>/dev/null; then
  mkdir -p "$TMP/old"; git -C "$ROOT" archive "$BASE" browser | tar -x -C "$TMP/old"
  OLD="$TMP/old/browser/bin/browser"
  auto_a "$OLD"; f=$(nops front)
  "$OLD" serve "$FB" >/dev/null 2>&1
  arm 'N1 control: before the fix, serve facebook on reddit.com'"'"'s running browser sends no front' "$f" "$(nops front)"
  plain_a "$OLD"; n=$(starts)
  "$OLD" viewer "$FB" --bind=s1 >/dev/null 2>&1; vrc=$?
  arm 'N2 control: before the fix, the viewer for facebook mints on reddit.com'"'"'s window' "0 $A $n" "$vrc $(servedfor) $(starts)"
  stop_all "$OLD"; "$OLD" viewer-revoke "$FB" >/dev/null 2>&1
else
  SKIP=$((SKIP+1)); echo "SKIP: N1-N2 — base $BASE is not in this checkout"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
