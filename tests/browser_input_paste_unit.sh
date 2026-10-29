#!/usr/bin/env bash
# DIVE-7237 (GAP-17) — input mode's `paste` step. Typed key by key, a line of
# Shopify custom-pixel code came out with "," turned to "." and letters dropped
# (DIVE-6902, 10-29): a code editor answers each key (it closes quotes, commits
# an autocomplete on "," or ".", re-indents). A paste goes in as it is.
#
#   X  lib/x11.cjs on a bare Xvfb (tests/x11_paste.cjs): the text is offered on
#      CLIPBOARD, the browser's read of it gets it byte for byte (quotes, commas,
#      a newline, non-ASCII), and nothing holds it afterwards; with nobody reading
#      it says so (served=false) and still leaves nothing; over the cap it refuses
#   R  bin/browser with a fake input daemon: paste{path} sends the FILE's text,
#      read as the caller; a relative or unreadable path is refused before
#      anything is sent; the help names the step
#   N  control: the pre-fix daemon refuses a paste step as not an input step
# The live arm (real Chrome receives the paste through ctrl+v) is L15 in
# browser_input_drive_unit.sh, beside the typing arms it is measured against.
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
REAL_DAEMON="$ROOT/browser/bin/session-daemon"
BASE=46ef3a5   # 5dive-browser main before DIVE-7237
TMP="$(mktemp -d /tmp/d7237p.XXXXXX)"
_KILL=()
trap 'rc=$?; for p in "${_KILL[@]}"; do kill "$p" 2>/dev/null; done; chmod -R u+rwx "${TMP:-}" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
PASS=0; FAIL=0; SKIP=0
arm() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
        else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
yn() { if "$@"; then echo yes; else echo no; fi; }

# ---- X: bare Xvfb ----------------------------------------------------------
REAL_XVFB="$(command -v Xvfb || true)"
if [[ -z "$REAL_XVFB" ]]; then
  SKIP=$((SKIP+1)); echo "SKIP: X arms — this machine has no Xvfb"
else
  d=""; for n in $(seq 680 719); do [[ -e "/tmp/.X11-unix/X$n" ]] || { d=$n; break; }; done
  "$REAL_XVFB" ":$d" -screen 0 640x480x24 -nolisten tcp -noreset >/dev/null 2>&1 & _KILL+=($!)
  for i in $(seq 1 100); do [[ -e "/tmp/.X11-unix/X$d" ]] && break; sleep 0.05; done
  xp() { DISPLAY=":$d" timeout 30 node "$ROOT/tests/x11_paste.cjs" "$@" 2>&1; }
  CODE=$'fbq(\'track\', "Purchase", {value: 1.5, currency: \'USD\'});\n  // é ✓ 服'
  arm 'X1 the browser reads the pasted code byte for byte, and nothing holds it afterwards' \
    "served=true read=$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$CODE") owner-after=none" "$(xp read "$CODE")"
  arm 'X2 with nobody reading, it says so and leaves nothing on the clipboard' 'served=false owner-after=none' "$(xp noreader hello)"
  arm 'X3 over the cap it refuses by name' 'error=200001 bytes is more than one paste carries (200000); split it' "$(xp big)"
fi

# ---- R: bin/browser, fake input daemon ---------------------------------------
export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/pr" FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/ad"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/rv" FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/fake-daemon"
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli" FIVEDIVE_BROWSER_TMP_ROOT="$TMP/tmproot"
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
export FIVEDIVE_BROWSER_APPROVAL_POLICY="$TMP/no-policy.json" FIVEDIVE_BROWSER_WAKE_PRIV="$TMP/no-wake"
export FIVEDIVE_BROWSER_X11_DIR="$TMP/x11" FIVEDIVE_BROWSER_DRIVE_DEFAULT_FILE="$TMP/drive-default"
SEAT="$(id -un)"
mkdir -p "$TMP/pr/$SEAT/tiktok.com" "$TMP/ad" "$TMP/x11" "$TMP/rv/$SEAT"
chmod 711 "$TMP/pr"; chmod 700 "$TMP/pr/$SEAT" "$TMP/pr/$SEAT/tiktok.com"
cp "$ROOT/browser/adapters/tiktok.com.json" "$TMP/ad/"
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\n: > "%s/x11/X${1#:}"\nexec sleep 300\n' "$TMP" > "$FAKEBIN/Xvfb"
DREC="$TMP/daemon.rec"; : > "$DREC"
cat > "$TMP/fake-daemon" <<DAEMON
#!/usr/bin/env node
'use strict';
const fs = require('fs'), net = require('net');
const [, , mode, profile, ...rest] = process.argv;
if (mode === 'call') { const r = require('child_process').spawnSync('$REAL_DAEMON', ['call', profile], { stdio: 'inherit' }); process.exit(r.status === null ? 1 : r.status); }
const sock = rest.filter(a => !a.startsWith('--'))[0];
const PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC';
const srv = net.createServer((c) => {
  let buf = '';
  c.on('data', (d) => {
    buf += d; const nl = buf.indexOf('\n'); if (nl < 0) return;
    const req = JSON.parse(buf.slice(0, nl));
    fs.appendFileSync('$DREC', JSON.stringify(req) + '\n');
    const send = (o) => c.write(JSON.stringify(o) + '\n');
    const end = (rc) => { send({ t: 'end', rc }); c.end(); };
    if (req.op === 'ping') { send({ t: 'out', data: 'pong\n' }); return end(0); }
    if (req.op === 'lease') { send({ t: 'out', data: req.act === 'acquire' ? 'fedcba9876543210fedcba9876543210\n' : 'free\n' }); return end(0); }
    if (req.op === 'shutdown') { end(0); srv.close(); try { fs.unlinkSync(sock); } catch (e) {} process.exit(0); }
    if (req.op === 'title') { send({ t: 'out', data: JSON.stringify({ drive: 'input', title: 'Fake', handoff: false, viewer: false }) + '\n' }); return end(0); }
    send({ t: 'out', data: JSON.stringify({ drive: 'input', title: 'Fake', width: 1280, height: 800, png_b64: PNG, act_report: true, steps_run: (req.steps || []).length }) + '\n' });
    end(0);
  });
});
try { fs.unlinkSync(sock); } catch (e) {}
srv.listen(sock, () => process.stdout.write('ready sock=' + sock + '\n'));
process.on('SIGTERM', () => { try { fs.unlinkSync(sock); } catch (e) {} process.exit(0); });
DAEMON
chmod +x "$FAKEBIN/Xvfb" "$TMP/fake-daemon"
export PATH="$FAKEBIN:$PATH"
cd "$TMP"
"$BROWSER" serve tiktok.com >/dev/null 2>&1
_KILL+=("$(sed -n 's/^daemon_pid=//p' "$TMP/pr/$SEAT/tiktok.com/.5dive-serve")" "$(sed -n 's/^xvfb_pid=//p' "$TMP/pr/$SEAT/tiktok.com/.5dive-serve")")
printf '%s\n' "analytics.subscribe('checkout_completed', (event) => {" "  fbq('track', 'Purchase', {value: event.data.checkout.totalPrice.amount});" "});" > "$TMP/pixel.js"
o=$("$BROWSER" act tiktok.com --steps="[{\"op\":\"paste\",\"path\":\"$TMP/pixel.js\"}]" --out="$TMP/r1" 2>&1); rc=$?
sent=$(jq -r -s '[.[] | select(.op=="input")] | last | .steps[0] | "\(.op) \(has("path"))"' "$DREC")
arm 'R1 paste{path} sends one paste step, and no path for the browser'"'"'s seat to open' "0 paste false" "$rc $sent"
arm 'R1 ...carrying the file'"'"'s text exactly (read as the caller, trailing newline and all)' "$(sha256sum < "$TMP/pixel.js")" \
  "$(jq -j -s '[.[] | select(.op=="input")] | last | .steps[0].value' "$DREC" | sha256sum)"
n=$(jq -s '[.[] | select(.op=="input")] | length' "$DREC")
o=$("$BROWSER" act tiktok.com --steps='[{"op":"paste","path":"pixel.js"}]' 2>&1); rc=$?
arm 'R2 a relative path is refused (64) and nothing is sent' "64 $n" "$rc $(jq -s '[.[] | select(.op=="input")] | length' "$DREC")"
cp "$TMP/pixel.js" "$TMP/locked.js"; chmod 000 "$TMP/locked.js"
if [[ -r "$TMP/locked.js" ]]; then SKIP=$((SKIP+1)); echo "SKIP: R3 — this uid reads a 0000 file (root)"
else
  o=$("$BROWSER" act tiktok.com --steps="[{\"op\":\"paste\",\"path\":\"$TMP/locked.js\"}]" 2>&1); rc=$?
  arm 'R3 a file this seat cannot read is refused (64) and nothing is sent' "64 $n" "$rc $(jq -s '[.[] | select(.op=="input")] | length' "$DREC")"
fi
arm 'R4 the help names paste and says what it is for' 'yes yes' \
  "$(yn grep -q 'paste{value|path}' <<<"$("$BROWSER" act tiktok.com --help 2>&1)") $(yn grep -q 'a code editor changes text typed key by key' <<<"$("$BROWSER" act tiktok.com --help 2>&1)")"
"$BROWSER" serve tiktok.com --stop >/dev/null 2>&1

# ---- N: the pre-fix daemon's step table ---------------------------------------
if git -C "$ROOT" cat-file -e "$BASE:browser/bin/session-daemon" 2>/dev/null; then
  arm 'N1 control: before the fix the daemon had no paste step' 'no yes' \
    "$(yn grep -q "paste:" <(git -C "$ROOT" show "$BASE:browser/bin/session-daemon")) $(yn grep -q "  paste:  (s) =>" "$REAL_DAEMON")"
else
  SKIP=$((SKIP+1)); echo "SKIP: N1 — base $BASE is not in this checkout"
fi

printf '\n%d pass, %d fail, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
