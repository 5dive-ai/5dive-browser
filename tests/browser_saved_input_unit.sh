#!/usr/bin/env bash
# DIVE-7314 — chill-gorge's DigitalOcean, 10-30: on a site in input mode an agent
# could not type a login the owner saved, and the owner's take-over of a signed-in
# automated browser opened logged out.
#
#   A  bin/browser with a fake input daemon; root's half through its unprivileged
#      seam and a stub CLI (as browser_saved_fill_unit.sh's V arms)
#      A1 a type step naming a saved password reaches the daemon as a type step
#         carrying the value, and no `saved` field; rc 0
#      A2 a paste step naming one reaches it as a paste of the value
#      A3 the value is in none of stdout, stderr, the act's files, the audit log,
#         any jq argv, the rail's argv or the CLI's argv; the audit names the ref
#      A4 a saved value bound to another site is refused before the Vault is read
#      A5 a saved click, a saved step with a value or a path of its own, and a bad
#         name are each refused, and nothing reaches the browser
#      A6 NEGATIVE CONTROL: a seat with no sudo for the Vault read is refused by
#         name, tells the agent what to ask the owner, and sends nothing
#      A7 MUTANT: the pre-fix tree sends the step as written (no value), which the
#         real daemon refuses as "missing or out-of-range fields"
#   P  Chrome's own "Save password?" is off in every served profile
#      P1 a fresh profile is served with credentials_enable_service=false
#      P2 an existing Preferences keeps its other keys and gains the two
#      P3 a Preferences that does not parse is left byte for byte
#      P4 the clipboard half: a paste leaves nothing on CLIPBOARD (X1 of
#         browser_input_paste_unit.sh, the same be.x.paste a saved paste goes through)
#   C  a view's re-serve keeps a login that lasts only while the browser runs
#      C1 `serve --login` over a warm serve (what `viewer` runs) asks the automated
#         browser to keep its session logins before it goes, and gives a session
#         cookie already on disk an expiry ~SESSION_KEEP_S out
#      C2 NEGATIVE CONTROL: a cookie that already had an expiry is unchanged
#      C3 a real stop (Done, the reaper) asks for no keep and still ends a session cookie
#      C4 MUTANT: the pre-fix tree's same swap asks for no keep and leaves the
#         session cookie to die
#      C5 LIVE, when this machine has Chrome, Xvfb and playwright-core (CI): the
#         real daemon on real Chrome, a page sets a session and a lasting cookie;
#         C5a a plain shutdown, then Chrome again: the session cookie is gone;
#         C5b the swap's shutdown (keep_session), then Chrome again: both are there
#      C6 lib/session-keep.cjs on a stub context: only cookies with no expiry are
#         set back, with one ~KEEP_S out; host-only stays host-only (by URL); one
#         Chrome refuses does not stop the rest
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
REAL_DAEMON="$ROOT/browser/bin/session-daemon"
BASE=9e6f975   # 5dive-browser main before DIVE-7314
REAL_CHROME="$(command -v google-chrome || command -v chromium || command -v chromium-browser || true)"
[[ -n "${INPUT_DRIVE_SKIP_LIVE:-}" ]] && REAL_CHROME=""
TMP="$(mktemp -d /tmp/d7314.XXXXXX)"
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
run() { local o="$TMP/.o" e="$TMP/.e"; "$@" >"$o" 2>"$e"; RC=$?; OUT=$(cat "$o"); ERR=$(cat "$e"); return 0; }
leaks() {  # leaks <value> <text|dir>... — how many places hold the value, raw or JSON-escaped
  local v="$1" n=0 f x; shift
  local -a forms=("$v" "$(jq -Rr '@json' <<<"$v" | sed 's/^"//; s/"$//')")
  for x in "$@"; do
    if [[ -d "$x" ]]; then
      while IFS= read -r -d '' f; do for v in "${forms[@]}"; do grep -qF -- "$v" "$f" && n=$((n+1)); done; done < <(find "$x" -type f -print0)
    else
      for v in "${forms[@]}"; do [[ "$x" == *"$v"* ]] && n=$((n+1)); done
    fi
  done
  echo "$n"
}

export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/pr" FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/ad"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/rv" FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/fake-daemon"
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli" FIVEDIVE_BROWSER_TMP_ROOT="$TMP/tmproot"
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
export FIVEDIVE_BROWSER_APPROVAL_POLICY="$TMP/no-policy.json" FIVEDIVE_BROWSER_WAKE_PRIV="$TMP/no-wake"
export FIVEDIVE_BROWSER_X11_DIR="$TMP/x11" FIVEDIVE_BROWSER_DRIVE_DEFAULT_FILE="$TMP/drive-default"
SEAT="$(id -un)"
TT="$TMP/pr/$SEAT/tiktok.com" DO="$TMP/pr/$SEAT/digitalocean.com"
mkdir -p "$TT" "$DO" "$TMP/ad" "$TMP/x11" "$TMP/rv/$SEAT"
chmod 711 "$TMP/pr"; chmod 700 "$TMP/pr/$SEAT" "$TT" "$DO"
cp "$ROOT/browser/adapters/tiktok.com.json" "$TMP/ad/"
printf '%s\n' '{"site":"digitalocean.com","drive":"cdp","probe":{"url":"https://cloud.digitalocean.com/","logged_out_when_dom_matches":"id=\"login-form\""},"actions":{}}' > "$TMP/ad/digitalocean.com.json"
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\n: > "%s/x11/X${1#:}"\nexec sleep 300\n' "$TMP" > "$FAKEBIN/Xvfb"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == --version ]] && { echo "Google Chrome 153"; exit 0; }\nexec sleep 300\n' > "$FAKEBIN/google-chrome"
# Every jq the act runs logs its command line first (A3).
REALJQ="$(command -v jq)"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$TMP/jq-argv.log" "$REALJQ" > "$FAKEBIN/jq"
DREC="$TMP/daemon.rec"; : > "$DREC"
cat > "$TMP/fake-daemon" <<DAEMON
#!/usr/bin/env node
'use strict';
const fs = require('fs'), net = require('net');
const [, , mode, profile, ...rest] = process.argv;
if (mode === 'call') { const r = require('child_process').spawnSync('$REAL_DAEMON', ['call', profile], { stdio: 'inherit' }); process.exit(r.status === null ? 1 : r.status); }
const sock = rest.filter(a => !a.startsWith('--'))[0];
const drive = rest.includes('--input') ? 'input' : 'cdp';
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
    if (req.op === 'title') { send({ t: 'out', data: JSON.stringify({ drive, title: 'Fake', handoff: false, viewer: false }) + '\n' }); return end(0); }
    send({ t: 'out', data: JSON.stringify({ drive, title: 'Fake', width: 1280, height: 800, png_b64: PNG, act_report: true, steps_run: (req.steps || []).length }) + '\n' });
    end(0);
  });
});
try { fs.unlinkSync(sock); } catch (e) {}
srv.listen(sock, () => process.stdout.write('ready sock=' + sock + '\n'));
process.on('SIGTERM', () => { try { fs.unlinkSync(sock); } catch (e) {} process.exit(0); });
DAEMON
chmod +x "$FAKEBIN/Xvfb" "$FAKEBIN/google-chrome" "$FAKEBIN/jq" "$TMP/fake-daemon"
export PATH="$FAKEBIN:$PATH"
cd "$TMP"
pids() { _KILL+=("$(sed -n 's/^daemon_pid=//p' "$1/.5dive-serve" 2>/dev/null)" "$(sed -n 's/^xvfb_pid=//p' "$1/.5dive-serve" 2>/dev/null)" "$(sed -n 's/^chrome_pid=//p' "$1/.5dive-serve" 2>/dev/null)"); }
inputs() { jq -s '[.[] | select(.op=="input")] | length' "$DREC"; }
last_input() { jq -c -s '[.[] | select(.op=="input")] | last | .steps' "$DREC"; }

# ================================================================ A  saved, input mode
"$BROWSER" serve tiktok.com >/dev/null 2>&1; pids "$TT"
VCON="$TMP/vcon"; mkdir -p "$VCON"; chmod 700 "$VCON"
VPASS='Do-<&"pass> 9 ✓'
VLOGIN='sam@example.com'
jq -nc --arg l "$VLOGIN" --arg p "$VPASS" '{"tiktok.login":$l, "tiktok.password":$p, "other.password":$p}' > "$TMP/vault.json"
cat > "$TMP/fake-5dive" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE5_LOG"
[[ "${1:-}" == secret && "${2:-}" == _reveal ]] || { echo "error: unknown command" >&2; exit 2; }
shift 2; refs=()
for a in "$@"; do case "$a" in --agent=*|--host=*) ;; *) refs+=("$a") ;; esac; done
miss=""; for r in "${refs[@]}"; do jq -e --arg r "$r" 'has($r)' "$FAKE5_VAULT" >/dev/null || miss+="${miss:+, }$r"; done
[[ -z "$miss" ]] || { echo "error: nothing is saved as $miss" >&2; exit 4; }
printf '%s\n' "${refs[@]}" | jq -R . | jq -sc --slurpfile v "$FAKE5_VAULT" 'map({(.): $v[0][.]}) | add'
SH
cat > "$TMP/seam-rail" <<RAIL
#!/usr/bin/env bash
# What sudo does, minus root: root's half through its unprivileged test seam. Once.
[[ -z "\${SEAM_RAIL_ONCE:-}" ]] || { echo "the rail was re-entered: root's half did not run" >&2; exit 70; }
printf '%s\n' "\$*" > "$TMP/seam-rail-args"
SEAM_RAIL_ONCE=1 FIVEDIVE_BROWSER_SAVED_ROOT_SEAM=1 exec "$BROWSER" "\$@"
RAIL
chmod +x "$TMP/fake-5dive" "$TMP/seam-rail"
export FAKE5_LOG="$TMP/fake5.log" FAKE5_VAULT="$TMP/vault.json"
URL="https://www.tiktok.com/login"
iact() {  # iact <steps> <out> [browser]
  : > "$FAKE5_LOG"; : > "$TMP/jq-argv.log"; : > "$TMP/seam-rail-args"
  run env FIVEDIVE_BROWSER_SAVED_SUDO="$TMP/seam-rail" FIVEDIVE_BROWSER_SAVED_CLI="$TMP/fake-5dive" \
    FIVEDIVE_BROWSER_CONNECTORS_DIR="$VCON" "${3:-$BROWSER}" act tiktok.com "$URL" --steps="$1" --out="$2"
}

iact '[{"op":"click","x":640,"y":300},{"op":"type","saved":"tiktok.login"},{"op":"click","x":640,"y":360},{"op":"type","saved":"tiktok.password"},{"op":"press","key":"Return"}]' "$TMP/a1"
arm 'A1a an input act typing a saved login and password exits 0' 0 "$RC"
[[ "$RC" == 0 ]] || gha 'A1 act output' "$OUT $ERR"
arm 'A1b the daemon got goto + the steps, the two type steps carrying the values' \
  "$("$REALJQ" -nc --arg l "$VLOGIN" --arg p "$VPASS" '["goto","click","type:"+$l,"click","type:"+$p,"press"]')" \
  "$(last_input | jq -c 'map(.op + (if .op == "type" then ":" + .value else "" end))')"
arm 'A1c ...and no step still names a saved field' 0 "$(last_input | jq '[.[] | select(has("saved"))] | length')"
arm 'A1d root asked _reveal for the refs, for the act'"'"'s start host' yes \
  "$(has "secret _reveal --agent=$SEAT --host=www.tiktok.com tiktok.login tiktok.password" "$(cat "$FAKE5_LOG")")"
arm 'A3a the password is in none of stdout, stderr, the act'"'"'s files, the audit log, jq argv, rail argv, CLI argv' 0 \
  "$(leaks "$VPASS" "$OUT" "$ERR" "$TMP/a1" "$(cat "$TT/.5dive-audit.jsonl" 2>/dev/null)" "$(cat "$TMP/jq-argv.log")" "$(cat "$TMP/seam-rail-args")" "$(cat "$FAKE5_LOG")")"
arm 'A3b ...and the jq shim was live (it logged the act'"'"'s calls)' yes "$(yn test -s "$TMP/jq-argv.log")"
arm 'A3c the audit log names the refs it typed' '["tiktok.login","tiktok.password"]' \
  "$(jq -c -s '[.[] | select(.event == "input-saved")] | last | .detail | fromjson' "$TT/.5dive-audit.jsonl" 2>/dev/null)"
arm 'A3d the first use bound the item to the site' 'TIKTOK=tiktok.com' "$(cat "$VCON/saved.hosts" 2>/dev/null)"

iact '[{"op":"click","x":640,"y":360},{"op":"paste","saved":"tiktok.password"}]' "$TMP/a2"
arm 'A2 a saved paste reaches the daemon as a paste of the value' "0 paste:$VPASS" \
  "$RC $(last_input | jq -r '[.[] | select(.op == "paste") | "paste:" + .value] | first')"
arm 'A2b ...and leaks nowhere' 0 "$(leaks "$VPASS" "$OUT" "$ERR" "$TMP/a2" "$(cat "$TMP/jq-argv.log")")"

n=$(inputs)
printf 'OTHER=other.test\n' >> "$VCON/saved.hosts"
iact '[{"op":"type","saved":"other.password"}]' "$TMP/a4"
arm 'A4 an item bound to another site is refused by its site'"'"'s name before the Vault is read, nothing sent' "yes yes $n no" \
  "$([[ "$RC" != 0 ]] && echo yes || echo no) $(has 'typed only on other.test' "$ERR") $(inputs) $(yn grep -q _reveal "$FAKE5_LOG")"

refused() {  # refused <steps> -> "<rc != 0> <inputs unchanged>"
  local before; before=$(inputs); iact "$1" "$TMP/a5"
  printf '%s %s' "$([[ "$RC" != 0 ]] && echo refused || echo ran)" "$([[ "$(inputs)" == "$before" ]] && echo unsent || echo sent)"
}
arm 'A5a a saved click is refused, nothing sent' 'refused unsent' "$(refused '[{"op":"click","x":1,"y":1,"saved":"tiktok.password"}]')"
arm 'A5b a saved step with a value of its own is refused' 'refused unsent' "$(refused '[{"op":"type","value":"x","saved":"tiktok.password"}]')"
arm 'A5c a saved paste with a path of its own is refused' 'refused unsent' "$(refused "[{\"op\":\"paste\",\"path\":\"$TMP/vault.json\",\"saved\":\"tiktok.password\"}]")"
arm 'A5d a bad name is refused' 'refused unsent' "$(refused '[{"op":"type","saved":"../etc"}]')"
iact '[{"op":"type","saved":"../etc"}]' "$TMP/a5"
arm 'A5e ...the refusal says how to write it' yes "$(has 'a saved login goes in a type or paste step' "$ERR")"

# A6: the real rail on a seat sudo refuses: the probe says no, nothing runs.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 1\n' "$TMP/sudo-log" > "$FAKEBIN/sudo"; chmod +x "$FAKEBIN/sudo"
n=$(inputs); : > "$FAKE5_LOG"
run "$BROWSER" act tiktok.com "$URL" --steps='[{"op":"type","saved":"tiktok.password"}]' --out="$TMP/a6"
arm 'A6a NEGATIVE CONTROL: no sudo for the Vault read: refused by name, says what to ask the owner' 'yes yes' \
  "$([[ "$RC" != 0 ]] && echo yes || echo no) $(has 'Ask the owner to make it an admin agent' "$ERR")"
arm 'A6b ...nothing reached the browser and the Vault was not read' "$n no" "$(inputs) $(yn test -s "$FAKE5_LOG")"
arm 'A6c ...and it only asked sudo -l' '-n -l /usr/local/bin/5dive browser act' "$(head -1 "$TMP/sudo-log" 2>/dev/null)"
rm -f "$FAKEBIN/sudo"

# A7: the mutant — the pre-fix tree, same act.
BASEDIR="$TMP/base"
if git -C "$ROOT" cat-file -e "$BASE:browser/bin/browser" 2>/dev/null; then
  mkdir -p "$BASEDIR"; git -C "$ROOT" archive "$BASE" browser | tar -x -C "$BASEDIR"
  iact '[{"op":"type","saved":"tiktok.password"}]' "$TMP/a7" "$BASEDIR/browser/bin/browser"
  arm 'A7a MUTANT: before the fix the step reached the daemon as written, with no value' 'saved no' \
    "$(last_input | jq -r '.[1] | (keys - ["op"] | first), (has("value") | if . then "yes" else "no" end)' | tr '\n' ' ' | sed 's/ $//')"
  arm 'A7b ...which the real daemon refuses (the chill-gorge error: a type step needs a string value)' yes \
    "$(yn grep -qF "type:   (s) => typeof s.value === 'string'" "$REAL_DAEMON")"
else
  SKIP=$((SKIP+2)); echo "SKIP: A7 — base $BASE is not in this checkout"
fi
"$BROWSER" serve tiktok.com --stop >/dev/null 2>&1

# ================================================================ P  no "Save password?"
pref() { jq -c '[.credentials_enable_service, .profile.password_manager_enabled]' "$1/Default/Preferences" 2>/dev/null; }
arm 'P1 a fresh profile is served with Chrome'"'"'s password offer off' '[false,false]' "$(pref "$TT")"
mkdir -p "$DO/Default"; printf '%s\n' '{"foo":{"bar":1},"profile":{"name":"Person 1"}}' > "$DO/Default/Preferences"
"$BROWSER" serve digitalocean.com >/dev/null 2>&1; pids "$DO"
arm 'P2 an existing Preferences gains the two and keeps its other keys' '[false,false] 1 "Person 1"' \
  "$(pref "$DO") $(jq -c '.foo.bar' "$DO/Default/Preferences") $(jq -c '.profile.name' "$DO/Default/Preferences")"
"$BROWSER" serve digitalocean.com --stop >/dev/null 2>&1
BAD="$TMP/pr/$SEAT/bad.test"; mkdir -p "$BAD/Default"; chmod 700 "$BAD"
printf '{"half": ' > "$BAD/Default/Preferences"; h0=$(sha256sum < "$BAD/Default/Preferences")
printf '%s\n' '{"site":"bad.test","drive":"cdp","probe":{"url":"https://bad.test/","logged_out_when_dom_matches":"login"},"actions":{}}' > "$TMP/ad/bad.test.json"
"$BROWSER" serve bad.test >/dev/null 2>&1; pids "$BAD"
arm 'P3 a Preferences that does not parse is left byte for byte' "$h0" "$(sha256sum < "$BAD/Default/Preferences")"
"$BROWSER" serve bad.test --stop >/dev/null 2>&1
# The paste a saved value goes through is be.x.paste, whose window (and with it
# the CLIPBOARD selection) is destroyed once Chrome has read it: X1 there runs it.
arm 'P4 the clipboard half is graded by X1 of browser_input_paste_unit.sh (owner-after=none)' 'yes yes' \
  "$(yn grep -q "nothing holds it afterwards" "$ROOT/tests/browser_input_paste_unit.sh") $(yn grep -q "case 'paste': {" "$REAL_DAEMON")"

# ================================================================ C  session cookies on a swap
mkcookies() {  # mkcookies <db> — one session cookie, one with an expiry
  python3 - "$1" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE IF NOT EXISTS cookies (creation_utc INTEGER, host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, path TEXT, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, last_access_utc INTEGER, has_expires INTEGER, is_persistent INTEGER, priority INTEGER, samesite INTEGER)")
c.execute("DELETE FROM cookies")
c.execute("INSERT INTO cookies VALUES (1, '.digitalocean.com', '_digitalocean2_session_v4', '', x'763130aa', '/', 0, 1, 1, 1, 0, 0, 1, 0)")
c.execute("INSERT INTO cookies VALUES (2, '.digitalocean.com', '__cf_bm', '', x'763130bb', '/', 13400000000000000, 1, 1, 1, 1, 1, 1, 0)")
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
# Chrome's clock: microseconds from 1601. "near" = within 5 minutes of now + 12 h.
near() { python3 -c 'import sys,time; e=int(sys.argv[1]); w=(time.time()+43200+11644473600)*1e6; print("yes" if abs(e-w) < 300e6 else "no")' "$1"; }
if ! command -v python3 >/dev/null 2>&1; then
  SKIP=$((SKIP+5)); echo "SKIP: C — no python3 here"
else
  swap() {  # swap <browser> — warm serve, cookies on disk, then the view's re-serve
    "$1" serve digitalocean.com >/dev/null 2>&1; pids "$DO"
    mkdir -p "$DO/Default/Network"; mkcookies "$DO/Default/Network/Cookies"
    "$1" serve digitalocean.com --login >"$TMP/swap.out" 2>&1; SWAPRC=$?; pids "$DO"
  }
  swap "$BROWSER"
  read -r p e x <<<"$(ck "$DO/Default/Network/Cookies" _digitalocean2_session_v4)"
  arm 'C1a the view'"'"'s re-serve ran (warm -> plain)' '0 yes' "$SWAPRC $(yn grep -q 'login=1' "$DO/.5dive-serve")"
  [[ "$SWAPRC" == 0 ]] || gha 'C1 swap output' "$(cat "$TMP/swap.out")"
  arm 'C1b the session cookie is kept: persistent, with an expiry ~12 h out' '1 1 yes' "$p $e $(near "$x")"
  arm 'C1c ...and the automated browser was asked to keep its session logins before it went' 'true' \
    "$(jq -s -c '[.[] | select(.op=="shutdown")] | last | .keep_session' "$DREC")"
  arm 'C2 NEGATIVE CONTROL: the cookie that had an expiry is unchanged' '1 1 13400000000000000' "$(ck "$DO/Default/Network/Cookies" __cf_bm)"
  python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("UPDATE cookies SET is_persistent=0, has_expires=0, expires_utc=0 WHERE name=\"_digitalocean2_session_v4\""); c.commit()' "$DO/Default/Network/Cookies"
  "$BROWSER" serve digitalocean.com --stop >/dev/null 2>&1
  arm 'C3 a real stop still ends a session cookie (left with no expiry for Chrome to drop)' '0 0 0' "$(ck "$DO/Default/Network/Cookies" _digitalocean2_session_v4)"
  "$BROWSER" serve digitalocean.com >/dev/null 2>&1; pids "$DO"; "$BROWSER" serve digitalocean.com --stop >/dev/null 2>&1
  arm 'C3b a real stop of the automated browser asks it for no keep' 'null' \
    "$(jq -s -c '[.[] | select(.op=="shutdown")] | last | .keep_session' "$DREC")"
  if [[ -x "$BASEDIR/browser/bin/browser" ]]; then
    swap "$BASEDIR/browser/bin/browser"
    arm 'C4 MUTANT: the pre-fix swap leaves the session cookie with no expiry (Chrome drops it at start)' '0 0 0' \
      "$(ck "$DO/Default/Network/Cookies" _digitalocean2_session_v4)"
    arm 'C4b MUTANT: ...and asks the automated browser for no keep' 'null' \
      "$(jq -s -c '[.[] | select(.op=="shutdown")] | last | .keep_session' "$DREC")"
    "$BASEDIR/browser/bin/browser" serve digitalocean.com --stop >/dev/null 2>&1
  else
    SKIP=$((SKIP+1)); echo "SKIP: C4 — base $BASE is not in this checkout"
  fi

  # C5 LIVE: the real daemon on real Chrome, then Chrome again on the profile.
  REAL_XVFB="$(PATH="${PATH#"$FAKEBIN:"}" command -v Xvfb || true)"
  PWDIR=""; for d in ${NODE_PATH:+${NODE_PATH//:/ }} "$ROOT/browser/node_modules"; do [[ -d "$d/playwright-core" ]] && { PWDIR="$d"; break; }; done
  if [[ -z "$REAL_CHROME" || -z "$REAL_XVFB" || -z "$PWDIR" ]]; then
    SKIP=$((SKIP+1)); echo "SKIP: C5 — needs Chrome (${REAL_CHROME:-none}), Xvfb (${REAL_XVFB:-none}) and playwright-core (${PWDIR:-none}); CI has all three"
  else
    disp=""; for n in $(seq 840 890); do [[ -e "/tmp/.X11-unix/X$n" ]] || { disp=$n; break; }; done
    "$REAL_XVFB" ":$disp" -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 & _KILL+=("$!")
    for i in $(seq 1 100); do [[ -e "/tmp/.X11-unix/X$disp" ]] && break; sleep 0.05; done
    PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
    cat > "$TMP/srv.py" <<'PY'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type", "text/html")
        if self.path == "/set":
            self.send_header("Set-Cookie", "sess=on; Path=/")
            self.send_header("Set-Cookie", "kept=on; Path=/; Max-Age=86400")
        self.end_headers()
        self.wfile.write(("<html><body>cookie=[" + (self.headers.get("Cookie") or "") + "]</body></html>").encode())
        if self.path == "/set": open(sys.argv[2], "a").write("set\n")
        if self.path == "/show": open(sys.argv[3], "a").write("cookie=[" + (self.headers.get("Cookie") or "") + "]\n")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
    python3 "$TMP/srv.py" "$PORT" "$TMP/served" "$TMP/shown" & _KILL+=($!)
    for i in $(seq 1 50); do python3 -c 'import socket,sys; socket.create_connection(("127.0.0.1",int(sys.argv[1])),0.2)' "$PORT" 2>/dev/null && break; sleep 0.1; done
    # live <profile> <shutdown-json> — serve it (CDP) at /set, shut it down with
    # that request, then a plain headless Chrome on the same profile reads /show.
    live() {
      local lp="$1" i; mkdir -m 700 "$lp"; : > "$TMP/served"
      DISPLAY=":$disp" FIVEDIVE_BROWSER_CHROME="$REAL_CHROME" FIVEDIVE_BROWSER_START_URL="http://127.0.0.1:$PORT/set" NODE_PATH="$PWDIR" \
        "$REAL_DAEMON" serve "$lp" "$lp/s.sock" > "$lp.ready" 2> "$lp.err" & local dp=$!; _KILL+=("$dp")
      for i in $(seq 1 600); do grep -q '^ready' "$lp.ready" 2>/dev/null && break; sleep 0.05; done
      for i in $(seq 1 300); do [[ -s "$TMP/served" ]] && break; sleep 0.05; done
      sleep 1
      NODE_PATH="$PWDIR" "$REAL_DAEMON" call "$lp/s.sock" <<<"$2" > "$lp.shut" 2>&1
      for i in $(seq 1 300); do kill -0 "$dp" 2>/dev/null || break; sleep 0.05; done
      for i in $(seq 1 100); do pgrep -f -- "--user-data-dir=$lp( |$)" >/dev/null || break; sleep 0.1; done
      rm -f "$lp"/Singleton*
      # What the stop left on disk, for the failure annotation: each row's flags
      # and its encryption prefix (763130 = v10, 763131 = v11).
      python3 -c 'import sqlite3,sys
try:
    c=sqlite3.connect("file:"+sys.argv[1]+"?mode=ro",uri=True)
    print(";".join("%s:%s:p%s:e%s:%s" % r for r in c.execute("SELECT host_key,name,is_persistent,has_expires,substr(hex(encrypted_value),1,6) FROM cookies")) or "no-rows")
except Exception as e: print("no-db:%s" % e)' "$lp/Default/Network/Cookies" > "$lp.disk" 2>&1
      # READ IT BACK THE WAY THE OWNER'S VIEW DOES (DIVE-7314 it3): plain headed
      # Chrome on the display with serve's own flags, and the server records the
      # Cookie header /show arrives with. it2 read back through headless
      # --dump-dom, which is not the path the take-over runs.
      : > "$TMP/shown"
      DISPLAY=":$disp" "$REAL_CHROME" --no-sandbox --disable-gpu --user-data-dir="$lp" --no-first-run \
        --no-default-browser-check --window-size=1280,800 --hide-crash-restore-bubble \
        "http://127.0.0.1:$PORT/show" >/dev/null 2>"$lp.read.err" & local rp=$!; _KILL+=("$rp")
      for i in $(seq 1 600); do [[ -s "$TMP/shown" ]] && break; sleep 0.05; done
      kill -TERM "$rp" 2>/dev/null; for i in $(seq 1 100); do kill -0 "$rp" 2>/dev/null || break; sleep 0.1; done
      kill -KILL "$rp" 2>/dev/null; head -1 "$TMP/shown"
    }
    o=$(live "$TMP/live-plain" '{"op":"shutdown"}')
    arm 'C5a LIVE: a plain shutdown, then Chrome again: the session cookie is gone, the lasting one stays' 'cookie=[kept=on]' "$o"
    [[ "$o" == 'cookie=[kept=on]' ]] || gha 'C5a daemon' "served=$(wc -l < "$TMP/served") disk=$(head -c 400 "$TMP/live-plain.disk") ready=$(head -c 300 "$TMP/live-plain.ready") err=$(tail -c 600 "$TMP/live-plain.err") read-err=$(tail -c 400 "$TMP/live-plain.read.err")"
    o=$(live "$TMP/live-keep" '{"op":"shutdown","keep_session":true}')
    k=$(sed -n 's/.*kept=\([0-9]*\).*/\1/p' "$TMP/live-keep.shut" | head -1)
    arm 'C5b LIVE: the swap'"'"'s shutdown keeps the session cookie (Chrome stores it), then Chrome again: both are there' 'yes' \
      "$([[ "$k" =~ ^[1-9] && "$o" == *sess=on* && "$o" == *kept=on* ]] && echo yes || echo "no (kept=$k $o)")"
    [[ "$k" =~ ^[1-9] && "$o" == *sess=on* ]] || gha 'C5b daemon' "shut=$(head -c 300 "$TMP/live-keep.shut") disk=$(head -c 400 "$TMP/live-keep.disk") err=$(tail -c 600 "$TMP/live-keep.err") read-err=$(tail -c 400 "$TMP/live-keep.read.err")"
  fi
fi

# ================================================================ C6  lib/session-keep.cjs, stub context
o=$(node -e '
const k = require(process.argv[1]);
const now = 1700000000000, until = 1700000000 + k.KEEP_S, added = [];
const jar = [
  { name: "sess", value: "s1", domain: "cloud.example.com", path: "/", expires: -1, httpOnly: true, secure: true, sameSite: "Lax" },
  { name: "dom", value: "d1", domain: ".example.com", path: "/app", expires: -1, httpOnly: false, secure: false, sameSite: "None" },
  { name: "deep", value: "p1", domain: "cloud.example.com", path: "/a/b", expires: -1, httpOnly: false, secure: true },
  { name: "bad", value: "x", domain: "cloud.example.com", path: "/", expires: -1 },
  { name: "lasting", value: "l1", domain: "cloud.example.com", path: "/", expires: 1800000000 },
];
const ctx = { cookies: async () => jar, addCookies: async (cs) => { if (cs[0].name === "bad") throw new Error("refused"); added.push(...cs); } };
k.keepSessionCookies(ctx, k.KEEP_S, now).then((n) => {
  const by = Object.fromEntries(added.map((c) => [c.name, c]));
  console.log([n, added.length, Object.keys(by).sort().join(","),
    added.every((c) => c.expires === until),
    by.sess.url, by.sess.domain === undefined, by.sess.httpOnly, by.sess.sameSite,
    by.dom.domain, by.dom.path, by.dom.url === undefined,
    by.deep.url].join(" "));
});' "$ROOT/browser/lib/session-keep.cjs" 2>&1)
read -r n na names allexp surl nodom shttp ssame ddom dpath durl deepurl <<<"$o"
arm 'C6a only the cookies with no expiry are set back, and one Chrome refuses does not stop the rest' '3 3 deep,dom,sess' "$n $na $names"
arm 'C6b ...each with an expiry KEEP_S (12 h) out' 'true' "$allexp"
arm 'C6c a host-only cookie is set back by URL (stays host-only), its flags kept' 'https://cloud.example.com/ true true Lax' "$surl $nodom $shttp $ssame"
arm 'C6d a domain cookie is set back by domain and path' '.example.com /app true' "$ddom $dpath $durl"
arm 'C6e a host-only cookie on a deeper path keeps that path' 'https://cloud.example.com/a/b/' "$deepurl"

printf '\n%d pass, %d fail, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
