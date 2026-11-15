#!/usr/bin/env bash
# DIVE-8367 — box report 942, 2026-11-13: the owner signed in to a site in the
# sign-in window, tapped Done, and every time read "still on the sign-in page".
# Done stops the window and then checks the sign-in on a fresh Chrome, which
# drops every cookie with no expiry. A site whose login is such a cookie was
# signed out by the check itself.
#
#   K  bin/browser with a fake Chrome that records how it was started
#      K1 the sign-in window (`serve --login`) starts Chrome with
#         --restore-last-session (so Chrome writes its session-only cookies to
#         disk), after deleting any earlier session's tabs
#      K2 its stop (what Done and the dashboard's close run) gives a session
#         cookie on disk an expiry ~30 days out (SESSION_KEEP_SAVED_S)
#      K3 NEGATIVE CONTROL: a cookie that already had an expiry is unchanged
#      K4 NEGATIVE CONTROL: the automated browser's own stop (the idle sweep,
#         `serve --stop` with no person in it) still ends a session cookie
#      K5 MUTANT: the pre-fix tree (BASE) starts the window without the flag and
#         its stop leaves the session cookie with no expiry, for Chrome to drop
#      K6 the session daemon honours keep_s, bounded to 30 days
#      K7 (DIVE-8487) the window opens the site as an app window (one page, no
#         tabs, no address bar); FIVEDIVE_BROWSER_LOGIN_WINDOW=tab is the way back
#   L  LIVE, when this machine has Chrome and Xvfb (CI): a local site whose
#      sign-in page sets a cookie with no expiry and one with an expiry; the
#      sign-in window opens it, is stopped the way Done stops it, and a fresh
#      Chrome on the profile then reads the site
#      L1 the fixed tree: both cookies arrive (the login survived Done)
#      L2 MUTANT, the pre-fix tree: only the lasting cookie arrives (the red
#         arm this row was filed on)
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
REAL_DAEMON="$ROOT/browser/bin/session-daemon"
BASE=e3808ba   # 5dive-browser main before DIVE-8367 (1.83.0)
REAL_CHROME="$(command -v google-chrome || command -v chromium || command -v chromium-browser || true)"
REAL_XVFB="$(command -v Xvfb || true)"
[[ -n "${DONE_KEEP_SKIP_LIVE:-}" ]] && REAL_CHROME=""
TMP="$(mktemp -d /tmp/d8367.XXXXXX)"
_KILL=()
trap 'rc=$?; for p in "${_KILL[@]}"; do kill "$p" 2>/dev/null; done; chmod -R u+rwx "${TMP:-}" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
PASS=0; FAIL=0; SKIP=0
gha() {
  [[ "${GITHUB_ACTIONS:-}" == true ]] || return 0
  local m="$2"; m="${m//'%'/%25}"; m="${m//$'\r'/%0D}"; m="${m//$'\n'/%0A}"
  printf '::error title=%s::%s\n' "${1//[:,]/ }" "$m"
}
arm() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
        else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; gha "$1" "expected: $2 got: $3"; fi; }
yn() { if "$@"; then echo yes; else echo no; fi; }
has() { [[ "$2" == *"$1"* ]] && echo yes || echo no; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: all — no python3 here"; exit 0; }

export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/pr" FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/ad"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/rv" FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/fake-daemon"
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli" FIVEDIVE_BROWSER_TMP_ROOT="$TMP/tmproot"
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
export FIVEDIVE_BROWSER_APPROVAL_POLICY="$TMP/no-policy.json" FIVEDIVE_BROWSER_WAKE_PRIV="$TMP/no-wake"
export FIVEDIVE_BROWSER_X11_DIR="$TMP/x11" FIVEDIVE_BROWSER_DRIVE_DEFAULT_FILE="$TMP/drive-default"
export FIVEDIVE_BROWSER_COOKIE_SETTLE=1   # the fake Chrome never commits; the wait is graded elsewhere (T49)
SEAT="$(id -un)"
S=keep.example.com
D="$TMP/pr/$SEAT/$S"
mkdir -p "$D" "$TMP/ad" "$TMP/x11" "$TMP/rv/$SEAT"
chmod 711 "$TMP/pr"; chmod 700 "$TMP/pr/$SEAT" "$D"
printf '%s\n' '{"site":"keep.example.com","drive":"cdp","probe":{"url":"https://keep.example.com/","logged_out_when_dom_matches":"id=\"login-form\""},"actions":{}}' > "$TMP/ad/$S.json"
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\n: > "%s/x11/X${1#:}"\nexec sleep 300\n' "$TMP" > "$FAKEBIN/Xvfb"
# The fake Chrome logs its argv, one launch per line.
printf '#!/usr/bin/env bash\n[[ "${1:-}" == --version ]] && { echo "Google Chrome 153"; exit 0; }\nprintf "%%s\\n" "$*" >> "%s"\nexec sleep 300\n' "$TMP/chrome-argv.log" > "$FAKEBIN/google-chrome"
DREC="$TMP/daemon.rec"; : > "$DREC"
cat > "$TMP/fake-daemon" <<DAEMON
#!/usr/bin/env node
'use strict';
const fs = require('fs'), net = require('net');
const [, , mode, profile, ...rest] = process.argv;
if (mode === 'call') { const r = require('child_process').spawnSync('$REAL_DAEMON', ['call', profile], { stdio: 'inherit' }); process.exit(r.status === null ? 1 : r.status); }
const sock = rest.filter(a => !a.startsWith('--'))[0];
const srv = net.createServer((c) => {
  let buf = '';
  c.on('data', (d) => {
    buf += d; const nl = buf.indexOf('\n'); if (nl < 0) return;
    const req = JSON.parse(buf.slice(0, nl));
    fs.appendFileSync('$DREC', JSON.stringify(req) + '\n');
    const send = (o) => c.write(JSON.stringify(o) + '\n');
    const end = (rc) => { send({ t: 'end', rc }); c.end(); };
    if (req.op === 'ping') { send({ t: 'out', data: 'pong\n' }); return end(0); }
    if (req.op === 'shutdown') { end(0); srv.close(); try { fs.unlinkSync(sock); } catch (e) {} process.exit(0); }
    if (req.op === 'title') { send({ t: 'out', data: JSON.stringify({ drive: 'cdp', title: 'Fake', handoff: false, viewer: false }) + '\n' }); return end(0); }
    send({ t: 'out', data: '{}\n' }); end(0);
  });
});
try { fs.unlinkSync(sock); } catch (e) {}
srv.listen(sock, () => process.stdout.write('ready sock=' + sock + '\n'));
process.on('SIGTERM', () => { try { fs.unlinkSync(sock); } catch (e) {} process.exit(0); });
DAEMON
chmod +x "$FAKEBIN/Xvfb" "$FAKEBIN/google-chrome" "$TMP/fake-daemon"
export PATH="$FAKEBIN:$PATH"
cd "$TMP"
pids() { _KILL+=("$(sed -n 's/^daemon_pid=//p' "$1/.5dive-serve" 2>/dev/null)" "$(sed -n 's/^xvfb_pid=//p' "$1/.5dive-serve" 2>/dev/null)" "$(sed -n 's/^chrome_pid=//p' "$1/.5dive-serve" 2>/dev/null)"); }

mkcookies() {  # mkcookies <db> — one session cookie, one with an expiry
  python3 - "$1" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE IF NOT EXISTS cookies (creation_utc INTEGER, host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, path TEXT, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, last_access_utc INTEGER, has_expires INTEGER, is_persistent INTEGER, priority INTEGER, samesite INTEGER)")
c.execute("DELETE FROM cookies")
c.execute("INSERT INTO cookies VALUES (1, 'keep.example.com', 'login_session', '', x'763130aa', '/', 0, 1, 1, 1, 0, 0, 1, 0)")
c.execute("INSERT INTO cookies VALUES (2, 'keep.example.com', 'lasting', '', x'763130bb', '/', 13400000000000000, 1, 1, 1, 1, 1, 1, 0)")
c.commit()
PY
}
ck() {  # ck <db> <name> -> "is_persistent has_expires expires_utc"
  python3 - "$1" "$2" <<'PY'
import sqlite3, sys
r = sqlite3.connect(sys.argv[1]).execute("SELECT is_persistent, has_expires, expires_utc FROM cookies WHERE name = ?", (sys.argv[2],)).fetchone()
print(" ".join(map(str, r)) if r else "none")
PY
}
# Chrome's clock: microseconds from 1601. near <expires_utc> <seconds> = within 5 min of now + seconds.
near() { python3 -c 'import sys,time; e=int(sys.argv[1]); w=(time.time()+int(sys.argv[2])+11644473600)*1e6; print("yes" if abs(e-w) < 300e6 else "no")' "$1" "$2"; }

# window <browser> — the sign-in window, as Done finds it: served for a person,
# an earlier session's tabs in the profile, the person's login on disk.
window() {
  : > "$TMP/chrome-argv.log"
  mkdir -p "$D/Default/Sessions" "$D/Default/Network"; : > "$D/Default/Sessions/Session_1"; : > "$D/Default/Current Session"
  "$1" serve "$S" --login >"$TMP/serve.out" 2>&1; SRC=$?; pids "$D"
  mkcookies "$D/Default/Network/Cookies"
}

# ================================================================ K1-K3  the sign-in window and its stop
window "$BROWSER"
arm 'K1a the sign-in window serves as plain Chrome' '0 yes' "$SRC $(yn grep -q '^login=1' "$D/.5dive-serve")"
[[ "$SRC" == 0 ]] || gha 'K1 serve output' "$(cat "$TMP/serve.out")"
arm 'K1b ...started with --restore-last-session, so Chrome writes its session-only cookies to disk' 'yes' \
  "$(yn grep -q -- '--restore-last-session' "$TMP/chrome-argv.log")"
arm 'K1c ...after the earlier session'"'"'s tabs were deleted (one tab: the sign-in page)' 'no no' \
  "$(yn test -e "$D/Default/Sessions") $(yn test -e "$D/Default/Current Session")"
"$BROWSER" serve "$S" --stop >"$TMP/stop.out" 2>&1; STRC=$?
read -r p e x <<<"$(ck "$D/Default/Network/Cookies" login_session)"
arm 'K2a the stop Done runs stops the window' '0 no' "$STRC $(yn test -f "$D/.5dive-serve")"
arm 'K2b ...and keeps the session-only login: persistent, with an expiry ~30 days out' '1 1 yes' "$p $e $(near "${x:-0}" 2592000)"
arm 'K3 NEGATIVE CONTROL: the cookie that had an expiry is unchanged' '1 1 13400000000000000' "$(ck "$D/Default/Network/Cookies" lasting)"

# ================================================================ K7  the window is the page (DIVE-8487)
# K1's launch line: the site opens as an app window (no tabs, no address bar),
# at the top-left corner, and is not also a bare tab URL.
L1=$(head -1 "$TMP/chrome-argv.log")
arm 'K7a the sign-in window opens the site as an app window at 0,0, with no bare tab URL after it' 'yes yes --' \
  "$(has ' --app=https://keep.example.com' " $L1") $(has ' --window-position=0,0' " $L1") $(awk '{print substr($NF,1,2)}' <<<"$L1")"
FIVEDIVE_BROWSER_LOGIN_WINDOW=tab window "$BROWSER"
L2=$(head -1 "$TMP/chrome-argv.log")
arm 'K7b FIVEDIVE_BROWSER_LOGIN_WINDOW=tab gives back the tabbed window: the bare URL, no --app' 'no https' \
  "$(has ' --app=' " $L2") $(awk '{print substr($NF,1,5)}' <<<"$L2")"
"$BROWSER" serve "$S" --stop >/dev/null 2>&1

# ================================================================ K4  the automated browser's own stop
"$BROWSER" serve "$S" >/dev/null 2>&1; pids "$D"
arm 'K4a (setup) the automated browser serves (no person in it)' 'yes no' \
  "$(yn grep -q '^daemon_pid=' "$D/.5dive-serve") $(yn grep -q '^login=1' "$D/.5dive-serve")"
mkcookies "$D/Default/Network/Cookies"
"$BROWSER" serve "$S" --stop >/dev/null 2>&1
arm 'K4b NEGATIVE CONTROL: its stop (the idle sweep'"'"'s) still ends a session cookie' '0 0 0' "$(ck "$D/Default/Network/Cookies" login_session)"
arm 'K4c ...and asks the automated browser for no keep' 'null' \
  "$(jq -s -c '[.[] | select(.op=="shutdown")] | last | .keep_session' "$DREC")"

# ================================================================ K5  the pre-fix tree
BASEDIR="$TMP/base"
if git -C "$ROOT" cat-file -e "$BASE:browser/bin/browser" 2>/dev/null; then
  mkdir -p "$BASEDIR"; git -C "$ROOT" archive "$BASE" browser | tar -x -C "$BASEDIR"
  window "$BASEDIR/browser/bin/browser"
  arm 'K5a MUTANT: the pre-fix window starts Chrome without --restore-last-session' 'no' \
    "$(yn grep -q -- '--restore-last-session' "$TMP/chrome-argv.log")"
  "$BASEDIR/browser/bin/browser" serve "$S" --stop >/dev/null 2>&1
  arm 'K5b MUTANT: ...and its stop leaves the session cookie with no expiry (Chrome drops it at start)' '0 0 0' \
    "$(ck "$D/Default/Network/Cookies" login_session)"
else
  SKIP=$((SKIP+2)); echo "SKIP: K5 — base $BASE is not in this checkout"
fi

# ================================================================ K6  the daemon's keep_s
arm 'K6 the session daemon passes keep_s (at most 30 days) to the keep' 'yes yes' \
  "$(yn grep -q 'req.keep_s <= 2592000' "$REAL_DAEMON") $(yn grep -q 'keepSessionCookies(ctx, ks)' "$REAL_DAEMON")"

# ================================================================ L  LIVE
if [[ -z "$REAL_CHROME" || -z "$REAL_XVFB" ]]; then
  SKIP=$((SKIP+2)); echo "SKIP: L — needs Chrome (${REAL_CHROME:-none}) and Xvfb (${REAL_XVFB:-none}); CI has both"
else
  PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  cat > "$TMP/srv.py" <<'PY'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type", "text/html")
        if self.path == "/signin":
            self.send_header("Set-Cookie", "sess=on; Path=/")
            self.send_header("Set-Cookie", "kept=on; Path=/; Max-Age=86400")
        self.end_headers()
        self.wfile.write(("<html><body>cookie=[" + (self.headers.get("Cookie") or "") + "]</body></html>").encode())
        if self.path == "/signin": open(sys.argv[2], "a").write("set\n")
        if self.path == "/show": open(sys.argv[3], "a").write("cookie=[" + (self.headers.get("Cookie") or "") + "]\n")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
  python3 "$TMP/srv.py" "$PORT" "$TMP/served" "$TMP/shown" & _KILL+=($!)
  for i in $(seq 1 50); do python3 -c 'import socket,sys; socket.create_connection(("127.0.0.1",int(sys.argv[1])),0.2)' "$PORT" 2>/dev/null && break; sleep 0.1; done
  # The real Chrome, through a shim that adds only --no-sandbox (a CI runner's
  # kernel refuses Chrome's sandbox) and logs the argv.
  LBIN="$TMP/lbin"; mkdir -p "$LBIN"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" --no-sandbox --disable-gpu "$@"\n' "$TMP/live-argv.log" "$REAL_CHROME" > "$LBIN/google-chrome"
  ln -sf "$REAL_XVFB" "$LBIN/Xvfb"; chmod +x "$LBIN/google-chrome"
  LPATH="$LBIN:${PATH#"$FAKEBIN:"}"
  LS=127.0.0.1
  printf '{"site":"127.0.0.1","drive":"cdp","probe":{"url":"http://127.0.0.1:%s/signin","logged_out_when_dom_matches":"id=\\"login-form\\""},"actions":{}}\n' "$PORT" > "$TMP/ad/$LS.json"
  # live <browser> <tag> — the sign-in window on the real site, the person signs
  # in (the page sets both cookies), Chrome commits them, the stop Done runs, and
  # then a fresh Chrome on the profile reads /show.
  live() {
    local b="$1" lp="$TMP/pr/$SEAT/$LS" i
    rm -rf "$lp"; mkdir -m 700 "$lp"; : > "$TMP/served"; : > "$TMP/shown"
    env PATH="$LPATH" FIVEDIVE_BROWSER_X11_DIR=/tmp/.X11-unix "$b" serve "$LS" --login > "$TMP/$2.serve" 2>&1
    pids "$lp"
    for i in $(seq 1 300); do [[ -s "$TMP/served" ]] && break; sleep 0.05; done
    # Chrome commits cookie changes on a ~30 s timer; wait for that commit, so this
    # grades what reaches disk and not the timing T49 grades.
    for i in $(seq 1 450); do
      python3 -c 'import sqlite3,sys
c=sqlite3.connect("file:"+sys.argv[1]+"?mode=ro",uri=True)
sys.exit(0 if c.execute("SELECT count(*) FROM cookies WHERE name=\"kept\"").fetchone()[0] else 1)' "$lp/Default/Network/Cookies" 2>/dev/null && break
      sleep 0.1
    done
    sleep 1
    env PATH="$LPATH" FIVEDIVE_BROWSER_X11_DIR=/tmp/.X11-unix FIVEDIVE_BROWSER_COOKIE_SETTLE=2 "$b" serve "$LS" --stop > "$TMP/$2.stop" 2>&1
    for i in $(seq 1 100); do pgrep -f -- "--user-data-dir=$lp( |$)" >/dev/null || break; sleep 0.1; done
    rm -f "$lp"/Singleton*
    python3 -c 'import sqlite3,sys
try:
    c=sqlite3.connect("file:"+sys.argv[1]+"?mode=ro",uri=True)
    print(";".join("%s:%s:p%s:e%s" % r for r in c.execute("SELECT host_key,name,is_persistent,has_expires FROM cookies")) or "no-rows")
except Exception as e: print("no-db:%s" % e)' "$lp/Default/Network/Cookies" > "$TMP/$2.disk" 2>&1
    # A fresh Chrome on the profile, as the check after Done starts one: plain
    # headed Chrome with serve's flags and NO restore, on its own display.
    local ld=""; for i in $(seq 891 940); do [[ -e "/tmp/.X11-unix/X$i" ]] || { ld=$i; break; }; done
    "$REAL_XVFB" ":$ld" -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 & local xp=$!; _KILL+=("$xp")
    for i in $(seq 1 100); do [[ -e "/tmp/.X11-unix/X$ld" ]] && break; sleep 0.05; done
    DISPLAY=":$ld" "$REAL_CHROME" --no-sandbox --disable-gpu --user-data-dir="$lp" --no-first-run \
      --no-default-browser-check --window-size=1280,800 --hide-crash-restore-bubble \
      "http://127.0.0.1:$PORT/show" >/dev/null 2>"$TMP/$2.read.err" & local rp=$!; _KILL+=("$rp")
    for i in $(seq 1 600); do [[ -s "$TMP/shown" ]] && break; sleep 0.05; done
    kill -TERM "$rp" 2>/dev/null; for i in $(seq 1 100); do kill -0 "$rp" 2>/dev/null || break; sleep 0.1; done
    kill -KILL "$rp" 2>/dev/null; kill "$xp" 2>/dev/null
    head -1 "$TMP/shown"
  }
  o=$(live "$BROWSER" fixed)
  arm 'L1 LIVE: after the stop Done runs, a fresh Chrome still sends the session-only login (and the lasting one)' 'yes yes' \
    "$(has sess=on "$o") $(has kept=on "$o")"
  [[ "$o" == *sess=on* && "$o" == *kept=on* ]] || gha 'L1 detail' "shown=$o served=$(wc -l < "$TMP/served") disk=$(head -c 400 "$TMP/fixed.disk") serve=$(tail -c 300 "$TMP/fixed.serve") stop=$(tail -c 300 "$TMP/fixed.stop") argv=$(tail -c 400 "$TMP/live-argv.log") read-err=$(tail -c 300 "$TMP/fixed.read.err")"
  if [[ -x "$BASEDIR/browser/bin/browser" ]]; then
    o=$(live "$BASEDIR/browser/bin/browser" base)
    arm 'L2 LIVE MUTANT: on the pre-fix tree the session-only login is gone after Done; the lasting one is not' 'cookie=[kept=on]' "$o"
    [[ "$o" == 'cookie=[kept=on]' ]] || gha 'L2 detail' "disk=$(head -c 400 "$TMP/base.disk") serve=$(tail -c 300 "$TMP/base.serve")"
  else
    SKIP=$((SKIP+1)); echo "SKIP: L2 — base $BASE is not in this checkout"
  fi
fi

printf '\n%d pass, %d fail, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
