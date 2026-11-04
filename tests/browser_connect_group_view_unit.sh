#!/usr/bin/env bash
# DIVE-7674 (box report 688) — Connect for one site of a sign-in group opens the
# person's view ON THAT SITE, never on another site of the group, and never by
# switching a browser another call is using.
#
# On exact-swallow, Connect for business.facebook.com showed cjdropshipping.com:
# the group's one Chrome was in input mode for CJ (its adapter), Facebook has no
# adapter, the seat has a proxy file, and `serve --login` fell through to
# "already serving" — so the owner's one-time viewer showed CJ's live session
# while another seat was driving it.
#
# Through the real bin/browser with a FAKE session daemon that records which
# browser (input or automated) every request reached and the URL each browser
# was started on; x11vnc and websockify are stand-ins that only listen.
#
#   C  a seat with a proxy file (no login), CJ (input) served for the group
#      C1 Connect's `serve --login` for facebook re-serves the group's browser
#         as the automated one, on facebook's URL
#      C2 `viewer` mints on it without switching it again
#      C3 the redeem brings facebook forward in the automated browser
#      C4 CJ busy (another call holds it): refused in plain words, CJ's input
#         browser untouched (no stop, no start)
#   P  a seat with no proxy (plain Chrome for a login)
#      P1 CJ busy: refused, not stopped (the latent sibling, step 5 on the row)
#      P2 CJ free: stopped and re-served as plain Chrome on facebook's URL
#      P3 the automated browser held for reddit.com (another site of the group)
#         by another call: refused, not stopped
#   U  lib/front-tab.cjs inputFront: both sites in input mode, one window
#      U1 a window last sent to CJ: one new tab, facebook's URL typed into it
#      U2 the next Connect for facebook opens no second tab
#      U3 a window last sent to this site is left as it is (a handoff's page)
#      U4 no tab opened: nothing typed
#   S  the daemon's input `front` waits for a request in flight and holds the
#      window while it types (read in the source: input mode needs a real X)
#   N  the 1.67.0 tree on the same fixtures: C1 leaves CJ's input browser and
#      the redeem goes to it (the bug); P1 stops CJ's busy browser; the lib has
#      no input front
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
REAL_DAEMON="$ROOT/browser/bin/session-daemon"
BASE=0806d69   # 5dive-browser main before DIVE-7674 (1.67.0)
TMP="$(mktemp -d /tmp/d7674.XXXXXX)"   # short: a unix socket path is capped at 108 bytes
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
FB=business.facebook.com FBURL=https://business.facebook.com/

FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\n: > "%s/x11/X${1#:}"\nexec sleep 300\n' "$TMP" > "$FAKEBIN/Xvfb"
# Plain Chrome (a login view): records the URL it was opened on, then stays up.
printf '#!/usr/bin/env bash\nprintf "plain %%s\\n" "${@: -1}" >> "%s/starts"\nexec sleep 300\n' "$TMP" > "$FAKEBIN/google-chrome"
# The viewer's two programs: they only listen, on the port they were given.
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
    if (req.op === 'title') { send({ t: 'out', data: JSON.stringify({ drive: 'input', title: 'CJ', handoff: false, viewer: false }) + '\n' }); return end(0); }
    if (req.op === 'front') { send({ t: 'out', data: JSON.stringify({ moved: !input }) + '\n' }); return end(0); }
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

served() {  # how the group's browser is served, and for which site
  [[ -f "$G/.5dive-serve" ]] || { echo none; return; }
  local d; d=$(sed -n 's/^drive=//p' "$G/.5dive-serve")
  [[ -z "$d" ]] && grep -q '^login=1' "$G/.5dive-serve" && d=plain
  echo "${d:-cdp}"
}
lastop() { jq -r -s --arg op "$1" '[.[] | select(.op==$op)] | last | if . then .via + " " + (.url // "") else "none" end' "$DREC"; }
nops() { jq -s --arg op "$1" '[.[] | select(.op==$op)] | length' "$DREC"; }
starts() { wc -l < "$TMP/starts" | tr -d ' '; }
laststart() { tail -1 "$TMP/starts"; }
hold_lease() {  # another seat's call holds the group's browser
  sleep 60 & _HOLDER=$!
  mkdir -p "$G/.5dive-lease"
  printf 'token=%s\nholder=agent-other\non_behalf_of=agent-other\nholder_pid=%s\nkind=agent\npurpose=input:act\nacquired_at=%s\nexpires_at=%s\n' \
    0123456789abcdef0123456789abcdef "$_HOLDER" "$(date -u +%s)" "$(( $(date -u +%s) + 600 ))" > "$G/.5dive-lease/meta"
}
free_lease() { kill "$_HOLDER" 2>/dev/null; wait "$_HOLDER" 2>/dev/null; rm -rf "$G/.5dive-lease"; }
cj_input() { "$1" serve cjdropshipping.com --stop >/dev/null 2>&1; "$1" serve cjdropshipping.com >/dev/null 2>&1; }
redeem() { printf '%s' "$NONCE" | "$1" viewer-redeem "$FB" --nonce=- --session=s1 2>"$TMP/redeem.err"; }

# connect <browser>: what the owner's Connect tap runs, in order (serve --login,
# viewer, redeem). Sets SO/SRC (serve), VRC (viewer), RRC (redeem).
connect() {
  SO=$("$1" serve "$FB" --login 2>&1); SRC=$?
  local v; v=$("$1" viewer "$FB" --bind=s1 2>/dev/null); VRC=$?
  NONCE="${v##*/}"; RRC=x
  (( VRC == 0 )) && { redeem "$1" >/dev/null; RRC=$?; }
}

# ================================================================ C  proxy seat
printf 'socks5://127.0.0.1:1080\n' > "$PX"; chmod 600 "$PX"
cj_input "$BROWSER"
arm 'C0 (precondition) the group browser is CJ'"'"'s, in input mode, on its URL' "input input https://cjdropshipping.com/ cjdropshipping.com" \
  "$(served) $(laststart) $(sed -n 's/^site=//p' "$G/.5dive-serve")"
n=$(starts); connect "$BROWSER"
arm 'C1 Connect for facebook: the group browser is re-served as the automated one, on facebook'"'"'s URL' "0 cdp cdp $FBURL $((n + 1))" \
  "$SRC $(served) $(laststart) $(starts)"
arm 'C1 ...and says so' yes "$(yn grep -q 'was in input mode for cjdropshipping.com; re-serving it on business.facebook.com' <<<"$SO")"
arm 'C2 the viewer mints on that browser without switching it again' "0 $((n + 1))" "$VRC $(starts)"
arm 'C3 the redeem brings facebook forward, in the automated browser (not CJ'"'"'s input window)' "0 cdp $FBURL" "$RRC $(lastop front)"
[[ "$RRC" == 0 ]] || cat "$TMP/redeem.err"

cj_input "$BROWSER"; n=$(starts); sd=$(nops shutdown); hold_lease
connect "$BROWSER"
arm 'C4 CJ busy: Connect for facebook is refused (69) and no viewer is minted' "69 69" "$SRC $VRC"
arm 'C4 ...in plain words, naming the other site' yes "$(yn grep -q 'shares with cjdropshipping.com is in use right now' <<<"$SO")"
arm 'C4 ...and CJ'"'"'s input browser is untouched: not stopped, nothing started' "input $sd $n" "$(served) $(nops shutdown) $(starts)"
free_lease

# ================================================================ P  no proxy
rm -f "$PX"
cj_input "$BROWSER"; n=$(starts); sd=$(nops shutdown); hold_lease
o=$("$BROWSER" serve "$FB" --login 2>&1); rc=$?
arm 'P1 no proxy, CJ busy: refused (69), not stopped' "69 input $sd $n" "$rc $(served) $(nops shutdown) $(starts)"
arm 'P1 ...naming why' yes "$(yn grep -q 'is in use right now' <<<"$o")"
free_lease
o=$("$BROWSER" serve "$FB" --login 2>&1); rc=$?
arm 'P2 no proxy, CJ free: CJ'"'"'s browser stopped, re-served as plain Chrome on facebook'"'"'s URL' "0 plain plain $FBURL $FB" \
  "$rc $(served) $(laststart) $(sed -n 's/^site=//p' "$G/.5dive-serve")"
"$BROWSER" serve "$FB" --stop >/dev/null 2>&1
"$BROWSER" serve reddit.com >/dev/null 2>&1; n=$(starts); sd=$(nops shutdown); hold_lease
o=$("$BROWSER" serve "$FB" --login 2>&1); rc=$?
arm 'P3 the automated browser held for reddit.com by another call: refused (69), not stopped' "69 cdp $sd $n" \
  "$rc $(served) $(nops shutdown) $(starts)"
free_lease
"$BROWSER" serve reddit.com --stop >/dev/null 2>&1

# ================================================================ U  input front
ufront() {  # <lib> -> the four cases as JSON
  node -e '
const t = require(process.argv[1]);
if (typeof t.inputFront !== "function") { console.log(JSON.stringify({ missing: true })); process.exit(0); }
const win = (opens) => { const w = { title: "CJ - Google Chrome", keys: [], typed: [] };
  w.x = { windowTitle: async () => ({ window: w.title, page: w.title }),
          press: async (k) => { w.keys.push(k); if (k === "ctrl+t" && opens) w.title = "New Tab - Google Chrome"; } };
  return w; };
const io = (w) => ({ sleep: async () => {}, keys: async () => {}, typeUrl: async (u) => { w.typed.push(u); } });
(async () => {
  const o = {};
  const a = win(true); a.lastHost = "cjdropshipping.com";
  const r1 = await t.inputFront(a, "https://business.facebook.com/", io(a));
  o.u1 = [r1.moved, r1.opened, a.keys.join(","), a.typed.join(","), a.lastHost].join(" ");
  const r2 = await t.inputFront(a, "https://business.facebook.com/", io(a));
  o.u2 = [r2.moved, a.keys.length, a.typed.length].join(" ");
  const b = win(true); b.lastHost = "www.cjdropshipping.com";
  const r3 = await t.inputFront(b, "https://cjdropshipping.com/", io(b));
  o.u3 = [r3.moved, b.keys.length, b.typed.length].join(" ");
  const c = win(false); c.lastHost = "cjdropshipping.com";
  const r4 = await t.inputFront(c, "https://business.facebook.com/", io(c));
  o.u4 = [r4.moved, c.keys.join(","), c.typed.length, c.lastHost].join(" ");
  console.log(JSON.stringify(o));
})();' "$1"
}
u=$(ufront "$ROOT/browser/lib/front-tab.cjs")
arm 'U1 both sites in input mode, window last sent to CJ: one new tab, facebook typed into it' \
  "true true ctrl+t $FBURL business.facebook.com" "$(jq -r .u1 <<<"$u")"
arm 'U2 the next Connect for facebook opens no second tab' "false 1 1" "$(jq -r .u2 <<<"$u")"
arm 'U3 a window last sent to this site (www. or not) is left as it is: no key pressed' "false 0 0" "$(jq -r .u3 <<<"$u")"
arm 'U4 no new tab came up: nothing typed, the record unchanged' "false ctrl+t 0 cjdropshipping.com" "$(jq -r .u4 <<<"$u")"

# ================================================================ S  daemon source
D="$REAL_DAEMON"
arm 'S1 input front waits for a request in flight, holds the window while it types, releases it' 1 \
  "$(awk '/if \(req.op === .front.\) \{/{p=1} p&&/while \(busy && Date.now\(\) < until\)/{w=NR} p&&/busy = \{ op: .front./{h=NR} p&&/frontRequest\(ctx, input, req, send, end, input && !held\)/{f=NR} p&&/if \(held\) busy = null/{r=NR} p&&/^      \}$/{p=0} END{print (w && h > w && f > h && r > f) ? 1 : 0}' "$D")"
arm 'S2 input frontRequest asks inputFront, and types nothing while another request drives' 1 \
  "$(awk '/^async function frontRequest\(/{p=1} p&&/if \(inUse\)/{i=NR} p&&/frontTab\.inputFront\(ctx, url/{f=NR} p&&/frontTab\.pick\(/{k=NR} p&&/^}/{p=0} END{print (i && f > i && k > f) ? 1 : 0}' "$D")"
arm 'S3 the window'"'"'s record: its start URL, then every goto and screen --url typed into it' 3 \
  "$(grep -c 'lastHost: /^https?:\\/\\//i.test(startUrl)\|be.lastHost = frontTab.hostOf(s.url)\|be.lastHost = frontTab.hostOf(req.url)' "$D")"

# ================================================================ N  the 1.67.0 tree
if git -C "$ROOT" cat-file -e "$BASE:browser/bin/browser" 2>/dev/null; then
  mkdir -p "$TMP/old"; git -C "$ROOT" archive "$BASE" browser | tar -x -C "$TMP/old"
  OLD="$TMP/old/browser/bin/browser"
  printf 'socks5://127.0.0.1:1080\n' > "$PX"; chmod 600 "$PX"
  cj_input "$OLD"; connect "$OLD"
  arm 'N1 control: before the fix, Connect for facebook leaves CJ'"'"'s input browser up and the redeem goes to it' \
    "0 input input $FBURL" "$SRC $(served) $(lastop front)"
  rm -f "$PX"
  cj_input "$OLD"; hold_lease
  "$OLD" serve "$FB" --login >/dev/null 2>&1
  arm 'N2 control: before the fix, a no-proxy Connect stops CJ'"'"'s busy input browser' yes "$(yn test "$(served)" != input)"
  free_lease
  arm 'N3 control: before the fix, the lib has no input front' true "$(ufront "$TMP/old/browser/lib/front-tab.cjs" | jq -r .missing)"
  "$OLD" serve "$FB" --stop >/dev/null 2>&1
else
  SKIP=$((SKIP+1)); echo "SKIP: N1-N3 — base $BASE is not in this checkout"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
