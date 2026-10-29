#!/usr/bin/env bash
# DIVE-7237 — the box's logins share one Chrome per group, and the dropshipping
# run (DIVE-6902, 10-29) needed 6 root steps because of it. This grades the
# fixes through the real script with a FAKE session daemon that records which
# browser (input or automated) every request reached.
#
#   G  GAP-6: a group's browser in input mode for one site (tiktok.com stands in
#      for CJ) no longer blocks a page verb on another site of the group
#      (reddit.com stands in for Shopify): the verb re-serves it as the automated
#      browser and reaches it; the input site's next verb switches it back.
#        G1 owner seat   G2 back to input   G3 refused, by name, while another
#        call holds the browser, and nothing is switched   G4 a brokered seat
#   B  GAP-6b: a brokered `status` of the input site, while the group serves the
#      other site, neither starts nor switches a browser, and says why
#   R  GAP-10: a brokered seat restarts the box browser itself (`serve --restart`)
#      through the grant it already has, in the mode the site needs; its own
#      input verb switches it too; a stop stays the owner's and names --restart;
#      a restart under another call is refused
#   N  negative control: the pre-fix tree refuses G1's verb with the INPUT-mode
#      message (skipped where the base commit is not in the checkout)
# Run unprivileged: every seam is honoured only without root.
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
REAL_DAEMON="$ROOT/browser/bin/session-daemon"
BASE=46ef3a5   # 5dive-browser main before DIVE-7237
TMP="$(mktemp -d /tmp/d7237.XXXXXX)"   # short: a unix socket path is capped at 108 bytes
_KILL=()
trap 'rc=$?; for p in "${_KILL[@]}"; do kill "$p" 2>/dev/null; done; pkill -f "$TMP/" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0
arm() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
        else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
yn() { if "$@"; then echo yes; else echo no; fi; }
command -v jq >/dev/null && command -v node >/dev/null || { echo "SKIP: needs jq and node"; exit 1; }

export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/pr" FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/ad"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/rv" FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/fake-daemon"
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli" FIVEDIVE_BROWSER_TMP_ROOT="$TMP/tmproot"
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
export FIVEDIVE_BROWSER_APPROVAL_POLICY="$TMP/no-policy.json" FIVEDIVE_BROWSER_COOKIE_SETTLE=0
export FIVEDIVE_BROWSER_DRIVE_DEFAULT_FILE="$TMP/drive-default"
export FIVEDIVE_BROWSER_WAKE_PRIV="$TMP/no-wake" FIVEDIVE_BROWSER_X11_DIR="$TMP/x11"
SEAT="$(id -un)"
G="$TMP/pr/$SEAT/.group-main"
mkdir -p "$G" "$TMP/ad" "$TMP/x11" "$TMP/rv/$SEAT"; chmod 711 "$TMP/pr"; chmod 700 "$TMP/pr/$SEAT" "$G"
printf 'Main\n' > "$G/.5dive-group-name"
cp "$ROOT/browser/adapters/tiktok.com.json" "$ROOT/browser/adapters/reddit.com.json" "$TMP/ad/"
ln -s .group-main "$TMP/pr/$SEAT/tiktok.com"; ln -s .group-main "$TMP/pr/$SEAT/reddit.com"

FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\n: > "%s/x11/X${1#:}"\nexec sleep 300\n' "$TMP" > "$FAKEBIN/Xvfb"
printf '#!/usr/bin/env bash\necho fake chrome >&2; exit 1\n' > "$FAKEBIN/google-chrome"
DREC="$TMP/daemon.rec"; : > "$DREC"; : > "$TMP/daemon.argv"
cat > "$TMP/fake-daemon" <<DAEMON
#!/usr/bin/env node
'use strict';
const fs = require('fs'), net = require('net');
const [, , mode, profile, ...rest] = process.argv;
if (mode === 'call') { const r = require('child_process').spawnSync('$REAL_DAEMON', ['call', profile], { stdio: 'inherit' }); process.exit(r.status === null ? 1 : r.status); }
const input = rest.includes('--input');
const sock = rest.filter(a => !a.startsWith('--'))[0];
fs.appendFileSync('$TMP/daemon.argv', process.argv.slice(2).join(' ') + '\n');
const PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC';
const srv = net.createServer((c) => {
  let buf = '';
  c.on('data', (d) => {
    buf += d; const nl = buf.indexOf('\n'); if (nl < 0) return;
    const req = JSON.parse(buf.slice(0, nl));
    fs.appendFileSync('$DREC', JSON.stringify({ via: input ? 'input' : 'cdp', op: req.op }) + '\n');
    const send = (o) => c.write(JSON.stringify(o) + '\n');
    const end = (rc) => { send({ t: 'end', rc }); c.end(); };
    if (req.op === 'ping') { send({ t: 'out', data: 'pong\n' }); return end(0); }
    if (req.op === 'lease') { send({ t: 'out', data: req.act === 'acquire' ? 'fedcba9876543210fedcba9876543210\n' : 'free\n' }); return end(0); }
    if (req.op === 'shutdown') { end(0); srv.close(); try { fs.unlinkSync(sock); } catch (e) {} process.exit(0); }
    if (!input) { send({ t: 'out', data: JSON.stringify({ url: 'https://www.reddit.com/', title: 'Reddit', nodes: [] }) + '\n' }); return end(0); }
    if (req.op === 'title') { send({ t: 'out', data: JSON.stringify({ drive: 'input', title: 'Fake Page', handoff: false, viewer: false }) + '\n' }); return end(0); }
    if (req.op === 'screen' || req.op === 'input') {
      send({ t: 'out', data: JSON.stringify({ drive: 'input', title: 'Fake Page', width: 1280, height: 800, png_b64: PNG, act_report: req.op === 'input' || undefined, steps_run: req.op === 'input' ? req.steps.length : undefined }) + '\n' });
      return end(0);
    }
    send({ t: 'err', msg: 'served in INPUT mode, refused ' + req.op }); end(70);
  });
});
try { fs.unlinkSync(sock); } catch (e) {}
srv.listen(sock, () => process.stdout.write('ready sock=' + sock + '\n'));
process.on('SIGTERM', () => { try { fs.unlinkSync(sock); } catch (e) {} process.exit(0); });
DAEMON
chmod +x "$FAKEBIN/Xvfb" "$FAKEBIN/google-chrome" "$TMP/fake-daemon"
export PATH="$FAKEBIN:$PATH"
cd "$TMP"
served() { local d; d=$(sed -n 's/^drive=//p' "$G/.5dive-serve" 2>/dev/null); [[ -f "$G/.5dive-serve" ]] && echo "${d:-cdp}" || echo none; }
lastvia() { jq -r -s --arg op "$1" '[.[] | select(.op==$op)] | last | .via // "none"' "$DREC"; }
starts() { wc -l < "$TMP/daemon.argv" | tr -d ' '; }
hold_lease() {  # another call holds the group's browser for <s> seconds
  sleep "$1" & _HOLDER=$!
  mkdir -p "$G/.5dive-lease"
  printf 'token=%s\nholder=agent-other\non_behalf_of=agent-other\nholder_pid=%s\nkind=agent\npurpose=input:act\nacquired_at=%s\nexpires_at=%s\n' \
    0123456789abcdef0123456789abcdef "$_HOLDER" "$(date -u +%s)" "$(( $(date -u +%s) + 600 ))" > "$G/.5dive-lease/meta"
}
free_lease() { kill "$_HOLDER" 2>/dev/null; wait "$_HOLDER" 2>/dev/null; rm -rf "$G/.5dive-lease"; }

# ---- G: the owner seat ------------------------------------------------------
o=$("$BROWSER" serve tiktok.com 2>&1); rc=$?
arm 'G0 (precondition) the group browser is served in input mode, for tiktok.com' "0 input" "$rc $(served)"
o=$("$BROWSER" tree reddit.com https://www.reddit.com/ 2>&1); rc=$?
arm 'G1 a page verb on the other site of the group is not refused for input mode' no "$(yn grep -q 'INPUT mode' <<<"$o")"
arm 'G1 ...it re-served the group browser as the automated one and reached it' "cdp cdp" "$(served) $(lastvia tree)"
arm 'G1 ...and said so' yes "$(yn grep -q 're-serving it as the automated browser for reddit.com' <<<"$o")"
[[ "$(lastvia tree)" == cdp ]] || printf 'G1 output: %s\n' "$o"
o=$("$BROWSER" shot tiktok.com --out="$TMP/g2.png" 2>&1); rc=$?
arm 'G2 the input site'"'"'s next verb switches it back and gets its screen' "0 input input yes" "$rc $(served) $(lastvia screen) $(yn test -s "$TMP/g2.png")"
n=$(starts); hold_lease 30
o=$("$BROWSER" tree reddit.com https://www.reddit.com/ 2>&1); rc=$?
arm 'G3 while another call holds the browser, the switch is refused (69) and nothing restarts' "69 input $n" "$rc $(served) $(starts)"
arm 'G3 ...naming why' yes "$(yn grep -q 'not switching it under them' <<<"$o")"
free_lease

# ---- G4/B/R: a brokered seat (no store of its own, the box's logins) ----------
brk() { FIVEDIVE_BROWSER_SEAT=agent-borrower FIVEDIVE_BROWSER_BOX_SEAT="$SEAT" FIVEDIVE_BROWSER_WAKE_PRIV="$BROWSER" "$BROWSER" "$@"; }
o=$(brk tree reddit.com https://www.reddit.com/ 2>&1); rc=$?
arm 'G4 a brokered page verb on the other site switches the box browser, as the owner' "cdp cdp" "$(served) $(lastvia tree)"
arm 'G4 ...not refused for input mode, nor sent to a person' "no no" "$(yn grep -q 'INPUT mode' <<<"$o") $(yn grep -q 'sudo' <<<"$o")"
[[ "$(lastvia tree)" == cdp ]] || printf 'G4 output: %s\n' "$o"
n=$(starts)
o=$(brk status tiktok.com 2>&1); rc=$?
arm 'B1 a brokered status of the input site starts and switches nothing' "cdp $n" "$(served) $(starts)"
arm 'B1 ...and says the check is not done now, and why' yes "$(yn grep -q 'a status check does not switch it' <<<"$o")"
[[ "$o" == *'does not switch it'* ]] || printf 'B1 output: %s\n' "$o"
o=$(brk shot tiktok.com --out="$TMP/r1.png" 2>&1); rc=$?
arm 'R1 a brokered input verb switches the box browser to input itself (no root step)' "0 input yes" "$rc $(served) $(yn test -s "$TMP/r1.png")"
[[ "$rc" == 0 ]] || printf 'R1 output: %s\n' "$o"
n=$(starts)
o=$(brk serve tiktok.com --restart 2>&1); rc=$?
arm 'R2 a brokered seat restarts the box browser (serve --restart): stopped, started again, input' "0 input $((n + 1))" "$rc $(served) $(starts)"
arm 'R2 ...and is told so' yes "$(yn grep -q 'restarted tiktok.com' <<<"$o")"
[[ "$rc" == 0 ]] || printf 'R2 output: %s\n' "$o"
o=$(brk serve reddit.com --restart 2>&1); rc=$?
arm 'R3 a restart for the other site comes back the way THAT site needs' "0 cdp" "$rc $(served)"
o=$(brk serve tiktok.com --stop 2>&1); rc=$?
arm 'R4 a brokered stop stays the owner'"'"'s (77), and names --restart' "77 yes cdp" "$rc $(yn grep -q 'serve tiktok.com --restart' <<<"$o") $(served)"
n=$(starts); hold_lease 30
o=$(brk serve tiktok.com --restart 2>&1); rc=$?
arm 'R5 a restart while another call holds the browser is refused, nothing restarted' "69 cdp $n" "$rc $(served) $(starts)"
free_lease

# ---- N: the pre-fix tree, on G1's fixture ------------------------------------
if git -C "$ROOT" cat-file -e "$BASE:browser/bin/browser" 2>/dev/null; then
  OLD="$TMP/old/browser/bin"; mkdir -p "$OLD"
  git -C "$ROOT" archive "$BASE" browser | tar -x -C "$TMP/old"
  "$BROWSER" serve tiktok.com --restart >/dev/null 2>&1
  o=$("$OLD/browser" tree reddit.com https://www.reddit.com/ 2>&1); rc=$?
  arm 'N1 control: before the fix, the same verb is refused for input mode' "yes input" "$(yn grep -q 'INPUT mode' <<<"$o") $(served)"
else
  echo "SKIP: N1 — base $BASE is not in this checkout"
fi
"$BROWSER" serve tiktok.com --stop >/dev/null 2>&1

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
