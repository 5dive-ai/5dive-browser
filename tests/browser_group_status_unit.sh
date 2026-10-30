#!/usr/bin/env bash
# DIVE-7346 (report 594) — a brokered seat's `status <site>` said UNKNOWN for a
# site (bing.com) whose group's browser was held in input mode for another site
# (discord.gg), while the overview said "served — ready to use" in the same
# minute. Graded through the real script with a FAKE session daemon that refuses
# every DOM op in input mode, as the real one does.
#
#   S1 brokered `status bing.com` with the group in input mode for tiktok.com
#      (the stand-in for discord.gg): not UNKNOWN; says it is not checked now,
#      names tiktok.com and the page verb that switches it
#   S2 the overview, the same minute, says the same thing (not "ready to use")
#   S3 `shot bing.com <url>` switches the browser and returns a screenshot
#   S4 the other way round: tiktok.com's status while the group is the automated
#      browser for bing.com says the same kind of line, and once a site has the
#      browser its overview line is "ready to use" again
#   N  mutant: the pre-fix tree on S1's fixture says UNKNOWN for bing.com and
#      "ready to use" in the overview (skipped where the base commit is absent)
# Run unprivileged: every seam is honoured only without root.
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
REAL_DAEMON="$ROOT/browser/bin/session-daemon"
BASE=e386423   # 5dive-browser main before DIVE-7346 (1.65.1)
TMP="$(mktemp -d /tmp/d7346.XXXXXX)"   # short: a unix socket path is capped at 108 bytes
trap 'rc=$?; pkill -f "$TMP/" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

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
cp "$ROOT/browser/adapters/tiktok.com.json" "$TMP/ad/"   # input; bing.com has no adapter (automated)
ln -s .group-main "$TMP/pr/$SEAT/tiktok.com"; ln -s .group-main "$TMP/pr/$SEAT/bing.com"

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
    if (!input) { send({ t: 'out', data: JSON.stringify({ url: 'https://www.bing.com/', title: 'Bing', nodes: [] }) + '\n' }); return end(0); }
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
brk() { FIVEDIVE_BROWSER_SEAT=agent-borrower FIVEDIVE_BROWSER_BOX_SEAT="$SEAT" FIVEDIVE_BROWSER_WAKE_PRIV="$BROWSER" "${BRK_BIN:-$BROWSER}" "$@"; }
line() { grep -E "^  $1 " <<<"$2"; }
fixture() {  # the owner served bing.com once, then the group's browser went to tiktok.com in input mode
  "$BROWSER" serve tiktok.com --stop >/dev/null 2>&1; "$BROWSER" serve bing.com --stop >/dev/null 2>&1
  "$BROWSER" serve bing.com >/dev/null 2>&1 && "$BROWSER" serve tiktok.com >/dev/null 2>&1
}

fixture
arm 'S0 (precondition) the group browser is in input mode, for tiktok.com; bing.com is offered' "input yes" "$(served) $(yn test -f "$TMP/rv/$SEAT/bing.com.offered")"
o=$(brk status bing.com 2>&1); rc=$?
s1=$(line bing.com "$o")
arm 'S1 brokered status bing.com is not UNKNOWN' "0 no" "$rc $(yn grep -q UNKNOWN <<<"$s1")"
arm 'S1 ...says it is not checked now, names tiktok.com, and the page verb that switches it' "yes yes yes" \
  "$(yn grep -q 'not checked now' <<<"$s1") $(yn grep -q 'serving tiktok.com in input mode' <<<"$s1") $(yn grep -q 'shot bing.com https://' <<<"$s1")"
arm 'S1 ...and moved nothing' input "$(served)"
[[ "$s1" == *'not checked now'* ]] || printf 'S1 output: %s\n' "$o"
o=$(brk status 2>&1)
s2=$(line bing.com "$o")
arm 'S2 the overview the same minute agrees: served, on tiktok.com in input mode, not "ready to use"' "yes yes no" \
  "$(yn grep -q 'served' <<<"$s2") $(yn grep -q 'on tiktok.com in input mode' <<<"$s2") $(yn grep -q 'ready to use' <<<"$s2")"
arm 'S2 ...and tiktok.com, which has the browser, is ready to use' yes "$(yn grep -q 'ready to use' <<<"$(line tiktok.com "$o")")"
[[ "$s2" == *'on tiktok.com'* ]] || printf 'S2 output: %s\n' "$o"
o=$(brk shot bing.com https://www.bing.com/ --out="$TMP/s3.png" 2>&1); rc=$?
arm 'S3 shot bing.com switches the browser and returns a screenshot' "0 cdp yes" "$rc $(served) $(yn test -s "$TMP/s3.png")"
[[ "$rc" == 0 ]] || printf 'S3 output: %s\n' "$o"
o=$(brk status 2>&1)
arm 'S4 once bing.com has the browser, its overview line is "ready to use"' yes "$(yn grep -q 'ready to use' <<<"$(line bing.com "$o")")"
o=$(brk status tiktok.com 2>&1); rc=$?
s4=$(line tiktok.com "$o")
arm 'S4 the input site, while the group is the automated browser for bing.com: not UNKNOWN, names bing.com' "0 no yes cdp" \
  "$rc $(yn grep -q UNKNOWN <<<"$s4") $(yn grep -q 'serving bing.com as the automated browser' <<<"$s4") $(served)"
o=$(brk status 2>&1)
arm 'S4 ...and the overview says the same for tiktok.com' yes "$(yn grep -q 'on bing.com as the automated browser' <<<"$(line tiktok.com "$o")")"

# ---- N: the pre-fix tree, on S1's fixture ------------------------------------
if git -C "$ROOT" cat-file -e "$BASE:browser/bin/browser" 2>/dev/null; then
  mkdir -p "$TMP/old"; git -C "$ROOT" archive "$BASE" browser | tar -x -C "$TMP/old"
  fixture
  o=$(BRK_BIN="$TMP/old/browser/bin/browser" brk status bing.com 2>&1)
  arm 'N1 mutant: before the fix, status bing.com says UNKNOWN' yes "$(yn grep -q UNKNOWN <<<"$(line bing.com "$o")")"
  o=$(BRK_BIN="$TMP/old/browser/bin/browser" brk status 2>&1)
  arm 'N2 mutant: ...while the overview says "ready to use" for it' yes "$(yn grep -q 'ready to use' <<<"$(line bing.com "$o")")"
else
  echo "SKIP: N1/N2 — base $BASE is not in this checkout"
fi
"$BROWSER" serve tiktok.com --stop >/dev/null 2>&1; "$BROWSER" serve bing.com --stop >/dev/null 2>&1

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
