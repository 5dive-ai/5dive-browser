#!/usr/bin/env bash
# DIVE-7675 — Done in the viewer itself.
#
# lodar, 2026-11-04: "should we add carry on button to our browser viewer? so i
# dont need to go to chat and click it?" The viewer's Done must be the chat's
# Done, reached through the ticket's bind (never the Done code in the page):
#   V  root's half, `_connect view-done <site> <bind>`: only the box seat, only
#      the bind this link was minted under, once; revoke -> stop -> probe; the
#      agent gets the chat Done's words; the chat message is edited to the
#      verdict with no button left, and the chat's own Done is refused after it
#   N  not signed in yet: a fresh link to the same window and a fresh Done
#   C  a challenge ask: "carrying on", and the challenge note
#   S  DIVE-8354: a link NO agent asked for (the settings screen's Connect): its
#      Done checks the sign-in the same way and says "not signed in yet" with a
#      way back in, never "already finished"; only for the window a person is in
#      now (this bind's ticket, redeemed and not revoked or replaced)
#   E  END TO END on the self-hosted server: tap -> bind -> redeem -> the page's
#      Done button (viewer-ui.js wireDone, a DOM fake) -> the server -> root ->
#      the agent is told. MUTANT: the same run with the button's click handler
#      cut out of viewer-ui.js: nothing reaches the agent.
# Run unprivileged: the test seams are honoured only without root.
# The Telegram API and shelld are one loopback stub; the relay seat's browser verbs
# and the CLI's `agent send` are fakes that log what they were asked.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
TMP=$(mktemp -d)
SRV_PID=""
trap 'rc=$?; [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }
has_() { [[ "$2" == *"$1"* ]] && echo yes || echo no; }
tn() { if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected NOT to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }

command -v jq >/dev/null && command -v python3 >/dev/null && command -v curl >/dev/null \
  || { echo "SKIP: needs jq, python3 and curl"; exit 1; }

# ---- the stub: Telegram Bot API + shelld's bind endpoint, one loopback server --
cat >"$TMP/stub.py" <<'PY'
import http.server, json, os, sys, urllib.parse
LOG = sys.argv[1]; CTL = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get('content-length') or 0)
        body = self.rfile.read(n).decode()
        rec = {'path': self.path, 'auth': self.headers.get('authorization', ''), 'body': body}
        if self.path.startswith('/bot'):
            rec['form'] = {k: v[0] for k, v in urllib.parse.parse_qs(body).items()}
        with open(LOG, 'a') as f: f.write(json.dumps(rec) + '\n')
        status = 200
        if self.path == '/shell/browser-viewer-bind' and os.path.exists(CTL + '.bind500'): status = 500
        if self.path.startswith('/bot') and os.path.exists(CTL + '.tgfail'):
            out = {'ok': False}
        else:
            out = {'ok': True, 'result': {'message_id': 7}}
        b = json.dumps(out).encode()
        self.send_response(status); self.send_header('content-length', str(len(b))); self.end_headers(); self.wfile.write(b)
s = http.server.HTTPServer(('127.0.0.1', 0), H)
open(CTL + '.port', 'w').write(str(s.server_port))
s.serve_forever()
PY
python3 "$TMP/stub.py" "$TMP/stub.log" "$TMP/ctl" & SRV_PID=$!
for _ in $(seq 50); do [[ -s "$TMP/ctl.port" ]] && break; sleep 0.1; done
PORT=$(cat "$TMP/ctl.port")

# ---- the relay seat's browser verbs, faked -----------------------------------
cat >"$TMP/fake-browser" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG"
case "$1" in
  serve)
    if [[ -f "$FAKE_CTL.noprofile" && ! -f "$FAKE_CTL.authed" ]]; then
      echo "browser: no profile for $2 — 5dive browser auth $2" >&2; exit 69
    fi
    [[ -f "$FAKE_CTL.servefail" && "$*" != *--login* && "$*" != *--stop* ]] && { echo "browser: the warm session did not start" >&2; exit 69; } ;;
  auth) : >"$FAKE_CTL.authed" ;;
  viewer)
    [[ -f "$FAKE_CTL.badpath" ]] && { echo "not-a-path"; echo "one-time, expires 2099-01-01T00:00:00Z, bound to session x." >&2; exit 0; }
    printf '/browser/viewer/%s/%s\n' "$2" "$(printf 'a%.0s' $(seq 64))"
    echo "one-time, expires 2099-01-01T00:00:00Z, bound to session ${3#--bind=}. Redeeming it consumes it." >&2
    # DIVE-6111: a hand-run view says where it listens and how to read its password.
    [[ "$3" == --bind=local && ! -f "$FAKE_CTL.novline" ]] \
      && echo "local view: VNC on 127.0.0.1:5917 of this box only, one connection; its one-time password: sudo cat /var/lib/5dive/browser-profiles/agent-clicker/$2/.5dive-viewer.pw" >&2 ;;
  snapshot)
    # DIVE-6725: the look before a challenge ask, and again at its Done. The
    # default page is a Cloudflare check (a 403 that IS a check); the ctl files
    # turn it into the incident's 404, a network error, a soft 404, or a page
    # with no check on it.
    u=""; for a in "${@:2}"; do [[ "$a" =~ ^https?:// ]] && { u="$a"; break; }; done
    if [[ -f "$FAKE_CTL.snapneterr" ]]; then
      echo "browser: could not capture $u: net::ERR_NAME_NOT_RESOLVED at $u" >&2
      echo "browser: the executor could not capture $u (its own reason is above)." >&2; exit 69
    fi
    [[ -f "$FAKE_CTL.snapslow" ]] && sleep 5
    if [[ -f "$FAKE_CTL.snapstop" ]]; then
      echo "browser: futuretools.io is presenting a security challenge, so anything rendered now is the challenge page and not the page you asked for. A person clears it. Ask your owner to, then carry on after their Done: 5dive browser connect-request futuretools.io --challenge --url=<the page you asked for>" >&2; exit 75
    fi
    st=403 ti="Just a moment..."
    [[ -f "$FAKE_CTL.snap404" ]] && st=404 ti="Error 404 (Not Found)!!1"
    [[ -f "$FAKE_CTL.snapsoft404" ]] && st=200 ti="Page not found | FutureTools"
    [[ -f "$FAKE_CTL.snapclear" ]] && st=200 ti="URL inspection - Search Console"
    jq -nc --arg u "$u" --arg t "$ti" --argjson s "$st" '{url:$u, title:$t, http_status:$s, nodes:[]}' ;;
  status)
    # DIVE-5638: the real shape of a BROKEN status — the site's verdict line,
    # then a paragraph that ends in a reproducer command, rc 69.
    if [[ -f "$FAKE_CTL.broken" ]]; then
      printf '  %-20s %s\n' "$2" "BROKEN (this box cannot start a browser as claude: it exited 133 — chrome_crashpad_handler: --database is required)"
      printf '\nThis box cannot start a browser as this seat, so the session states above were\nnot read. Reproduce it directly to see the\nreason:\n  google-chrome --headless --no-sandbox --disable-gpu --user-data-dir=$(mktemp -d) --dump-dom about:blank\n' >&2
      exit 69
    fi
    echo "$2: authenticated"; ;;
esac
exit 0
SH
chmod +x "$TMP/fake-browser"

ME=$(id -un)
OWNER=111222333
mkdir -p "$TMP/home/.claude/channels/telegram" "$TMP/connectors" "$TMP/req"
printf '{"dmPolicy":"allowlist","allowFrom":["%s"],"groups":{}}\n' "$OWNER" >"$TMP/home/.claude/channels/telegram/access.json"
printf 'TELEGRAM_BOT_TOKEN=123:SECRETBOTTOKEN\n' >"$TMP/connectors/telegram-${ME#agent-}.env"
printf 'CONNECTORD_TOKEN=connectord-secret-token-0123456789\n' >"$TMP/connectord.env"
printf 'FIVE_DOMAIN=box.example.5dive.ai\n' >"$TMP/provisioning.env"

export FIVEDIVE_BROWSER_CONNECT_DIR="$TMP/req"
# DIVE-7078: where a no-Telegram ask's readable summary goes, and the login hook.
export FIVEDIVE_BROWSER_ASKS_DIR="$TMP/asks" FIVEDIVE_BROWSER_PROFILE_D="$TMP/profile.d/5dive-browser-asks.sh"
export FIVEDIVE_CONNECTOR_DIR="$TMP/connectors"
export FIVEDIVE_BROWSER_CONNECT_HOME="$TMP/home"
export FIVEDIVE_CONNECTORD_ENV="$TMP/connectord.env"
export FIVEDIVE_PROVISIONING_ENV="$TMP/provisioning.env"
export FIVEDIVE_SHELLD_URL="http://127.0.0.1:$PORT"
export FIVEDIVE_TELEGRAM_API="http://127.0.0.1:$PORT"
export FIVEDIVE_BROWSER_CONNECT_SELF="$TMP/fake-browser"
export FIVEDIVE_BROWSER_CONNECT_PRIV="$BROWSER"
export FAKE_LOG="$TMP/fake.log" FAKE_CTL="$TMP/ctl"
# The viewer server's user is the box seat; here that is this same user.
export FIVEDIVE_BROWSER_BOX_SEAT="$ME"
# DIVE-8354: root reads the box seat's viewer ticket for a link no agent asked for.
export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/profiles"
ticket() {  # <site> <bind> <state>: the box seat's viewer ticket, as `viewer` writes it
  mkdir -p "$TMP/profiles/$ME/$1"
  printf 'hash=x\nexpires_at=4070908800\nbind=%s\nstate=%s\nminted_at=1\nport=6080\n' "$2" "$3" >"$TMP/profiles/$ME/$1/.5dive-viewer.ticket"
}
cat >"$TMP/fake-5dive" <<'SH'
#!/usr/bin/env bash
{ printf 'ARGS %s\n' "$*"; cat; printf '\n'; } >>"$SENT_LOG"
SH
chmod +x "$TMP/fake-5dive"
export FIVEDIVE_BROWSER_SAVED_CLI="$TMP/fake-5dive" SENT_LOG="$TMP/sent.log" FIVEDIVE_BROWSER_CONNECT_LOOK_S=20
WHO="${ME#agent-}"

priv() { printf '%s\0' "$@" | "$BROWSER" _connect; }
# view-done's answer is its stdout, the way shelld reads it (/^result=/m on stdout only), so the
# exact-match arms take stdout alone; stderr goes to its own file (DIVE-7675 iteration 3: a stray
# "Broken pipe" on stderr failed C1 through 2>&1). V3 checks its stderr refusal on purpose.
vd() { priv view-done "$@" 2>"$TMP/vd.err"; }
reset() { : >"$TMP/stub.log"; : >"$FAKE_LOG"; : >"$SENT_LOG"; rm -f "$TMP"/ctl.{broken,snapclear}; }
last_code() { jq -r 'select(.path|test("sendMessage")) | .form.reply_markup' "$TMP/stub.log" | tail -1 | jq -r '.inline_keyboard[0][0].callback_data' | sed 's/^bconn://'; }
last_bind() { jq -r 'select(.path=="/shell/browser-viewer-bind") | .body' "$TMP/stub.log" | tail -1 | jq -r .bind; }
edits() { jq -c 'select(.path|test("editMessageText")) | .form' "$TMP/stub.log"; }
# What the telegram plugin tells the agent on a chat Done (browser-connect.ts
# connectAgentNote('verdict', site, "`5dive browser status <site>` said: <status>")).
CHAT_NOTE='[browser connect] The owner finished logging in to booking.com. `5dive browser status booking.com` said: booking.com: authenticated'

# ---- V: a login ask, finished from the viewer ---------------------------------
reset
"$BROWSER" connect-request booking.com --reason="to search hotels for you" >/dev/null 2>&1
CODE=$(last_code)
out=$(priv tap "$CODE" "$OWNER" 2>&1); rc=$?
t  "V0 the owner's tap opens the link" 0 "$rc"
DONE=$(sed -n 's/^done=//p' <<<"$out"); BIND=$(last_bind)
t  "V0 ... the bind went to the viewer server" 1 "$([[ "$BIND" =~ ^[0-9a-f]{32}$ ]] && echo 1)"
tn "V0 ... and the bind is NOT in what the tap prints (the chat sees that)" "$BIND" "$out"
tc "V1 the Done code remembers its chat message" "msgs=$OWNER:7" "$(cat "$(printf '%s/%s' "$TMP/req" "$(printf '%s' "$DONE" | sha256sum | cut -d' ' -f1)")")"
: >"$FAKE_LOG"
out=$(vd booking.com "$(printf 'b%.0s' $(seq 32))"); rc=$?
t  "V2 a bind this link was not minted under finishes nothing" "0 result=gone" "$rc $out"
t  "V2 ... and nothing was run" "" "$(cat "$FAKE_LOG")"
out=$(vd example.org "$BIND"); rc=$?
t  "V2 ... nor the right bind for another site" "0 result=gone" "$rc $out"
out=$(FIVEDIVE_BROWSER_BOX_SEAT=some-other-seat priv view-done booking.com "$BIND" 2>&1); rc=$?
t  "V3 only the box seat (the viewer server's user) may press it" 77 "$rc"
tc "V3 ... and says so" "only the box's own viewer" "$out"
t  "V3 ... the agent was not told" "" "$(cat "$SENT_LOG")"
out=$(vd booking.com "$BIND"); rc=$?
t  "V4 the viewer's Done, with the link's bind: signed in" "0 result=saved" "$rc $out"
t  "V4 ... the chat Done's path: revoke -> stop -> probe" "viewer-revoke booking.com|serve booking.com --stop|status booking.com" "$(paste -sd'|' "$FAKE_LOG")"
t  "V4 ... the agent gets the chat Done's message, word for word" "ARGS agent send $WHO --message-file=-|$CHAT_NOTE" "$(paste -sd'|' "$SENT_LOG")"
E=$(edits)
t  "V5 the chat message is edited to the chat Done's verdict" "✅ booking.com is connected. The agent can use it now." "$(jq -r .text <<<"$E")"
t  "V5 ... the same message the ask went to" "$OWNER 7" "$(jq -r '.chat_id + " " + .message_id' <<<"$E")"
t  "V5 ... with no button left on it" "null" "$(jq -r '.reply_markup' <<<"$E")"
out=$(priv done "$DONE" "$OWNER" 2>&1); rc=$?
t  "V6 the chat's Done no longer acts" 77 "$rc"
tc "V6 ... it is spent" "not live" "$out"
: >"$SENT_LOG"
out=$(vd booking.com "$BIND"); rc=$?
t  "V7 a second press finishes nothing" "0 result=gone" "$rc $out"
t  "V7 ... and the agent is not told twice" "" "$(cat "$SENT_LOG")"

# ---- V8: the chat Done first, then the viewer's ------------------------------
reset
"$BROWSER" connect-request booking.com --reason="r" >/dev/null 2>&1
out=$(priv tap "$(last_code)" "$OWNER" 2>&1); DONE=$(sed -n 's/^done=//p' <<<"$out"); BIND=$(last_bind)
out=$(priv done "$DONE" "$OWNER" 2>&1); rc=$?
t  "V8 the chat Done still works as before" 0 "$rc"
: >"$FAKE_LOG"
out=$(vd booking.com "$BIND"); rc=$?
t  "V8 ... and the viewer's Done after it finishes nothing" "0 result=gone" "$rc $out"
t  "V8 ... runs nothing" "" "$(cat "$FAKE_LOG")"

# ---- N: not signed in yet -----------------------------------------------------
reset
"$BROWSER" connect-request booking.com --reason="r" >/dev/null 2>&1
out=$(priv tap "$(last_code)" "$OWNER" 2>&1); DONE=$(sed -n 's/^done=//p' <<<"$out"); BIND=$(last_bind)
: >"$TMP/ctl.broken"; : >"$TMP/stub.log"
out=$(vd booking.com "$BIND"); rc=$?
tc "N1 a login that did not take: not signed in yet" "result=notyet" "$out"
AGAIN=$(sed -n 's/^again=//p' <<<"$out")
t  "N1 ... with a way back in: a fresh link to the box" 1 "$([[ "$AGAIN" =~ ^https://box\.example\.5dive\.ai/browser/viewer/booking\.com/[0-9a-f]{64}$ ]] && echo 1)"
BIND2=$(last_bind)
t  "N1 ... under a fresh bind" 1 "$([[ "$BIND2" =~ ^[0-9a-f]{32}$ && "$BIND2" != "$BIND" ]] && echo 1)"
E=$(edits)
tc "N2 the chat says it is not confirmed" "is not confirmed logged in" "$(jq -r .text <<<"$E")"
NEW=$(jq -r '.reply_markup' <<<"$E" | jq -r '.inline_keyboard[0][0].callback_data' | sed 's/^bdone://')
t  "N2 ... and carries a fresh Done" 1 "$([[ "$NEW" =~ ^[0-9a-f]{48}$ && "$NEW" != "$DONE" ]] && echo 1)"
tc "N3 the agent is told, and told to wait" "wait for their next Done" "$(cat "$SENT_LOG")"
rm -f "$TMP/ctl.broken"; : >"$SENT_LOG"
out=$(vd booking.com "$BIND2")
t  "N4 the viewer's Done on the new link finishes it" "result=saved" "$out"
out=$(priv done "$NEW" "$OWNER" 2>&1); rc=$?
t  "N4 ... and then the chat's fresh Done is spent too (one Done)" 77 "$rc"

# ---- C: a challenge ask -------------------------------------------------------
reset
: >"$TMP/ctl.snapclear"
"$BROWSER" connect-request futuretools.io --challenge --url=https://futuretools.io/tools >/dev/null 2>&1
out=$(priv tap "$(last_code)" "$OWNER" 2>&1); BIND=$(last_bind); : >"$SENT_LOG"
out=$(vd futuretools.io "$BIND")
t  "C1 a challenge Done from the viewer: carrying on" "result=carryon" "$out"
tc "C1 ... the agent gets the chat Done's challenge note" "[browser challenge] The owner tapped Done for futuretools.io. The box browser for futuretools.io is back in your hands. What it shows now:" "$(cat "$SENT_LOG")"
t  "C1 ... and the chat says so" "✅ Thanks. The agent is carrying on with futuretools.io." "$(edits | jq -r .text)"

# ---- S: a link no agent asked for (DIVE-8354) ----------------------------------
# The settings screen's Connect: serve, `viewer --bind=<its own>`, a person redeems it.
# No connect-request, no tap, no Done code: nothing is indexed under the bind.
SB=$(printf 'c%.0s' $(seq 32))
reset; : >"$TMP/ctl.broken"; ticket booking.com "$SB" consumed
out=$(vd booking.com "$SB"); rc=$?
tc "S1 not signed in, on a link no agent asked for: not signed in yet" "result=notyet" "$out"
tn "S1 ... NOT 'already finished'" "result=gone" "$out"
t  "S1 ... checked the way the settings screen's Done checks" "viewer-revoke booking.com|serve booking.com --stop|status booking.com" "$(grep -v '^serve booking.com --login\|^viewer booking.com' "$FAKE_LOG" | paste -sd'|')"
AGAIN=$(sed -n 's/^again=//p' <<<"$out")
t  "S2 ... with a way back into the same window: a fresh link" 1 "$([[ "$AGAIN" =~ ^https://box\.example\.5dive\.ai/browser/viewer/booking\.com/[0-9a-f]{64}$ ]] && echo 1)"
t  "S2 ... opened on the box (served for a person, then viewed)" 1 "$(grep -q '^serve booking.com --login' "$FAKE_LOG" && grep -q '^viewer booking.com --bind=' "$FAKE_LOG" && echo 1)"
t  "S3 no agent is told (there is no ask)" "" "$(cat "$SENT_LOG")"
t  "S3 ... and no chat is edited" "" "$(edits)"
reset; ticket booking.com "$SB" consumed
out=$(vd booking.com "$SB")
t  "S4 signed in, on a link no agent asked for: saved" "result=saved" "$out"
t  "S4 ... still no agent told" "" "$(cat "$SENT_LOG")"
reset; ticket booking.com "$SB" open
t  "S5 a link nobody redeemed finishes nothing" "result=gone" "$(vd booking.com "$SB")"
t  "S5 ... and runs nothing" "" "$(cat "$FAKE_LOG")"
reset; ticket booking.com "$SB" revoked
t  "S6 a view the settings screen already closed: already finished" "result=gone" "$(vd booking.com "$SB")"
t  "S6 ... runs nothing" "" "$(cat "$FAKE_LOG")"
reset; ticket booking.com "$SB" consumed
t  "S7 another bind than the ticket's finishes nothing" "result=gone" "$(vd booking.com "$(printf 'd%.0s' $(seq 32))")"
t  "S7 ... nor this bind on another site" "result=gone" "$(vd example.org "$SB")"
t  "S7 ... and nothing ran" "" "$(cat "$FAKE_LOG")"
# An ASK's link whose Done was used in chat: its ticket is revoked by that Done.
reset
"$BROWSER" connect-request booking.com --reason="r" >/dev/null 2>&1
out=$(priv tap "$(last_code)" "$OWNER" 2>&1); DONE=$(sed -n 's/^done=//p' <<<"$out"); BIND=$(last_bind)
ticket booking.com "$BIND" consumed
priv done "$DONE" "$OWNER" >/dev/null 2>&1
ticket booking.com "$BIND" revoked
: >"$FAKE_LOG"; : >"$SENT_LOG"
t  "S8 an ask that really ended still reads 'already finished'" "result=gone" "$(vd booking.com "$BIND")"
t  "S8 ... and runs nothing" "" "$(cat "$FAKE_LOG")"
rm -f "$TMP/profiles/$ME/booking.com/.5dive-viewer.ticket"

# ---- E: end to end through the self-hosted server and the page's button --------
command -v node >/dev/null || { echo "SKIP E: needs node"; printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"; exit $(( FAIL > 0 )); }
SERVER="$ROOT/browser/lib/login-link-server.py"
LHOST=192-0-2-10.sslip.io
cat >"$TMP/redeem" <<'SH'
#!/usr/bin/env bash
IFS= read -r n
printf 'target=127.0.0.1:5999\npassword=pw-123\n'
SH
chmod +x "$TMP/redeem"
mkdir -p "$TMP/s/binds" "$TMP/s/novnc"
# The server runs root's half the way it does on a box (sudo there; the seam here).
LINK_HOST=$LHOST LINK_PORT=0 LINK_PORT_FILE="$TMP/srv.port" LINK_BIND_DIR="$TMP/s/binds" LINK_NOVNC_DIR="$TMP/s/novnc" \
  LINK_REDEEM_CMD="[\"$TMP/redeem\"]" LINK_DONE_CMD="[\"$BROWSER\", \"_connect\"]" python3 -I "$SERVER" 2>"$TMP/srv.err" & LPID=$!
trap 'rc=$?; kill "$SRV_PID" "$LPID" 2>/dev/null; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
for _ in $(seq 50); do [[ -s "$TMP/srv.port" ]] && break; sleep 0.1; done
B="http://127.0.0.1:$(cat "$TMP/srv.port")"

cp browser/lib/login-link/viewer-ui.js "$TMP/viewer-ui.mjs"
# The handler cut out: the click listener is never added.
sed 's/^  btn\.addEventListener(.click., async () => {$/  void (async () => {/' browser/lib/login-link/viewer-ui.js >"$TMP/viewer-ui-mutant.mjs"
t  "E0 the mutant really differs" 1 "$(cmp -s "$TMP/viewer-ui.mjs" "$TMP/viewer-ui-mutant.mjs" || echo 1)"
cat >"$TMP/press.mjs" <<'JS'
// The page's bar, its Done button, a click, against the real server.
const [ui, base, origin, done] = process.argv.slice(2);
const { wireDone, TEXT } = await import(ui);
const listeners = {};
const btn = { textContent: '', title: '', hidden: false, disabled: true,
  addEventListener(ev, f) { listeners[ev] = f; } };
const doc = { getElementById: (id) => (id === 'done' ? btn : null) };
const shown = [];
const w = wireDone(doc, TEXT.en, async () => {
  const r = await fetch(base + done, { method: 'POST', headers: { origin, 'x-5dive-viewer': '1' } });
  return r.json();
}, (line, again) => shown.push(again ? line + ' ' + again : line));
w.connect();
if (listeners.click) await listeners.click();
console.log(JSON.stringify({ label: btn.textContent, shown, disabled: btn.disabled }));
JS
e2e() {  # <viewer-ui copy>  -> prints the page's view of the press
  reset
  "$BROWSER" connect-request booking.com --reason="r" >/dev/null 2>&1
  priv tap "$(last_code)" "$OWNER" >/dev/null 2>&1
  local b; b=$(last_bind)
  # Root's bind, where a self-hosted box's root writes it for the server.
  printf 'bind=%s\nexpires_at=%s\n' "$b" "$(( $(date +%s) + 600 ))" >"$TMP/s/binds/booking.com"
  local n; n=$(printf 'a%.0s' $(seq 64))
  local j; j=$(curl -s -X POST -H "origin: https://$LHOST" -H 'x-5dive-viewer: 1' "$B/browser/viewer/booking.com/$n/redeem")
  printf '%s\n' "$j" >"$TMP/redeem.json"
  node "$TMP/press.mjs" "$1" "$B" "https://$LHOST" "$(jq -r .done <<<"$j")"
}
out=$(e2e "$TMP/viewer-ui.mjs")
tn "E1 the redeem hands the page a Done handle, not the Done code or the bind" "$(last_bind)" "$(cat "$TMP/redeem.json")"
tc "E1 ... a one-use path on this server" '"done": "/browser/viewer/booking.com/' "$(cat "$TMP/redeem.json")"
t  "E2 a press on the page's Done: the owner reads one plain line" '{"label":"Done","shown":["Checking the sign-in…","Saved. Your agent is carrying on."],"disabled":true}' "$out"
t  "E2 ... the agent gets the chat Done's message" "ARGS agent send $WHO --message-file=-|$CHAT_NOTE" "$(paste -sd'|' "$SENT_LOG")"
t  "E2 ... the chat message lost its buttons" "null" "$(edits | jq -r .reply_markup)"
D=$(jq -r .done "$TMP/redeem.json")
t  "E3 the handle is one use" 410 "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "origin: https://$LHOST" -H 'x-5dive-viewer: 1' "$B$D")"
out=$(e2e "$TMP/viewer-ui.mjs" >/dev/null; D=$(jq -r .done "$TMP/redeem.json"); curl -s -o /dev/null -w '%{http_code}' -X POST -H "origin: https://evil.example" -H 'x-5dive-viewer: 1' "$B$D")
t  "E4 another origin cannot press it" 403 "$out"
out=$(e2e "$TMP/viewer-ui-mutant.mjs")
t  "E5 MUTANT (button's handler removed): the page shows nothing" '{"label":"Done","shown":[],"disabled":false}' "$out"
t  "E5 ... and NOTHING reaches the agent" "" "$(cat "$SENT_LOG")"
t  "E5 ... nothing was run" 0 "$(grep -v '^serve booking.com --login\|^viewer booking.com\|^serve booking.com$' "$FAKE_LOG" | grep -c 'revoke\|--stop\|^status')"

# E6 (DIVE-8354): the settings screen's link, through the server and the page's button.
reset; : >"$TMP/ctl.broken"
ticket booking.com "$SB" consumed
printf 'bind=%s\nexpires_at=%s\n' "$SB" "$(( $(date +%s) + 600 ))" >"$TMP/s/binds/booking.com"
j=$(curl -s -X POST -H "origin: https://$LHOST" -H 'x-5dive-viewer: 1' "$B/browser/viewer/booking.com/$(printf 'a%.0s' $(seq 64))/redeem")
out=$(node "$TMP/press.mjs" "$TMP/viewer-ui.mjs" "$B" "https://$LHOST" "$(jq -r .done <<<"$j")")
tc "E6 a link no agent asked for, not signed in: the page says so" '"Checking the sign-in…","Not signed in yet.' "$out"
tn "E6 ... and never 'already finished'" "already finished" "$out"
t  "E6 ... no agent told" "" "$(cat "$SENT_LOG")"

printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ))
