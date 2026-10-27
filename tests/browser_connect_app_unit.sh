#!/usr/bin/env bash
# DIVE-7133 — a self-hosted box linked to the 5dive app: an agent's login or check
# request arrives in that agent's app chat as one Connect link, not in the login shell.
#
#   A  linked, login links on: connect-request exits 0 and posts ONE agent message
#      to the box's API (/server/messages/event, the box token): the link only in
#      metadata.link (on the box's own host), Done / Not now as the question, no
#      link in the text a push shows. The agent never sees the link.
#   D  connect-done is the Done: revoke, stop, probe; the code is spent once
#   K  the app ask's codes cannot be claimed by a button tap or as 'shell'
#   C  --challenge: the page is looked at first, then "Open <site>" on that page
#   B  no login link yet but the box's https front has a name: --via=box, at once
#   F  no front at all: `5dive secret https enable --via=auto`, then the link
#   N  no https possible (behind a router): one line in the chat, the login-shell
#      path, the ask waits there, and the agent is told
#   R  the API refuses: no live link left, the ask waits in the shell
#   O  order and negative controls: Telegram paired + linked -> the app chat only;
#      not linked -> the login shell (DIVE-7078); a hosted box never posts; the
#      pre-fix tree on the linked fixture posts nothing (skipped where its base
#      commit is not in the checkout)
# Run unprivileged: every seam is honoured only without root.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
BASE=4d09fce   # 5dive-browser main before DIVE-7133
TMP=$(mktemp -d)
trap 'rc=$?; [[ -n "${API_PID:-}" ]] && kill "$API_PID" 2>/dev/null; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }
tn() { if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected NOT to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }

command -v jq >/dev/null || { echo "SKIP: needs jq"; exit 1; }

# ---- the box's API: every request logged, one JSON line each ---------------------
cat >"$TMP/api.py" <<'PY'
import http.server, json, os, sys
LOG, STATUS = sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(n).decode()
        with open(LOG, "a") as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers.get("authorization"), "body": body}) + "\n")
        try: code = int(open(STATUS).read().strip())
        except Exception: code = 200
        out = b'{"ok":true,"result":{"message_id":1}}'
        self.send_response(code); self.send_header("content-length", str(len(out))); self.end_headers(); self.wfile.write(out)
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
python3 "$TMP/api.py" "$PORT" "$TMP/api.log" "$TMP/api.status" & API_PID=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done

# ---- the box seat's browser verbs, and the 5dive CLI, faked ----------------------
cat >"$TMP/fake-browser" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG"
case "$1" in
  viewer)
    printf '/browser/viewer/%s/%s\n' "$2" "$(printf 'a%.0s' $(seq 64))"
    echo "one-time, expires 2099-01-01T00:00:00Z, bound to session ${3#--bind=}. Redeeming it consumes it." >&2 ;;
  snapshot)
    u=""; for a in "${@:2}"; do [[ "$a" =~ ^https?:// ]] && { u="$a"; break; }; done
    jq -nc --arg u "$u" '{url:$u, title:"Just a moment...", http_status:403, nodes:[]}' ;;
  status) echo "  $2 authenticated" ;;
esac
exit 0
SH
# `secret https`: HTTPS_HOST = the name the box's front already has; AUTO_HOST =
# what --via=auto makes; neither = behind a router.
cat >"$TMP/fake-5dive" <<'SH'
#!/usr/bin/env bash
printf 'ARGS %s\n' "$*" >>"$CLI_LOG"
case "$*" in
  "--json secret https status")
    if [[ -n "${HTTPS_HOST:-}" ]]; then jq -nc --arg h "$HTTPS_HOST" '{ok:true,data:{on:true,managed:true,mode:"ip",host:$h}}'
    else echo '{"ok":true,"data":{"on":false,"managed":true}}'; fi ;;
  "--json secret https enable --via=auto")
    [[ -n "${AUTO_SLEEP:-}" ]] && sleep "$AUTO_SLEEP"
    if [[ -n "${AUTO_HOST:-}" ]]; then jq -nc --arg h "$AUTO_HOST" '{ok:true,data:{on:true,managed:true,mode:"ip",host:$h}}'
    else echo '{"ok":false,"error":{"code":7,"message":"no https name on this box: this box has no public IPv4 address (it is behind a router or NAT)"}}'; exit 7; fi ;;
  "agent send "*) { cat; printf '\n'; } >>"$CLI_LOG" ;;
esac
exit 0
SH
chmod +x "$TMP/fake-browser" "$TMP/fake-5dive"

# The asking seat is an agent seat (the chat's name rule) whoever runs this: CI's
# runner is not one, so `id -un` answers for a fixed seat and nothing else changes.
mkdir -p "$TMP/bin"
REAL_ID=$(command -v id)
printf '#!/usr/bin/env bash
[[ "$*" == -un ]] && { echo agent-tester; exit 0; }
exec %q "$@"
' "$REAL_ID" >"$TMP/bin/id"
chmod +x "$TMP/bin/id"; export PATH="$TMP/bin:$PATH"; hash -r
ME=$(id -un); WHO="${ME#agent-}"
mkdir -p "$TMP/home" "$TMP/connectors" "$TMP/req" "$TMP/profile.d" "$TMP/link"
printf 'API=http://127.0.0.1:%s\nLINKED_AT=2026-10-27T00:00:00Z\n' "$PORT" >"$TMP/chat-only"
printf 'CONNECTORD_TOKEN=box-token-0000\n' >"$TMP/connectord.env"
printf '# 5dive secret https\nhttps://192.0.2.20 {\n\t@viewer path /browser/viewer/*\n}\n' >"$TMP/secret-https.Caddyfile"
printf 'FIVE_DOMAIN=box.example.5dive.ai\n' >"$TMP/hosted.env"
export FIVEDIVE_BROWSER_CONNECT_DIR="$TMP/req" FIVEDIVE_CONNECTOR_DIR="$TMP/connectors"
export FIVEDIVE_BROWSER_CONNECT_HOME="$TMP/home" FIVEDIVE_CONNECTORD_ENV="$TMP/connectord.env"
export FIVEDIVE_PROVISIONING_ENV="$TMP/no-provisioning.env" FIVEDIVE_CHAT_ONLY_MARK="$TMP/chat-only"
export FIVEDIVE_SECRET_HTTPS_CADDYFILE="$TMP/secret-https.Caddyfile" FIVEDIVE_BROWSER_APP_FG=1
export FIVEDIVE_TELEGRAM_API="http://127.0.0.1:$PORT/tg" FIVEDIVE_SHELLD_URL="http://127.0.0.1:9"
export FIVEDIVE_BROWSER_CONNECT_SELF="$TMP/fake-browser" FIVEDIVE_BROWSER_CONNECT_PRIV="$BROWSER"
export FIVEDIVE_BROWSER_ASKS_DIR="$TMP/asks" FIVEDIVE_BROWSER_PROFILE_D="$TMP/profile.d/5dive-browser-asks.sh"
export FIVEDIVE_BROWSER_SAVED_CLI="$TMP/fake-5dive" FIVEDIVE_BROWSER_CONNECT_LOOK_S=20
export FAKE_LOG="$TMP/fake.log" CLI_LOG="$TMP/cli.log"
export FIVEDIVE_BROWSER_LINK_CONF="$TMP/link/browser-link.env" FIVEDIVE_BROWSER_LINK_STATE="$TMP/link/state"
export FIVEDIVE_BROWSER_LINK_LIB="$TMP/link/lib" FIVEDIVE_BROWSER_LINK_SYSTEMD_DIR="$TMP/link/systemd"
links_on()  { printf 'LINK_MODE=ip\nLINK_HOST=192.0.2.10\nLINK_PORT=3111\n' >"$FIVEDIVE_BROWSER_LINK_CONF"; }
links_off() { rm -f "$FIVEDIVE_BROWSER_LINK_CONF"; }
reset() {
  : >"$FAKE_LOG"; : >"$CLI_LOG"; : >"$TMP/api.log"; rm -f "$TMP/api.status"
  rm -rf "${TMP:?}/req" "${TMP:?}/asks" "${TMP:?}/link/state"; mkdir -p "$TMP/req"
  unset HTTPS_HOST AUTO_HOST
}
priv() { printf '%s\0' "$@" | "$BROWSER" _connect; }
posts() { jq -c 'select(.path == "/server/messages/event")' "$TMP/api.log" 2>/dev/null; }
post_body() { posts | tail -1 | jq -r '.body'; }
AAAA=$(printf 'a%.0s' $(seq 64))

# ---- A: linked, login links on ---------------------------------------------------
links_on; reset
out=$("$BROWSER" connect-request booking.com --reason="to check this week's orders" 2>&1); rc=$?
t  "A1 connect-request on a linked box exits 0" 0 "$rc"
tc "A1 ... and says the owner was asked in the app chat" "asked the owner in your chat in the 5dive app" "$out"
tc "A1 ... names the next step" "5dive browser connect-done booking.com" "$out"
tn "A1 ... with no link in it" "/browser/viewer/" "$out"
t  "A2 exactly one message was posted" 1 "$(posts | wc -l)"
t  "A2 ... with the box token" "Bearer box-token-0000" "$(posts | jq -r .auth)"
B=$(post_body)
t  "A2 ... as this agent" "$WHO" "$(jq -r .agent <<<"$B")"
tc "A2 ... asking for a login on the site" "$WHO asks you to log in to booking.com in the browser on your server." "$(jq -r .body <<<"$B")"
tc "A2 ... with the reason" "Why: to check this week's orders" "$(jq -r .body <<<"$B")"
tn "A2 ... and no link in the text (a push shows the text)" "https://" "$(jq -r .body <<<"$B")"
t  "A3 the link is the box's own viewer, on its own host" "https://192.0.2.10/browser/viewer/booking.com/$AAAA" "$(jq -r .metadata.link.url <<<"$B")"
t  "A3 ... labelled Connect <site>" "Connect booking.com" "$(jq -r .metadata.link.label <<<"$B")"
t  "A3 ... with Done and Not now under it" "Done|Not now" "$(jq -r '[.metadata.question.options[].label] | join("|")' <<<"$B")"
t  "A3 ... as a question the app can draw" "browser-done-booking.com" "$(jq -r .metadata.question.id <<<"$B")"
tc "A4 the box browser was served for a person" "serve booking.com --login" "$(cat "$FAKE_LOG")"
tc "A4 ... and the view lasts 30 minutes" "--ttl=1800" "$(grep '^viewer booking.com' "$FAKE_LOG")"
t  "A4 the bind went to the login-link server" yes "$([[ -s "$TMP/link/state/binds/booking.com" ]] && echo yes || echo no)"
t  "A4 no request code is left live (it was tapped at once)" 1 "$(ls "$TMP/req" | grep -cE '^[0-9a-f]{64}$')"
t  "A4 the body file is gone" "" "$(ls -a "$TMP/req" | grep app-post)"
t  "A4 nothing waits in the login shell" "" "$(ls "$TMP/asks" 2>/dev/null)"
REC="$TMP/req/app/$ME.booking.com"
t  "A5 root's record of the open ask is 0600" 600 "$(stat -c %a "$REC" 2>/dev/null)"
DONE=$(sed -n 's/^done=//p' "$REC")

# K: the done code is the app path's alone.
out=$(priv done "$DONE" 1234567890 2>&1); rc=$?
t  "K1 a Telegram Done tap cannot claim it" 77 "$rc"
tc "K1 ... saying where it waits" "waits in the owner's 5dive app chat" "$out"
out=$(priv done "$DONE" app 2>&1); rc=$?
t  "K2 the agent's own _connect cannot claim it as 'app'" 77 "$rc"
out=$(priv done "$DONE" shell 2>&1); rc=$?
t  "K3 ... nor as 'shell'" 77 "$rc"
t  "K3 ... and the record is still there for connect-done" yes "$([[ -f "$REC" ]] && echo yes || echo no)"

# D: the owner tapped Done; the agent runs connect-done.
: >"$FAKE_LOG"
out=$("$BROWSER" connect-done booking.com 2>&1); rc=$?
t  "D1 connect-done exits 0" 0 "$rc"
tc "D1 ... with the verdict" "booking.com is connected: booking.com authenticated" "$out"
t  "D1 it revokes, stops, then probes" "viewer-revoke booking.com|serve booking.com --stop|status booking.com" "$(tr '\n' '|' <"$FAKE_LOG" | sed 's/|$//')"
t  "D2 nothing is left: no record, no code" "" "$(ls "$TMP/req" "$TMP/req/app" 2>/dev/null | grep -E '[0-9a-f]{64}|booking')"
out=$("$BROWSER" connect-done booking.com 2>&1); rc=$?
t  "D3 a second connect-done is refused" 64 "$rc"
tc "D3 ... in plain words" "nothing of yours waits on booking.com" "$out"
out=$("$BROWSER" connect-done 'x y' 2>&1); rc=$?
t  "D4 a bad site is refused before root is asked" 64 "$rc"

# ---- C: --challenge ----------------------------------------------------------------
reset
PAGE="https://futuretools.io/tools/x"
out=$("$BROWSER" connect-request futuretools.io --challenge --url="$PAGE" --reason="finding the tool page" 2>&1); rc=$?
t  "C1 connect-request --challenge on a linked box exits 0" 0 "$rc"
B=$(post_body)
tc "C1 ... the message names the check" "$WHO is stuck on a check on futuretools.io" "$(jq -r .body <<<"$B")"
t  "C1 ... the link says Open" "Open futuretools.io" "$(jq -r .metadata.link.label <<<"$B")"
t  "C2 the page was looked at first, then served on it" "snapshot $PAGE --json --no-shot|serve futuretools.io --login --url=$PAGE" "$(grep -E '^(snapshot|serve)' "$FAKE_LOG" | tr '\n' '|' | sed 's/|$//')"
: >"$FAKE_LOG"
out=$("$BROWSER" connect-done futuretools.io 2>&1); rc=$?
t  "C3 connect-done on a check exits 0" 0 "$rc"
tc "C3 ... hands the browser back" "browser is back in your hands" "$out"
tc "C3 ... and says the check is still there when it is" "A check is still on the page" "$out"

# ---- B: no login link yet, the box's https front has a name -------------------------
links_off; reset; export HTTPS_HOST=192.0.2.20
out=$("$BROWSER" connect-request booking.com 2>&1); rc=$?
t  "B1 with the box's front up, connect-request exits 0 at once" 0 "$rc"
tc "B1 ... and the owner was asked" "asked the owner in your chat in the 5dive app" "$out"
t  "B2 login links went on behind the box's front" "LINK_MODE=box|LINK_HOST=192.0.2.20|LINK_PORT=3111" "$(grep -E '^LINK_' "$FIVEDIVE_BROWSER_LINK_CONF" 2>/dev/null | tr '\n' '|' | sed 's/|$//')"
t  "B2 ... with no front of its own" "" "$(ls "$TMP/link/systemd" 2>/dev/null | grep tls)"
t  "B3 the link is on the front's name" "https://192.0.2.20/browser/viewer/booking.com/$AAAA" "$(post_body | jq -r .metadata.link.url)"
tn "B3 nothing was set up (no --via=auto)" "enable --via=auto" "$(cat "$CLI_LOG")"
"$BROWSER" connect-done booking.com >/dev/null 2>&1

# ---- F: no front at all: --via=auto first ------------------------------------------
links_off; reset; export AUTO_HOST=192.0.2.30
out=$("$BROWSER" connect-request booking.com 2>&1); rc=$?
t  "F1 with no https yet, connect-request exits 0" 0 "$rc"
tc "F1 ... and says the box sets up its address first" "setting up its secure web address first" "$out"
tc "F2 the box's front was made with --via=auto" "ARGS --json secret https enable --via=auto" "$(cat "$CLI_LOG")"
t  "F2 ... and the link is on the name it made" "https://192.0.2.30/browser/viewer/booking.com/$AAAA" "$(post_body | jq -r .metadata.link.url)"
t  "F2 one message" 1 "$(posts | wc -l)"
"$BROWSER" connect-done booking.com >/dev/null 2>&1

# F3: the set-up runs on after the call returns, through the hangup sudo's
# use_pty sends when its terminal closes (a pty from `script`, the same signal).
if command -v script >/dev/null; then
  links_off; reset; export AUTO_HOST=192.0.2.31 AUTO_SLEEP=2
  t0=$(date +%s)
  script -qec "env -u FIVEDIVE_BROWSER_APP_FG '$BROWSER' connect-request booking.com" /dev/null >"$TMP/f3.out" 2>&1
  t  "F3 the call returns before the set-up is done" yes "$( (( $(date +%s) - t0 < 2 )) && echo yes || echo no )"
  for _ in $(seq 50); do [[ -n "$(posts)" ]] && break; sleep 0.2; done
  t  "F3 ... and the link still arrives after the terminal hung up" "https://192.0.2.31/browser/viewer/booking.com/$AAAA" "$(post_body | jq -r .metadata.link.url 2>/dev/null)"
  unset AUTO_SLEEP
  "$BROWSER" connect-done booking.com >/dev/null 2>&1
else
  echo "skip: F3 (no script(1) for a pty)"
fi

# ---- N: no https possible ------------------------------------------------------------
links_off; reset
out=$("$BROWSER" connect-request booking.com --reason="orders" 2>&1); rc=$?
t  "N1 behind a router, connect-request still exits 0" 0 "$rc"
B=$(post_body)
tc "N2 the chat says so in one line, with the reason" "Your server has no secure web address for a link (no https name on this box: this box has no public IPv4 address" "$(jq -r .body <<<"$B")"
tc "N2 ... and gives the login-shell path" "log in to your server and run: sudo 5dive browser asks" "$(jq -r .body <<<"$B")"
t  "N2 ... with no link at all" "{}" "$(jq -c .metadata <<<"$B")"
t  "N3 the ask waits in the login shell" yes "$([[ -f "$TMP/asks/$ME.booking.com.ask" ]] && echo yes || echo no)"
tc "N4 the agent is told" "[browser connect] No Connect link could be sent for booking.com" "$(cat "$CLI_LOG")"
tc "N4 ... by name" "ARGS agent send $WHO --message-file=-" "$(cat "$CLI_LOG")"

# ---- R: the API refuses the message ----------------------------------------------------
links_on; reset; echo 500 >"$TMP/api.status"
out=$("$BROWSER" connect-request booking.com 2>&1); rc=$?
t  "R1 the API refusing does not fail the agent's call" 0 "$rc"
tc "R1 ... it says the ask waits in the login shell" "the ask waits in the owner's login shell" "$out"
tc "R2 the view it opened was revoked" "viewer-revoke booking.com" "$(cat "$FAKE_LOG")"
t  "R2 no app record or done code is left" "" "$(ls "$TMP/req/app" 2>/dev/null)"
t  "R3 the ask waits in the shell" yes "$([[ -f "$TMP/asks/$ME.booking.com.ask" ]] && echo yes || echo no)"

# ---- O: order and negative controls ---------------------------------------------------
# Telegram paired AND linked: the app chat, and no Telegram message.
links_on; reset
mkdir -p "$TMP/home/.claude/channels/telegram"
printf '{"allowFrom":["1234567890"],"owners":["1234567890"]}\n' >"$TMP/home/.claude/channels/telegram/access.json"
printf 'TELEGRAM_BOT_TOKEN=000:fake\n' >"$TMP/connectors/telegram-$WHO.env"
out=$("$BROWSER" connect-request booking.com 2>&1); rc=$?
t  "O1 paired on Telegram and linked: the app chat first" "0 1" "$rc $(posts | wc -l)"
t  "O1 ... and no Telegram message" 0 "$(grep -c '/tg/' "$TMP/api.log")"
"$BROWSER" connect-done booking.com >/dev/null 2>&1
# Not linked (no marker): Telegram, as before.
reset; export FIVEDIVE_CHAT_ONLY_MARK="$TMP/no-marker"
out=$("$BROWSER" connect-request booking.com 2>&1); rc=$?
t  "O2 not linked, paired: Telegram as before, nothing posted to the app" "0 0" "$rc $(posts | wc -l)"
tc "O2 ... a Telegram sendMessage" "/tg/bot000:fake/sendMessage" "$(cat "$TMP/api.log")"
rm -rf "$TMP/home/.claude" "$TMP/connectors/telegram-$WHO.env"
# Not linked, nobody paired: the login shell (DIVE-7078).
reset
out=$("$BROWSER" connect-request booking.com 2>&1); rc=$?
t  "O3 not linked, nobody paired: the login shell, nothing posted" "0 0" "$rc $(posts | wc -l)"
tc "O3 ... in DIVE-7078's words" "asked in their login shell on this box" "$out"
# Linked, but no box token: not linked.
reset; export FIVEDIVE_CHAT_ONLY_MARK="$TMP/chat-only" FIVEDIVE_CONNECTORD_ENV="$TMP/no-connectord.env"
out=$("$BROWSER" connect-request booking.com 2>&1); rc=$?
t  "O4 a marker with no box token is not linked" "0 0" "$rc $(posts | wc -l)"
export FIVEDIVE_CONNECTORD_ENV="$TMP/connectord.env"
# A hosted box (FIVE_DOMAIN) with a stray marker never posts.
reset; export FIVEDIVE_PROVISIONING_ENV="$TMP/hosted.env"
out=$("$BROWSER" connect-request booking.com 2>&1); rc=$?
t  "O5 a hosted box never takes the app path" 0 "$(posts | wc -l)"
export FIVEDIVE_PROVISIONING_ENV="$TMP/no-provisioning.env"
# The pre-fix tree on the linked fixture: nothing reaches the app.
if git cat-file -e "$BASE:browser/bin/browser" 2>/dev/null; then
  git show "$BASE:browser/bin/browser" >"$TMP/browser-base"; chmod +x "$TMP/browser-base"
  links_on; reset
  out=$(FIVEDIVE_BROWSER_CONNECT_PRIV="$TMP/browser-base" "$TMP/browser-base" connect-request booking.com 2>&1); rc=$?
  t  "O6 negative control: the pre-fix tree posts nothing to the app" 0 "$(posts | wc -l)"
  tc "O6 ... and sends the owner to the login shell" "asked in their login shell on this box" "$out"
else
  echo "skip: O6 (base $BASE not in this checkout)"
fi

printf '\nbrowser_connect_app_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
