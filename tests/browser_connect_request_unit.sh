#!/usr/bin/env bash
# DIVE-4992 — `5dive browser connect-request` and its privileged half `_connect`.
#
# The agent asks; the OWNER'S TAP is the authorisation; the box binds. The arms
# are the row's ACCEPT, each one a way the property could be lost:
#   tap -> bind -> URL      the owner's tap registers the bind and yields the link
#   no tap -> no bind       a request by itself never reaches the relay
#   forged / other-user     a made-up code, another person's tap, another seat's
#                           relay, a replay and an expired button are all refused,
#                           and a refused tap does NOT burn the owner's button
#   Done                    revoke -> stop -> probe, in that order
# The Telegram API and shelld are one loopback stub server; the browser verbs the
# relay seat would run are a fake that logs what it was asked. Run unprivileged:
# the test seams are honoured only without root (arm S1 grades that they are).
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
export FIVEDIVE_CONNECTOR_DIR="$TMP/connectors"
export FIVEDIVE_BROWSER_CONNECT_HOME="$TMP/home"
export FIVEDIVE_CONNECTORD_ENV="$TMP/connectord.env"
export FIVEDIVE_PROVISIONING_ENV="$TMP/provisioning.env"
export FIVEDIVE_SHELLD_URL="http://127.0.0.1:$PORT"
export FIVEDIVE_TELEGRAM_API="http://127.0.0.1:$PORT"
export FIVEDIVE_BROWSER_CONNECT_SELF="$TMP/fake-browser"
export FIVEDIVE_BROWSER_CONNECT_PRIV="$BROWSER"
export FAKE_LOG="$TMP/fake.log" FAKE_CTL="$TMP/ctl"

priv() { printf '%s\0' "$@" | "$BROWSER" _connect; }
reset() { : >"$TMP/stub.log"; : >"$FAKE_LOG"; rm -f "$TMP"/ctl.{noprofile,authed,bind500,tgfail,badpath,servefail,broken,novline,snap404,snapneterr,snapsoft404,snapclear,snapstop,snapslow}; }
binds() { grep -c '"/shell/browser-viewer-bind"' "$TMP/stub.log" 2>/dev/null || true; }
last_code() { jq -r 'select(.path|test("sendMessage")) | .form.reply_markup' "$TMP/stub.log" | tail -1 | jq -r '.inline_keyboard[0][0].callback_data' | sed 's/^bconn://'; }

# ---- R: the request -----------------------------------------------------------
reset
out=$("$BROWSER" connect-request booking.com --reason="to search hotels for you" 2>&1); rc=$?
t  "R1 connect-request exits 0" 0 "$rc"
tc "R1 it says nothing is bound until the tap" "Nothing is bound until they tap" "$out"
msg=$(jq -c 'select(.path|test("sendMessage"))' "$TMP/stub.log")
t  "R2 exactly one message, to the paired owner" "$OWNER" "$(jq -r '.form.chat_id' <<<"$msg")"
t  "R2 through the seat's own bot token" "/bot123:SECRETBOTTOKEN/sendMessage" "$(jq -r '.path' <<<"$msg")"
tc "R3 the message names the site and the reason" "log in to booking.com" "$(jq -r '.form.text' <<<"$msg")"
tc "R3 ... and the reason" "Why: to search hotels for you" "$(jq -r '.form.text' <<<"$msg")"
t  "R4 one button, labelled Connect <site>" "Connect booking.com" "$(jq -r '.form.reply_markup' <<<"$msg" | jq -r '.inline_keyboard[0][0].text')"
CODE=$(last_code)
[[ "$CODE" =~ ^[0-9a-f]{48}$ ]]; t "R5 the button carries a 48-hex code" 0 $?
t  "R5 callback_data fits Telegram's 64-byte cap" 1 "$(( ${#CODE} + 6 <= 64 ))"
tn "R6 the code is never printed to the asking seat" "$CODE" "$out"
t  "R7 only the code's hash is stored" "" "$(grep -rl "$CODE" "$TMP/req" 2>/dev/null)"
t  "R7 ... under its sha256" 1 "$(ls "$TMP/req" | grep -cx "$(printf '%s' "$CODE" | sha256sum | cut -d' ' -f1)")"
t  "R8 NO TAP -> NO BIND: the request alone never reaches the relay" 0 "$(binds)"
t  "R8 ... and starts no browser" "" "$(cat "$FAKE_LOG")"

# ---- F: forged and foreign taps -----------------------------------------------
out=$(priv tap "$(printf 'f%.0s' $(seq 48))" "$OWNER" 2>&1); rc=$?
t  "F1 a made-up code is refused" 77 "$rc"
tc "F1 ... as not live" "not live" "$out"
out=$(priv tap "$CODE" 999999 2>&1); rc=$?
t  "F2 another person's tap is refused" 77 "$rc"
tc "F2 ... as not the paired owner" "only this seat's paired owner" "$out"
out=$(priv tap "$CODE" "-100$OWNER" 2>&1); rc=$?
t  "F3 a group chat id is not an owner" 77 "$rc"
out=$(priv tap "${CODE:0:40}" "$OWNER" 2>&1); rc=$?
t  "F4 a truncated code is refused" 77 "$rc"
t  "F5 no refused tap bound anything" 0 "$(binds)"
t  "F5 ... or started a browser" "" "$(cat "$FAKE_LOG")"
# a relay through ANOTHER seat: the stored request names a seat that is not us
f="$TMP/req/$(printf '%s' "$CODE" | sha256sum | cut -d' ' -f1)"
cp "$f" "$TMP/saved"; sed -i "s/^seat=.*/seat=agent-someone-else/" "$f"
out=$(priv tap "$CODE" "$OWNER" 2>&1); rc=$?
t  "F6 a tap relayed by a different seat is refused" 77 "$rc"
tc "F6 ... as another seat's button" "another seat's bot" "$out"
cp "$TMP/saved" "$f"

# ---- T: the owner's tap ---------------------------------------------------------
reset
out=$(priv tap "$CODE" "$OWNER" 2>&1); rc=$?
t  "T1 the owner's tap succeeds (refused taps did not burn it)" 0 "$rc"
t  "T2 serve then viewer, as the relay would" "serve booking.com|viewer" "$(head -2 "$FAKE_LOG" | cut -d' ' -f1,2 | tr '\n' '|' | sed 's/|$//' | sed 's/^serve booking.com|viewer.*/serve booking.com|viewer/')"
# DIVE-5203: the browser a person signs in through is plain Chrome, so the tap
# serves it that way from the start instead of starting a daemon to stop it.
t  "T2 ... and the serve is for a login" "serve booking.com --login" "$(head -1 "$FAKE_LOG")"
bindrec=$(jq -c 'select(.path=="/shell/browser-viewer-bind")' "$TMP/stub.log")
t  "T3 exactly one bind registered" 1 "$(binds)"
t  "T3 ... with the connectord token" "Bearer connectord-secret-token-0123456789" "$(jq -r '.auth' <<<"$bindrec")"
vbind=$(grep '^viewer' "$FAKE_LOG" | sed -n 's/.*--bind=\([^ ]*\).*/\1/p')
t  "T3 ... for the same bind the viewer was minted with" "$vbind" "$(jq -r '.body' <<<"$bindrec" | jq -r '.bind')"
t  "T3 ... and the ticket's own expiry" "$(date -u -d 2099-01-01T00:00:00Z +%s)" "$(jq -r '.body' <<<"$bindrec" | jq -r '.expiresAt')"
[[ "$vbind" =~ ^[0-9a-f]{32}$ ]]; t "T3 the bind is 128 random bits" 0 $?
tc "T4 the URL is the box host plus the viewer path" "url=https://box.example.5dive.ai/browser/viewer/booking.com/" "$out"
tn "T4 the bind never reaches the URL" "$vbind" "$(grep '^url=' <<<"$out")"
DONE=$(sed -n 's/^done=//p' <<<"$out")
[[ "$DONE" =~ ^[0-9a-f]{48}$ ]]; t "T5 a Done code comes back for the second button" 0 $?
tn "T6 the connectord token is never printed" "connectord-secret" "$out"
tn "T6 ... nor on the process table (it went on curl's stdin)" "connectord-secret" "$(grep -n 'Bearer \$token\|Bearer ${token}' "$BROWSER" | grep -v 'printf' || true)"
out=$(priv tap "$CODE" "$OWNER" 2>&1); rc=$?
t  "T7 a second tap on the same button is refused" 77 "$rc"
t  "T7 ... and binds nothing more" 1 "$(binds)"

# ---- D: Done --------------------------------------------------------------------
reset
out=$(priv done "$DONE" 999999 2>&1); rc=$?
t  "D1 another person cannot press Done" 77 "$rc"
out=$(priv done "$CODE" "$OWNER" 2>&1); rc=$?
t  "D2 a Connect code is not a Done code" 77 "$rc"
out=$(priv done "$DONE" "$OWNER" 2>&1); rc=$?
t  "D3 the owner's Done succeeds" 0 "$rc"
t  "D4 revoke -> stop -> probe, in that order" "viewer-revoke booking.com|serve booking.com --stop|status booking.com" "$(tr '\n' '|' <"$FAKE_LOG" | sed 's/|$//')"
tc "D5 the verdict comes back" "status=booking.com: authenticated" "$out"
out=$(priv done "$DONE" "$OWNER" 2>&1); rc=$?
t  "D6 Done is one-shot too" 77 "$rc"

# D7 (DIVE-5638): a box that cannot launch Chrome answers Done with the site's
# VERDICT, not the reproducer command that ends `status`'s broken paragraph —
# crystal-grove's agent channel got the raw `google-chrome --headless …` line.
reset
out=$("$BROWSER" connect-request booking.com --reason="d7" 2>&1)
out=$(priv tap "$(last_code)" "$OWNER" 2>&1); D7=$(sed -n 's/^done=//p' <<<"$out")
: >"$TMP/ctl.broken"
out=$(priv done "$D7" "$OWNER" 2>&1); rc=$?
t  "D7 Done on a broken box still completes" 0 "$rc"
tc "D7 ... and carries status_rc=69" "status_rc=69" "$out"
tc "D7 the status line is the site's verdict" "status=booking.com BROKEN (this box cannot start a browser as claude" "$out"
tn "D7 ... never the reproducer command" "status=google-chrome" "$out"
rm -f "$TMP/ctl.broken"

# ---- E: failure paths never hand over a link --------------------------------------
reset
"$BROWSER" connect-request booking.com >/dev/null 2>&1; CODE=$(last_code)
: >"$TMP/stub.log"; : >"$TMP/ctl.bind500"
out=$(priv tap "$CODE" "$OWNER" 2>&1); rc=$?
t  "E1 relay refuses the bind -> the tap fails" 69 "$rc"
tn "E1 ... and no URL is printed" "url=" "$out"
tc "E1 ... and the ticket is revoked" "viewer-revoke booking.com" "$(cat "$FAKE_LOG")"
reset
"$BROWSER" connect-request booking.com >/dev/null 2>&1; CODE=$(last_code); : >"$TMP/ctl.badpath"
out=$(priv tap "$CODE" "$OWNER" 2>&1); rc=$?
t  "E2 an unusable viewer path is refused" 69 "$rc"
t  "E2 ... before any bind" 0 "$(binds)"
reset
"$BROWSER" connect-request booking.com >/dev/null 2>&1; CODE=$(last_code); : >"$TMP/ctl.noprofile"; : >"$FAKE_LOG"
out=$(priv tap "$CODE" "$OWNER" 2>&1); rc=$?
t  "E3 a site with no profile is auth'd, then served" "serve|auth|serve|viewer" "$(cut -d' ' -f1 <"$FAKE_LOG" | tr '\n' '|' | sed 's/|$//')"
t  "E3 ... and the tap still succeeds" 0 "$rc"
reset
"$BROWSER" connect-request booking.com >/dev/null 2>&1; CODE=$(last_code)
f="$TMP/req/$(printf '%s' "$CODE" | sha256sum | cut -d' ' -f1)"; sed -i 's/^expires_at=.*/expires_at=1/' "$f"
out=$(priv tap "$CODE" "$OWNER" 2>&1); rc=$?
t  "E4 an expired button is refused" 77 "$rc"
t  "E4 ... and binds nothing" 0 "$(binds)"

# ---- Q: who can be asked -----------------------------------------------------------
reset; rm -rf "$TMP/req"/*; : >"$TMP/ctl.tgfail"
out=$("$BROWSER" connect-request booking.com 2>&1); rc=$?
t  "Q1 Telegram refusing the message is a failure, not a silent success" 69 "$rc"
t  "Q1 ... and leaves no live request behind" 0 "$(ls "$TMP/req" | wc -l | tr -d ' ')"
reset; rm -rf "$TMP/req"/*
mv "$TMP/home/.claude" "$TMP/home/.codex"
out=$("$BROWSER" connect-request booking.com 2>&1); rc=$?
t  "Q2 a bridge without the tap handler is refused up front" 69 "$rc"
tc "Q2 ... pointing at the dashboard" "Connected sites" "$out"
t  "Q2 ... and sends no dead button" 0 "$(grep -c sendMessage "$TMP/stub.log")"
mv "$TMP/home/.codex" "$TMP/home/.claude"
printf '{"allowFrom":[]}\n' >"$TMP/home/.claude/channels/telegram/access.json"
out=$("$BROWSER" connect-request booking.com 2>&1); rc=$?
t  "Q3 no paired owner -> refused" 69 "$rc"
printf '{"dmPolicy":"allowlist","allowFrom":["%s"],"groups":{}}\n' "$OWNER" >"$TMP/home/.claude/channels/telegram/access.json"
out=$("$BROWSER" connect-request _public 2>&1); rc=$?
t  "Q4 the public profile is not something to log in to" 64 "$rc"
out=$("$BROWSER" connect-request '../etc' 2>&1); rc=$?
t  "Q4 a traversing site name is refused" 64 "$rc"
out=$("$BROWSER" connect-request booking.com --reason="$(printf 'a\nb\033[31m%.0s' $(seq 100))" 2>&1)
txt=$(jq -r 'select(.path|test("sendMessage")) | .form.text' "$TMP/stub.log" | tail -1)
tn "Q5 control characters are stripped from the reason" $'\033' "$txt"
t  "Q5 the reason is capped" 1 "$(( $(sed -n 's/^Why: //p' <<<"$txt" | wc -c) <= 201 ))"

# ---- C: stuck on a captcha (DIVE-5200) -------------------------------------------------
# The same rails as Connect — the owner's tap is the authorisation, the link goes
# out from root as code — with three differences: the message says what is
# blocking and where, the browser opens on the page the agent was stopped on,
# and Done closes the view and HANDS THE BROWSER BACK (the person's plain Chrome
# swapped for the warm session, DIVE-5203, on the same page) so the agent's next
# read of the page goes through the profile the check was cleared in.
reset; rm -rf "$TMP/req"/*
PAGE="https://futuretools.io/submit-a-tool?ref=x"
out=$("$BROWSER" connect-request futuretools.io --challenge --url="$PAGE" --reason="submitting 5dive to the directory" 2>&1); rc=$?
t  "C1 connect-request --challenge exits 0" 0 "$rc"
tc "C1 it tells the agent to carry on after Done, not to poll" "carry on from the step you stopped on" "$out"
msg=$(jq -c 'select(.path|test("sendMessage"))' "$TMP/stub.log" | tail -1)
txt=$(jq -r '.form.text' <<<"$msg")
tc "C2 the message says what is blocking and where, in plain words" "is stuck on a captcha on futuretools.io" "$txt"
tc "C2 ... what the agent was doing" "Doing: submitting 5dive to the directory" "$txt"
tc "C2 ... and that the owner clears it, then taps Done" "Clear the check yourself, then tap Done" "$txt"
tn "C2 the page's address is NOT in the message (Telegram would preview it)" "https://" "$txt"
t  "C3 one button, labelled Open <site>" "Open futuretools.io" "$(jq -r '.form.reply_markup' <<<"$msg" | jq -r '.inline_keyboard[0][0].text')"
CCODE=$(last_code)
t  "C3 NO TAP -> NO BIND for a challenge either" 0 "$(binds)"
# DIVE-6725: the one load before the tap is the asking seat's look at the page,
# never a served browser or a view for the owner.
t  "C3 ... and no browser for the owner: only the asking seat's look at the page" "snapshot $PAGE --json --no-shot" "$(cat "$FAKE_LOG")"
out=$(priv tap "$CCODE" 999999 2>&1); rc=$?
t  "C4 only the paired owner can open it" 77 "$rc"
reset
out=$(priv tap "$CCODE" "$OWNER" 2>&1); rc=$?
t  "C5 the owner's tap succeeds" 0 "$rc"
t  "C5 the browser opens ON THE PAGE the agent was stopped on, as plain Chrome for a person" "serve futuretools.io --login --url=$PAGE" "$(head -1 "$FAKE_LOG")"
t  "C5 exactly one bind" 1 "$(binds)"
tc "C5 the link and a kind come back to the plugin" "kind=challenge" "$out"
tc "C5 ... the one-time link" "url=https://box.example.5dive.ai/browser/viewer/futuretools.io/" "$out"
CDONE=$(sed -n 's/^done=//p' <<<"$out")
reset
out=$(priv done "$CDONE" 999999 2>&1); rc=$?
t  "C6 another person cannot press Done" 77 "$rc"
out=$(priv done "$CDONE" "$OWNER" 2>&1); rc=$?
t  "C7 the owner's Done succeeds" 0 "$rc"
t  "C7 Done REVOKES the view, serves the page back for the agent, then reads it: no stop, no probe" "viewer-revoke futuretools.io|serve futuretools.io --url=$PAGE|snapshot futuretools.io $PAGE --json --no-shot" "$(tr '\n' '|' <"$FAKE_LOG" | sed 's/|$//')"
tc "C7 the verdict says the browser is back with the agent" "status=the view is closed and the browser is back in the agent's hands" "$out"
tc "C7 ... and is a challenge verdict" "kind=challenge" "$out"
out=$(priv done "$CDONE" "$OWNER" 2>&1); rc=$?
t  "C8 Done is one-shot" 77 "$rc"
# no --url: the site's own page
reset; "$BROWSER" connect-request futuretools.io --challenge >/dev/null 2>&1; CCODE=$(last_code); : >"$FAKE_LOG"
out=$(priv tap "$CCODE" "$OWNER" 2>&1); rc=$?
t  "C9 no --url opens the site's own front page" "serve futuretools.io --login --url=https://futuretools.io/" "$(head -1 "$FAKE_LOG")"
# the page must be ON the site
reset
for bad in "https://evil.example/futuretools.io" "javascript:alert(1)" "https://futuretools.io.evil.example/" "file:///etc/passwd" "https://futuretools.io/a b"; do
  out=$("$BROWSER" connect-request futuretools.io --challenge --url="$bad" 2>&1); rc=$?
  t  "C10 a page that is not on the site is refused: $bad" 64 "$rc"
done
t  "C10 ... and nobody was messaged" 0 "$(grep -c sendMessage "$TMP/stub.log")"
out=$(printf '%s\0' challenge futuretools.io "https://evil.example/" "x" | "$BROWSER" _connect 2>&1); rc=$?
t  "C11 root re-checks the page itself (the agent verb is not the only gate)" 64 "$rc"
t  "C11 ... and messages nobody" 0 "$(grep -c sendMessage "$TMP/stub.log")"
out=$("$BROWSER" connect-request futuretools.io --url="$PAGE" 2>&1); rc=$?
t  "C12 --url without --challenge is a usage error" 64 "$rc"
out=$("$BROWSER" connect-request futuretools.io.sub --challenge --url="https://sub.futuretools.io.sub/x" 2>&1); rc=$?
t  "C12 a subdomain of the site is its page" 0 "$rc"
# a request file tampered to point elsewhere is refused at the tap
reset; "$BROWSER" connect-request futuretools.io --challenge --url="$PAGE" >/dev/null 2>&1; CCODE=$(last_code)
f="$TMP/req/$(printf '%s' "$CCODE" | sha256sum | cut -d' ' -f1)"; sed -i 's|^url=.*|url=https://evil.example/|' "$f"; : >"$FAKE_LOG"
out=$(priv tap "$CCODE" "$OWNER" 2>&1); rc=$?
t  "C13 a stored page that is not on the site is refused at the tap" 77 "$rc"
t  "C13 ... before any browser starts" "" "$(cat "$FAKE_LOG")"
t  "C13 ... or any bind" 0 "$(binds)"
# serve --url itself only opens pages of the site
out=$("$BROWSER" serve futuretools.io --url=https://evil.example/ 2>&1); rc=$?
t  "C14 serve --url refuses a page of another site" 64 "$rc"
# a site with no profile yet: auth serves the FRONT page itself, so the tap stops
# that browser and serves again ON the stopped page (DIVE-5203 merge)
reset; "$BROWSER" connect-request futuretools.io --challenge --url="$PAGE" >/dev/null 2>&1; CCODE=$(last_code); : >"$TMP/ctl.noprofile"; : >"$FAKE_LOG"
out=$(priv tap "$CCODE" "$OWNER" 2>&1); rc=$?
t  "C15 no profile: the tap succeeds" 0 "$rc"
t  "C15 ... auth, stop its front-page browser, serve plain on the stopped page, then the view" \
   "serve futuretools.io --login --url=$PAGE|auth futuretools.io|serve futuretools.io --stop|serve futuretools.io --login --url=$PAGE|viewer futuretools.io" \
   "$(cut -d' ' -f1-4 <"$FAKE_LOG" | sed 's/ --bind=.*//' | tr '\n' '|' | sed 's/|$//')"
CDONE=$(sed -n 's/^done=//p' <<<"$out")
# a Done whose stored page was tampered off the site hands back the front page, not that page
f="$TMP/req/$(printf '%s' "$CDONE" | sha256sum | cut -d' ' -f1)"; sed -i 's|^url=.*|url=https://evil.example/|' "$f"; : >"$FAKE_LOG"
out=$(priv done "$CDONE" "$OWNER" 2>&1); rc=$?
t  "C16 a Done with a tampered page still closes the view" 0 "$rc"
t  "C16 ... and serves the site back with NO foreign page" "viewer-revoke futuretools.io|serve futuretools.io|snapshot futuretools.io https://futuretools.io/ --json --no-shot" "$(tr '\n' '|' <"$FAKE_LOG" | sed 's/|$//')"
# the hand-back fails: Done still succeeds (the view is closed) and says what happens next
reset; "$BROWSER" connect-request futuretools.io --challenge --url="$PAGE" >/dev/null 2>&1; CCODE=$(last_code)
out=$(priv tap "$CCODE" "$OWNER" 2>&1); CDONE=$(sed -n 's/^done=//p' <<<"$out"); : >"$TMP/ctl.servefail"; : >"$FAKE_LOG"
out=$(priv done "$CDONE" "$OWNER" 2>&1); rc=$?
t  "C17 a failed hand-back is still a closed view" 0 "$rc"
tc "C17 ... and the verdict says the agent's next command starts it, with the check kept" "its next command starts it (the cleared check is kept in the profile)" "$out"

# ---- P: look before asking, and again at Done (DIVE-6725) ---------------------------
# exact-swallow's ceo sent its owner three "clear the captcha" buttons for a Search
# Console URL that was a 404 with no captcha on it. Nothing loaded the page first.
BAD="https://futuretools.io/inspect?id=not-a-page"
for case in snap404:"HTTP 404" snapneterr:"net::ERR_NAME_NOT_RESOLVED" snapsoft404:"Page not found"; do
  reset; rm -rf "$TMP/req"/*; : >"$TMP/ctl.${case%%:*}"
  out=$("$BROWSER" connect-request futuretools.io --challenge --url="$BAD" --reason="tap Got it" 2>&1); rc=$?
  t  "P1 ${case%%:*}: a page that is an error is refused, not sent" 69 "$rc"
  tc "P1 ${case%%:*}: ... naming what the box saw" "${case#*:}" "$out"
  t  "P1 ${case%%:*}: ... nobody was messaged" 0 "$(grep -c sendMessage "$TMP/stub.log")"
  t  "P1 ${case%%:*}: ... and no request file was written" "" "$(ls "$TMP/req")"
  t  "P1 ${case%%:*}: the page was loaded first, as the asking seat" "snapshot $BAD --json --no-shot" "$(head -1 "$FAKE_LOG")"
done
reset; rm -rf "$TMP/req"/*
out=$("$BROWSER" connect-request futuretools.io --challenge --url="$PAGE" 2>&1); rc=$?
t  "P2 a 403 that IS a check (Cloudflare's \"Just a moment...\") is still sent" "0 1" "$rc $(grep -c sendMessage "$TMP/stub.log")"
tc "P2 ... in captcha words, since the box saw one" "is stuck on a captcha" "$(jq -r 'select(.path|test("sendMessage")) | .form.text' "$TMP/stub.log")"
reset; rm -rf "$TMP/req"/*; : >"$TMP/ctl.snapslow"
out=$(FIVEDIVE_BROWSER_CONNECT_LOOK_S=1 "$BROWSER" connect-request futuretools.io --challenge --url="$PAGE" 2>&1); rc=$?
t  "P2 a look that runs out of time is not an answer: the ask goes out as before" "0 1" "$rc $(grep -c sendMessage "$TMP/stub.log")"
tc "P2 ... in captcha words" "is stuck on a captcha" "$(jq -r 'select(.path|test("sendMessage")) | .form.text' "$TMP/stub.log")"
reset; rm -rf "$TMP/req"/*; : >"$TMP/ctl.snapstop"
out=$("$BROWSER" connect-request futuretools.io --challenge --url="$PAGE" 2>&1); rc=$?
t  "P2 a page verb that STOPS on a check (no render at all) is a check, and is sent" "0 1" "$rc $(grep -c sendMessage "$TMP/stub.log")"
tc "P2 ... in captcha words" "is stuck on a captcha" "$(jq -r 'select(.path|test("sendMessage")) | .form.text' "$TMP/stub.log")"
reset; rm -rf "$TMP/req"/*; : >"$TMP/ctl.snapclear"
out=$("$BROWSER" connect-request futuretools.io --challenge --url="$PAGE" --reason="tap Got it on the tour bubble" 2>&1); rc=$?
txt=$(jq -r 'select(.path|test("sendMessage")) | .form.text' "$TMP/stub.log")
t  "P3 no check on the page: still sent" "0 1" "$rc $(grep -c sendMessage "$TMP/stub.log")"
tn "P3 ... and never called a captcha" "captcha" "$txt"
tn "P3 ... nor a check to clear" "Clear the check" "$txt"
tc "P3 ... it asks the owner to take over, for what" "needs you to take over" "$txt"
tc "P3 ... with what to do" "What to do: tap Got it on the tour bubble" "$txt"
t  "P3 ... on the same Open button" "Open futuretools.io" "$(jq -r 'select(.path|test("sendMessage")) | .form.reply_markup' "$TMP/stub.log" | jq -r '.inline_keyboard[0][0].text')"
tc "P3 the agent is told no check was seen" "no check was seen on" "$out"
PCODE=$(last_code); reset
out=$(priv tap "$PCODE" "$OWNER" 2>&1); rc=$?
t  "P4 the tap tells the plugin there is no check, so its link text says take over" "0 check=0" "$rc $(grep '^check=' <<<"$out")"
PDONE=$(sed -n 's/^done=//p' <<<"$out"); : >"$TMP/ctl.snapclear"
out=$(priv done "$PDONE" "$OWNER" 2>&1); rc=$?
t  "P5 Done says what the box shows now: no check" "0 check=none" "$rc $(grep '^check=' <<<"$out")"
tc "P5 ... the page's title and address" "It shows \"URL inspection - Search Console\" at $PAGE" "$out"
tn "P5 ... and never says a check was cleared" "cleared" "$out"
reset; rm -rf "$TMP/req"/*
"$BROWSER" connect-request futuretools.io --challenge --url="$PAGE" >/dev/null 2>&1; PCODE=$(last_code)
out=$(priv tap "$PCODE" "$OWNER" 2>&1); t "P6 a page with a check: the tap says check=1" "check=1" "$(grep '^check=' <<<"$out")"
PDONE=$(sed -n 's/^done=//p' <<<"$out")
out=$(priv done "$PDONE" "$OWNER" 2>&1); rc=$?
t  "P6 Done on a page whose check is still there says so" "0 check=still" "$rc $(grep '^check=' <<<"$out")"
tc "P6 ... in the verdict" "a check is still on it" "$out"
reset; rm -rf "$TMP/req"/*
"$BROWSER" connect-request futuretools.io --challenge --url="$PAGE" >/dev/null 2>&1; PCODE=$(last_code)
out=$(priv tap "$PCODE" "$OWNER" 2>&1); PDONE=$(sed -n 's/^done=//p' <<<"$out"); : >"$TMP/ctl.snapslow"
out=$(FIVEDIVE_BROWSER_CONNECT_LOOK_S=1 bash -c 'printf "%s\0" done "$1" "$2" | "$3" _connect' _ "$PDONE" "$OWNER" "$BROWSER" 2>&1); rc=$?
t  "P7 a Done whose read-back runs out of time still completes, inside its bound" "0 check=unknown" "$rc $(grep '^check=' <<<"$out")"
tc "P7 ... and says it is not known, never cleared" "whether a check is still on it is not known" "$out"

# ---- L: a tap one minute late (DIVE-6725) --------------------------------------------
# The owner tapped at 09:32:08Z a button that had expired at 09:31:03Z and got a
# dead end. A late tap by the owner now gets a fresh button; a very late one does not.
reset; rm -rf "$TMP/req"/*; : >"$TMP/ctl.snapclear"
"$BROWSER" connect-request futuretools.io --challenge --url="$PAGE" --reason="tap Got it" >/dev/null 2>&1; LCODE=$(last_code)
f="$TMP/req/$(printf '%s' "$LCODE" | sha256sum | cut -d' ' -f1)"; sed -i "s/^expires_at=.*/expires_at=$(( $(date -u +%s) - 65 ))/" "$f"
reset
out=$(priv tap "$LCODE" "$OWNER" 2>&1); rc=$?
t  "L1 a tap 65 s late is not a bind" "77 0" "$rc $(binds)"
tc "L1 ... the owner is told a fresh button was sent" "a fresh one was just sent" "$out"
msg=$(jq -c 'select(.path|test("sendMessage"))' "$TMP/stub.log" | tail -1)
t  "L1 ... to the owner who tapped" "$OWNER" "$(jq -r '.form.chat_id' <<<"$msg")"
tc "L1 ... saying the last one expired" "The last button expired" "$(jq -r '.form.text' <<<"$msg")"
tc "L1 ... with the same words as the first ask" "What to do: tap Got it" "$(jq -r '.form.text' <<<"$msg")"
L2CODE=$(last_code)
t  "L1 ... carrying a NEW code" 1 "$(( ${#L2CODE} == 48 ))"
tn "L1 ... (not the expired one)" "$LCODE" "$L2CODE"
reset
out=$(priv tap "$L2CODE" "$OWNER" 2>&1); rc=$?
t  "L2 the fresh button opens the same page" "0 serve futuretools.io --login --url=$PAGE" "$rc $(head -1 "$FAKE_LOG")"
tc "L2 ... with the same no-check wording" "check=0" "$out"
reset; rm -rf "$TMP/req"/*
"$BROWSER" connect-request futuretools.io --challenge --url="$PAGE" >/dev/null 2>&1; LCODE=$(last_code)
f="$TMP/req/$(printf '%s' "$LCODE" | sha256sum | cut -d' ' -f1)"; sed -i "s/^expires_at=.*/expires_at=$(( $(date -u +%s) - 7300 ))/" "$f"
reset
out=$(priv tap "$LCODE" "$OWNER" 2>&1); rc=$?
t  "L3 a tap two hours late is refused, with no fresh button" "77 0" "$rc $(grep -c sendMessage "$TMP/stub.log")"
tc "L3 ... and says to ask the agent" "Ask the agent to send a new one" "$out"
reset; rm -rf "$TMP/req"/*
"$BROWSER" connect-request futuretools.io --challenge --url="$PAGE" >/dev/null 2>&1; LCODE=$(last_code)
f="$TMP/req/$(printf '%s' "$LCODE" | sha256sum | cut -d' ' -f1)"; sed -i "s/^expires_at=.*/expires_at=$(( $(date -u +%s) - 65 ))/" "$f"
reset
out=$(priv tap "$LCODE" 999999 2>&1); rc=$?
t  "L4 a late tap by someone else gets nothing" "77 0" "$rc $(grep -c sendMessage "$TMP/stub.log")"

# ---- H: the page hint (DIVE-5200) — the public profile is never probed, so a
# captcha interstitial there is named on the way out, keyed on the TITLE only.
hint_fns=$(awk '/^CHALLENGE_TITLE_MARKER=/{print} /^_render_title\(\)/{print} /^_challenge_hint\(\) \{/{p=1} p{print} p&&/^}$/{exit}' "$BROWSER")
hint() { ( PROG=browser; eval "$hint_fns"; _challenge_hint "$@" ) 2>&1; }
printf '<html><head><title>Just a moment...</title></head><body>cf</body></html>' >"$TMP/cf.html"
printf '<html><head><title>Submit a tool | FutureTools</title></head><body><div class="g-recaptcha"></div><form></form></body></html>' >"$TMP/form.html"
out=$(hint "$TMP/cf.html" "https://futuretools.io/submit")
tc "H1 a challenge interstitial names the handoff, with the host and the page" "connect-request futuretools.io --challenge --url=https://futuretools.io/submit" "$out"
tc "H1 ... and says 5dive never solves one" "never solves one" "$out"
t  "H2 a normal form that merely embeds a reCAPTCHA says nothing" "" "$(hint "$TMP/form.html" "https://futuretools.io/submit")"
out=$(hint "$TMP/cf.html" "" "https://uneed.best/submit")
tc "H3 with no landed URL, the asked URL names the host" "connect-request uneed.best --challenge" "$out"

# ---- H: the handoff (DIVE-5287) — the same button, onto the agent's live window ----
reset; rm -rf "$TMP/req"/*
out=$(priv handoff tiktok.com "solve the slider puzzle" 2>&1); rc=$?
t  "H1 a handoff request is sent" 0 "$rc"
msg=$(jq -c 'select(.path|test("sendMessage"))' "$TMP/stub.log" | tail -1)
tc "H1 ... asking the owner to TAKE OVER, not to log in" "needs you to take over" "$(jq -r '.form.text' <<<"$msg")"
tc "H1 ... with what for" "What for: solve the slider puzzle" "$(jq -r '.form.text' <<<"$msg")"
tc "H1 ... and that the agent resumes where they leave it" "carries on from the page you left" "$(jq -r '.form.text' <<<"$msg")"
t  "H1 ... on the same Connect button" "Connect tiktok.com" "$(jq -r '.form.reply_markup' <<<"$msg" | jq -r '.inline_keyboard[0][0].text')"
CODE=$(last_code); : >"$FAKE_LOG"
out=$(priv tap "$CODE" "$OWNER" 2>&1); rc=$?
t  "H2 the owner's tap on a handoff opens the view" 0 "$rc"
DONE=$(sed -n 's/^done=//p' <<<"$out"); : >"$FAKE_LOG"
out=$(priv done "$DONE" "$OWNER" 2>&1); rc=$?
t  "H3 Done on an input-mode site hands the window BACK and does not stop it" "viewer-revoke tiktok.com|handoff tiktok.com --close|status tiktok.com" "$(tr '\n' '|' <"$FAKE_LOG" | sed 's/|$//')"

# ---- X: a self-hosted box (DIVE-6111) — no front, so SSH steps to the same window ----
# No provisioning.env is what a box 5dive did not build looks like. The hosted
# arms above ran WITH it, unchanged.
export FIVEDIVE_PROVISIONING_ENV="$TMP/no-provisioning.env"
export FIVEDIVE_BROWSER_SSH_USER=lodar FIVEDIVE_BROWSER_SSH_ADDR=203.0.113.7
reset; rm -rf "$TMP/req"/*
out=$(priv handoff tiktok.com "sign in to Google" 2>&1); rc=$?
t  "X1 a self-host handoff exits 0" 0 "$rc"
tc "X1 ... and tells the agent there is no link, the steps went out" "no web front, so there is no link: sent the owner the SSH steps" "$out"
t  "X2 it starts the view on loopback, on the live window, as a hand-run" "viewer tiktok.com --bind=local --ttl=1800" "$(head -1 "$FAKE_LOG")"
t  "X2 ... and NEVER registers a relay bind (there is no relay)" 0 "$(binds)"
msg=$(jq -c 'select(.path|test("sendMessage"))' "$TMP/stub.log" | tail -1)
txt=$(jq -r '.form.text' <<<"$msg")
t  "X3 exactly one message, to the paired owner" "$OWNER" "$(jq -r '.form.chat_id' <<<"$msg")"
tc "X3 ... the tunnel line, filled in, onto the view's REAL port" "<code>ssh -N -L 5900:127.0.0.1:5917 lodar@203.0.113.7</code>" "$txt"
tc "X3 ... the password as the command that reads it" "<code>ssh -t lodar@203.0.113.7 sudo cat /var/lib/5dive/browser-profiles/agent-clicker/tiktok.com/.5dive-viewer.pw</code>" "$txt"
tc "X3 ... where to point the VNC client" "<code>vnc://localhost:5900</code>" "$txt"
tc "X3 ... what for" "What for: sign in to Google" "$txt"
tc "X3 ... and to tap Done when finished" "tap Done" "$txt"
tn "X4 NO http(s) link of any kind is sent" "http" "$txt"
t  "X4 ... HTML, commands in code, previews off" "HTML true" "$(jq -r '.form.parse_mode' <<<"$msg") $(jq -r '.form.link_preview_options' <<<"$msg" | jq -r .is_disabled)"
t  "X5 the button is Done, carrying a 48-hex Done code" "Done — carry on" "$(jq -r '.form.reply_markup' <<<"$msg" | jq -r '.inline_keyboard[0][0].text')"
XDONE=$(jq -r '.form.reply_markup' <<<"$msg" | jq -r '.inline_keyboard[0][0].callback_data' | sed -n 's/^bdone:\([0-9a-f]\{48\}\)$/\1/p')
t  "X5 ... (the code parses)" 48 "${#XDONE}"
tn "X5 ... and the code is never printed to the asking seat" "$XDONE" "$out"
: >"$FAKE_LOG"
out=$(priv done "$XDONE" "$OWNER" 2>&1); rc=$?
t  "X6 the owner's Done hands the window BACK on the window's own seat" "0 viewer-revoke tiktok.com|handoff tiktok.com --close|status tiktok.com" "$rc $(tr '\n' '|' <"$FAKE_LOG" | sed 's/|$//')"
tc "X6 ... and answers the bridge in the verdict shape it parses" "site=tiktok.com" "$out"
out=$(priv done "$XDONE" "$OWNER" 2>&1); rc=$?
t  "X6 ... once: a second Done is refused" 77 "$rc"

reset; rm -rf "$TMP/req"/*
out=$(FIVEDIVE_BROWSER_SSH_USER= FIVEDIVE_BROWSER_SSH_ADDR= priv handoff tiktok.com "" 2>&1); rc=$?
txt=$(jq -rs 'map(select(.path|test("sendMessage"))) | last | .form.text' "$TMP/stub.log")
tc "X7 an unknown user and address are NAMED placeholders, never a guess" "ssh -N -L 5900:127.0.0.1:5917 &lt;your-sudo-user&gt;@&lt;your-box-address&gt;" "$txt"

reset; rm -rf "$TMP/req"/*
out=$(FIVEDIVE_BROWSER_CONNECT_HOME="$TMP/nohome" priv handoff tiktok.com "solve the check" 2>&1); rc=$?
t  "X8 no paired owner: still exits 0, nobody messaged" "0 0" "$rc $(grep -c sendMessage "$TMP/stub.log")"
tc "X8 ... and the steps are PRINTED instead" "ssh -N -L 5900:127.0.0.1:5917 lodar@203.0.113.7" "$out"
tc "X8 ... with how to hand the window back" "or run on the box: sudo -u $ME 5dive browser handoff tiktok.com --close" "$out"
t  "X8 ... and no Done code is left behind" "" "$(ls "$TMP/req")"

reset; rm -rf "$TMP/req"/*; : >"$TMP/ctl.tgfail"
out=$(priv handoff tiktok.com "" 2>&1); rc=$?
t  "X9 Telegram refuses: exits 0, steps printed, no Done code left" "0 yes " "$rc $(grep -q 'sudo cat /var/lib' <<<"$out" && echo yes) $(ls "$TMP/req")"

reset; : >"$TMP/ctl.novline"
out=$(priv handoff tiktok.com "" 2>&1); rc=$?
t  "X10 a view that does not say where it listens is closed, nothing sent" "69 0 viewer-revoke tiktok.com" "$rc $(grep -c sendMessage "$TMP/stub.log") $(tail -1 "$FAKE_LOG")"

printf 'CONNECTORD_TOKEN=x\n' >"$TMP/half-provisioning.env"
reset
out=$(FIVEDIVE_PROVISIONING_ENV="$TMP/half-provisioning.env" priv handoff tiktok.com "" 2>&1); rc=$?
t  "X11 a provisioning file with no domain is no front either" "0 yes" "$rc $(grep -q 'no web front' <<<"$out" && echo yes)"
reset
out=$(FIVEDIVE_PROVISIONING_ENV="$TMP/provisioning.env" priv handoff tiktok.com "" 2>&1); rc=$?
t  "X12 (control) with the front, the same call is the hosted Connect button again" "0 Connect tiktok.com " \
   "$rc $(jq -r 'select(.path|test("sendMessage")) | .form.reply_markup' "$TMP/stub.log" | jq -r '.inline_keyboard[0][0].text') $(cat "$FAKE_LOG")"
unset FIVEDIVE_BROWSER_SSH_USER FIVEDIVE_BROWSER_SSH_ADDR
export FIVEDIVE_PROVISIONING_ENV="$TMP/provisioning.env"

# ---- O: owner-only (DIVE-6518) ---------------------------------------------------------
# The measured shape: allowFrom = the owner plus a guest, owners = the owner. The
# guest may talk to the agent; the Connect message and its button are not theirs.
GUEST=444555666
ACC="$TMP/home/.claude/channels/telegram/access.json"
sent_to() { jq -r 'select(.path|test("sendMessage")) | .form.chat_id' "$TMP/stub.log" | sort | tr '\n' ' ' | sed 's/ $//'; }
printf '{"dmPolicy":"allowlist","allowFrom":["%s","%s"],"owners":["%s"],"groups":{}}\n' "$OWNER" "$GUEST" "$OWNER" >"$ACC"

reset; rm -rf "$TMP/req"/*
out=$("$BROWSER" connect-request booking.com --reason="to search hotels" 2>&1); rc=$?
t  "O1 owners set: the Connect message goes to the owner only" "0 $OWNER" "$rc $(sent_to)"
OCODE=$(last_code)
reset
out=$("$BROWSER" connect-request booking.com --challenge 2>&1); rc=$?
t  "O2 ... and so does a captcha request" "0 $OWNER" "$rc $(sent_to)"
reset
out=$(priv tap "$OCODE" "$GUEST" 2>&1); rc=$?
t  "O3 a guest in allowFrom cannot tap the owner's Connect button" 77 "$rc"
tc "O3 ... refused as not the paired owner" "only this seat's paired owner can use that button" "$out"
t  "O3 ... and nothing was bound or started" "0 " "$(binds) $(cat "$FAKE_LOG")"
out=$(priv tap "$OCODE" "$OWNER" 2>&1); rc=$?
t  "O4 the owner's tap on the same button still works" 0 "$rc"

reset; rm -rf "$TMP/req"/*
out=$(FIVEDIVE_PROVISIONING_ENV="$TMP/half-provisioning.env" priv handoff tiktok.com "" 2>&1); rc=$?
t  "O5 a no-front handoff sends its SSH steps to the owner only" "0 $OWNER" "$rc $(sent_to)"
ODONE=$(jq -r 'select(.path|test("sendMessage")) | .form.reply_markup' "$TMP/stub.log" | jq -r '.inline_keyboard[0][0].callback_data' | sed -n 's/^bdone://p' | head -1)
out=$(priv done "$ODONE" "$GUEST" 2>&1); rc=$?
t  "O6 ... and the guest cannot press its Done" 77 "$rc"

# Old pairings have no owners record: every allowed DM, today's behaviour.
printf '{"dmPolicy":"allowlist","allowFrom":["%s","%s"],"groups":{}}\n' "$OWNER" "$GUEST" >"$ACC"
reset; rm -rf "$TMP/req"/*
out=$("$BROWSER" connect-request booking.com 2>&1); rc=$?
t  "O7 owners absent: both allowed DMs are asked" "0 $OWNER $GUEST" "$rc $(sent_to)"
OCODE=$(last_code)
out=$(priv tap "$OCODE" "$GUEST" 2>&1); rc=$?
t  "O7 ... and either may tap" 0 "$rc"

# An owner the bot no longer allows is nobody.
printf '{"dmPolicy":"allowlist","allowFrom":["%s"],"owners":["%s"],"groups":{}}\n' "$GUEST" "$OWNER" >"$ACC"
reset
out=$("$BROWSER" connect-request booking.com 2>&1); rc=$?
t  "O8 an owner outside allowFrom: refused, nobody messaged" "69 " "$rc $(sent_to)"
printf '{"dmPolicy":"allowlist","allowFrom":["%s"],"groups":{}}\n' "$OWNER" >"$ACC"

# ---- S: the seams are not a door under root -------------------------------------------
# EVERY top-level non-root block, not the first one: the on-demand serve's seams
# (DIVE-5389) live in a second block, and an awk that exits at the first `fi`
# never sees it — so a seam there could not be on the list below at all.
seam_block=$(awk '/^if \[\[ \$EUID -ne 0 \]\]; then$/{p=1} p{print} p&&/^fi$/{p=0}' "$BROWSER")
t  "S0 the scan reads every non-root block" "$(grep -c '^if \[\[ \$EUID -ne 0 \]\]; then$' "$BROWSER")" "$(grep -c '^if \[\[ \$EUID -ne 0 \]\]; then$' <<<"$seam_block")"
for v in FIVEDIVE_BROWSER_CONNECT_DIR FIVEDIVE_CONNECTOR_DIR FIVEDIVE_CONNECTORD_ENV FIVEDIVE_PROVISIONING_ENV FIVEDIVE_SHELLD_URL FIVEDIVE_TELEGRAM_API FIVEDIVE_BROWSER_CONNECT_SELF FIVEDIVE_BROWSER_CONNECT_PRIV \
         FIVEDIVE_BROWSER_SSH_USER FIVEDIVE_BROWSER_SSH_ADDR FIVEDIVE_BROWSER_CONNECT_LOOK_S FIVEDIVE_BROWSER_WAKE_PRIV FIVEDIVE_BROWSER_SERVE_MIN_MB FIVEDIVE_BROWSER_MEMINFO FIVEDIVE_BROWSER_SUDOERS_DIR FIVEDIVE_BROWSER_VISUDO; do
  t "S1 $v is used at all (a seam the file never reads grades nothing)" 1 "$(( $(grep -c "$v" "$BROWSER") > 0 ))"
  t "S1 $v is read only inside the non-root block" "$(grep -c "$v" "$BROWSER")" "$(grep -c "$v" <<<"$seam_block")"
done
t  "S2 _connect stays root under sudo (not dropped to the seat)" 1 "$(grep -c 'setup|adblock|config|approve|approvals|adapters|_connect|' "$BROWSER")"
tc "S3 the bot token rides curl's stdin, not argv" "| curl -sS --connect-timeout 5 --max-time 15 --config -" "$(grep -A1 'printf .url = ' "$BROWSER")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
