#!/usr/bin/env bash
# DIVE-6219 — the opt-in login link for a SELF-HOSTED box, and the hosted box it
# must never touch.
#
#   M  a box WITH FIVE_DOMAIN (a hosted box): the link host is FIVE_DOMAIN, the bind
#      goes to shelld, the option is never shown and cannot be turned on — even
#      with a login-link config planted on it (lodar: "dont break what works")
#   O  a self-hosted box with the option OFF: the tap still refuses, as before
#   N  the same box with it ON: the link host is the chosen name, the bind goes to
#      the box's own login-link server, and shelld is never called
#   E  `login-link enable`: the choices, the hosts each one makes, the HTTPS front's
#      config (viewer paths only, 404 for the rest, no admin), NAT, no Cloudflare
#   S  the login-link server itself, over loopback: page / redeem / websocket /
#      assets / 404, against a fake viewer-redeem and a fake websocket bridge
# Run unprivileged: every seam is honoured only without root.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
SERVER="$ROOT/browser/lib/login-link-server.py"
TMP=$(mktemp -d)
PIDS=()
trap 'rc=$?; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }
tn() { if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected NOT to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }

command -v jq >/dev/null && command -v python3 >/dev/null && command -v curl >/dev/null \
  || { echo "SKIP: needs jq, python3 and curl"; exit 1; }
waitport() { for _ in $(seq 50); do [[ -s "$1" ]] && break; sleep 0.1; done; cat "$1"; }

# ---- stubs: Telegram + shelld (one loopback server), and the relay seat's verbs ----
cat >"$TMP/stub.py" <<'PY'
import http.server, json, sys, urllib.parse
LOG = sys.argv[1]; PORTF = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('content-length') or 0)).decode()
        rec = {'path': self.path, 'body': body}
        if self.path.startswith('/bot'):
            rec['form'] = {k: v[0] for k, v in urllib.parse.parse_qs(body).items()}
        open(LOG, 'a').write(json.dumps(rec) + '\n')
        b = json.dumps({'ok': True, 'result': {'message_id': 7}}).encode()
        self.send_response(200); self.send_header('content-length', str(len(b))); self.end_headers(); self.wfile.write(b)
s = http.server.HTTPServer(('127.0.0.1', 0), H)
open(PORTF, 'w').write(str(s.server_port)); s.serve_forever()
PY
python3 "$TMP/stub.py" "$TMP/stub.log" "$TMP/stub.port" & PIDS+=($!)
PORT=$(waitport "$TMP/stub.port")

cat >"$TMP/fake-browser" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG"
case "$1" in
  viewer)
    printf '/browser/viewer/%s/%s\n' "$2" "$(printf 'a%.0s' $(seq 64))"
    echo "one-time, expires 2099-01-01T00:00:00Z, bound to session ${3#--bind=}. Redeeming it consumes it." >&2
    [[ "$3" == --bind=local ]] \
      && echo "local view: VNC on 127.0.0.1:5917 of this box only, one connection; its one-time password: sudo cat /var/lib/5dive/browser-profiles/agent-clicker/$2/.5dive-viewer.pw" >&2 ;;
esac
exit 0
SH
chmod +x "$TMP/fake-browser"

ME=$(id -un); OWNER=1234567890
mkdir -p "$TMP/home/.claude/channels/telegram" "$TMP/connectors" "$TMP/req"
printf '{"dmPolicy":"allowlist","allowFrom":["%s"],"groups":{}}\n' "$OWNER" >"$TMP/home/.claude/channels/telegram/access.json"
printf 'TELEGRAM_BOT_TOKEN=123:SECRETBOTTOKEN\n' >"$TMP/connectors/telegram-${ME#agent-}.env"
printf 'CONNECTORD_TOKEN=connectord-secret-token-0123456789\n' >"$TMP/connectord.env"
printf 'FIVE_DOMAIN=box.example.5dive.ai\n' >"$TMP/hosted.env"

export FIVEDIVE_BROWSER_CONNECT_DIR="$TMP/req" FIVEDIVE_CONNECTOR_DIR="$TMP/connectors"
export FIVEDIVE_BROWSER_CONNECT_HOME="$TMP/home" FIVEDIVE_CONNECTORD_ENV="$TMP/connectord.env"
export FIVEDIVE_SHELLD_URL="http://127.0.0.1:$PORT" FIVEDIVE_TELEGRAM_API="http://127.0.0.1:$PORT"
export FIVEDIVE_BROWSER_CONNECT_SELF="$TMP/fake-browser" FIVEDIVE_BROWSER_CONNECT_PRIV="$BROWSER"
export FAKE_LOG="$TMP/fake.log"
# The login-link seams: this harness's own files, nothing installed or started.
export FIVEDIVE_BROWSER_LINK_CONF="$TMP/link/browser-link.env" FIVEDIVE_BROWSER_LINK_STATE="$TMP/link/state"
export FIVEDIVE_BROWSER_LINK_LIB="$TMP/link/lib" FIVEDIVE_BROWSER_LINK_SYSTEMD_DIR="$TMP/link/systemd"
export FIVEDIVE_BROWSER_LINK_IP=192.0.2.10
mkdir -p "$TMP/link"

priv() { printf '%s\0' "$@" | "$BROWSER" _connect; }
reset() { : >"$TMP/stub.log"; : >"$FAKE_LOG"; rm -rf "$TMP/req"/*; }
binds() { grep -c '"/shell/browser-viewer-bind"' "$TMP/stub.log" 2>/dev/null || true; }
last_code() { jq -r 'select(.path|test("sendMessage")) | .form.reply_markup' "$TMP/stub.log" | tail -1 | jq -r '.inline_keyboard[0][0].callback_data' | sed 's/^bconn://'; }
tap_once() {  # a fresh request and the owner's tap on it; prints the tap's output
  reset
  "$BROWSER" connect-request booking.com --reason="log in" >/dev/null 2>&1
  priv tap "$(last_code)" "$OWNER" 2>&1
}
planted() { printf 'LINK_MODE=sslip\nLINK_HOST=192-0-2-10.sslip.io\nLINK_PORT=3111\n' >"$FIVEDIVE_BROWSER_LINK_CONF"; }
linkhost() { sed -n 's|^url=https://\([^/]*\)/.*|\1|p' <<<"$1"; }

# ---- M: a HOSTED box is byte-for-byte what it was --------------------------------
export FIVEDIVE_PROVISIONING_ENV="$TMP/hosted.env"
planted   # a login-link config on a hosted box must change NOTHING
out=$(tap_once); rc=$?
t  "M1 hosted tap exits 0" 0 "$rc"
t  "M1 THE LINK HOST IS FIVE_DOMAIN, even with a login-link config planted" "box.example.5dive.ai" "$(linkhost "$out")"
t  "M2 the bind went to shelld, exactly once" 1 "$(binds)"
# A hosted box whose relay refuses keeps its exact words: no opt-in hint there.
mv "$TMP/connectord.env" "$TMP/connectord.off"
out=$(tap_once); rc=$?
t  "M1b a hosted refusal is word for word what it was" "69|5dive browser: the box's relay did not accept the login link; nothing was sent" "$rc|$(tail -1 <<<"$out")"
mv "$TMP/connectord.off" "$TMP/connectord.env"
t  "M2 ... and NOT to the login-link server's bind store" "" "$(ls "$TMP/link/state/binds" 2>/dev/null)"
out=$("$BROWSER" login-link status 2>&1); rc=$?
t  "M3 login-link status on a hosted box is one line, exit 0" "0 1" "$rc $(grep -c . <<<"$out")"
tc "M3 ... naming the 5dive domain" "use its 5dive domain (box.example.5dive.ai)" "$out"
tn "M3 ... and NOT offering any choice" "--via" "$out"
out=$("$BROWSER" login-link --help 2>&1)
tn "M4 login-link --help offers nothing on a hosted box" "--via" "$out"
cp "$FIVEDIVE_BROWSER_LINK_CONF" "$TMP/conf.before"
out=$("$BROWSER" login-link enable --via=ip 2>&1); rc=$?
t  "M5 enable is REFUSED on a hosted box" 64 "$rc"
tc "M5 ... saying there is nothing to set up" "nothing to set up. Nothing changed." "$out"
t  "M5 ... and wrote nothing" "" "$(diff "$TMP/conf.before" "$FIVEDIVE_BROWSER_LINK_CONF")"
t  "M5 ... no units" "" "$(ls "$TMP/link/systemd" 2>/dev/null)"
out=$("$BROWSER" --help 2>&1)
tn "M6 the plugin's usage never shows the option on a hosted box" "login-link" "$out"
out=$("$BROWSER" login-link disable 2>&1); rc=$?
t  "M7 disable is refused too (the option does not exist here)" 64 "$rc"
rm -f "$FIVEDIVE_BROWSER_LINK_CONF"

# ---- O: a self-hosted box, option OFF: refuses as before -------------------------
export FIVEDIVE_PROVISIONING_ENV="$TMP/no-provisioning.env"
out=$(tap_once); rc=$?
t  "O1 the tap refuses as it always did" 69 "$rc"
tc "O1 ... with the same words" "the box's relay did not accept the login link; nothing was sent" "$out"
tn "O1 ... and sends no link" "url=" "$out"
tc "O1 ... and names the opt-in, on a self-hosted box only" "its owner can turn them on: sudo 5dive browser login-link" "$out"
t  "O2 the viewer was revoked" "viewer-revoke booking.com" "$(tail -1 "$FAKE_LOG")"
t  "O2 ... and nothing was written for a login-link server" "" "$(ls "$TMP/link/state/binds" 2>/dev/null)"
out=$("$BROWSER" login-link status 2>&1)
tc "O3 status says off" "login links: off" "$out"
tc "O3 ... and shows the choices with ip recommended" "--via=ip                    RECOMMENDED" "$out"
tc "O3 ... sslip with its trade-off" "operator could redirect the name and read what" "$out"
tc "O3 ... and why there is no Cloudflare tunnel" "Cloudflare would see every keystroke" "$out"
out=$("$BROWSER" --help 2>&1)
tc "O4 the usage names the opt-in on a self-hosted box" "sudo 5dive browser login-link" "$out"
# A file with no FIVE_DOMAIN line (the half-provisioned box the SSH arm knows) is no front either.
printf 'CONNECTORD_TOKEN=x\n' >"$TMP/half.env"
out=$(FIVEDIVE_PROVISIONING_ENV="$TMP/half.env" "$BROWSER" login-link status 2>&1)
tc "O5 a provisioning file with no domain is self-hosted" "login links: off" "$out"

# ---- E: enable — the choices and what each one builds ----------------------------
out=$("$BROWSER" login-link enable 2>&1); rc=$?
t  "E1 enable with no choice prints the choices and exits 64" 64 "$rc"
tc "E1 ... the choices" "--via=domain --host=<name>" "$out"
t  "E1 ... and turns nothing on" "" "$(ls "$TMP/link/browser-link.env" 2>/dev/null)"
for v in cloudflare tunnel; do
  out=$("$BROWSER" login-link enable --via=$v 2>&1); rc=$?
  t  "E2 --via=$v is refused" 64 "$rc"
done
tc "E2 ... and says why" "Cloudflare ends the TLS" "$out"
out=$(FIVEDIVE_BROWSER_LINK_IP= "$BROWSER" login-link enable --via=ip 2>&1); rc=$?
t  "E3 behind NAT (no public IPv4), --via=ip refuses" 69 "$rc"
tc "E3 ... and names what works there" "Use --via=proxy with Tailscale Funnel" "$out"
out=$("$BROWSER" login-link enable --via=domain 2>&1); rc=$?
t  "E4 --via=domain needs --host" 64 "$rc"
out=$("$BROWSER" login-link enable --via=domain --host='evil.example.com/x' 2>&1); rc=$?
t  "E4 ... a real domain name" 64 "$rc"
out=$("$BROWSER" login-link enable --via=ip --host=x.example.com 2>&1); rc=$?
t  "E4 --via=ip makes its own name; --host is refused" 64 "$rc"

out=$("$BROWSER" login-link enable --via=ip 2>&1); rc=$?
t  "E5 --via=ip turns on" 0 "$rc"
t  "E5 ... the link host is the box's own IP" "LINK_HOST=192.0.2.10" "$(grep '^LINK_HOST=' "$FIVEDIVE_BROWSER_LINK_CONF")"
tc "E5 ... and says no third party is in the path" "no third party is in the login path" "$out"
CF="$TMP/link/state/Caddyfile"
tc "E6 ip: Let's Encrypt's short-lived profile (the only one that issues IP certs)" $'issuer acme {\n\t\t\tprofile shortlived' "$(cat "$CF")"
tc "E6 ip: default_sni, because a client never sends an IP as SNI" $'default_sni 192.0.2.10' "$(cat "$CF")"
caddy_shape() {  # the front serves the viewer paths and 404s everything else, with no admin
  local c; c=$(cat "$CF")
  tc "E7 $1: no admin endpoint" $'\tadmin off' "$c"
  tc "E7 $1: the viewer paths, and only those, go to the local server" $'@viewer path /browser/viewer/*\n\thandle @viewer {\n\t\treverse_proxy 127.0.0.1:3111' "$c"
  tc "E7 $1: everything else is a 404" $'handle {\n\t\trespond 404' "$c"
  t  "E7 $1: exactly one reverse_proxy" 1 "$(grep -c reverse_proxy "$CF")"
  tn "E7 $1: no file server" "file_server" "$c"
}
caddy_shape ip
U="$TMP/link/systemd"
tc "E8 the server unit runs as the box seat, not root" "User=claude" "$(cat "$U/5dive-browser-link.service")"
tc "E8 ... from a copy, not the plugin's upgradable dir" "ExecStart=/usr/bin/python3 -I $TMP/link/lib/login-link-server.py" "$(cat "$U/5dive-browser-link.service")"
t  "E8 ... and the copy is there" 0 "$(cmp -s "$SERVER" "$TMP/link/lib/login-link-server.py"; echo $?)"
tc "E8 the HTTPS unit is caddy's user" $'User=caddy\nGroup=caddy' "$(cat "$U/5dive-browser-link-tls.service")"
tc "E8 ... with no new privileges" "NoNewPrivileges=yes" "$(cat "$U/5dive-browser-link-tls.service")"

out=$("$BROWSER" login-link enable --via=sslip 2>&1); rc=$?
t  "E9 --via=sslip turns on, as <dashed ip>.sslip.io" "0 LINK_HOST=192-0-2-10.sslip.io" "$rc $(grep '^LINK_HOST=' "$FIVEDIVE_BROWSER_LINK_CONF")"
tc "E9 ... and repeats its trade-off" "operator could redirect this name and read a login" "$out"
tn "E9 ... no IP-only profile for a name" "profile shortlived" "$(cat "$CF")"
tn "E9 ... no default_sni for a name" "default_sni" "$(cat "$CF")"
caddy_shape sslip
out=$("$BROWSER" login-link enable --via=domain --host=Box.Example.com 2>&1); rc=$?
t  "E10 --via=domain uses the owner's name, lowercased" "0 LINK_HOST=box.example.com" "$rc $(grep '^LINK_HOST=' "$FIVEDIVE_BROWSER_LINK_CONF")"
tc "E10 ... the front serves that name" "https://box.example.com {" "$(cat "$CF")"
out=$("$BROWSER" login-link enable --via=proxy --host=mybox.tail1234.ts.net --port=3999 2>&1); rc=$?
t  "E11 --via=proxy turns on with the owner's front" "0 LINK_HOST=mybox.tail1234.ts.net" "$rc $(grep '^LINK_HOST=' "$FIVEDIVE_BROWSER_LINK_CONF")"
t  "E11 ... and installs NO front of its own" "no-caddyfile no-tls-unit" "$([[ -e "$CF" ]] && echo caddyfile || echo no-caddyfile) $([[ -e "$U/5dive-browser-link-tls.service" ]] && echo tls-unit || echo no-tls-unit)"
tc "E11 ... it says what the owner's front must forward" "forward /browser/viewer/ (and nothing else) to http://127.0.0.1:3999" "$out"
out=$("$BROWSER" login-link enable --via=ip --port=80 2>&1); rc=$?
t  "E12 a privileged port is refused" 64 "$rc"

# ---- N: the same box, ON: the link is the chosen name ---------------------------
"$BROWSER" login-link enable --via=sslip >/dev/null 2>&1
out=$(tap_once); rc=$?
t  "N1 the tap succeeds on a self-hosted box that opted in" 0 "$rc"
t  "N1 THE LINK HOST IS <ip>.sslip.io" "192-0-2-10.sslip.io" "$(linkhost "$out")"
tc "N1 ... on the viewer path" "url=https://192-0-2-10.sslip.io/browser/viewer/booking.com/" "$out"
t  "N2 shelld is never called" 0 "$(binds)"
vbind=$(grep '^viewer' "$FAKE_LOG" | sed -n 's/.*--bind=\([^ ]*\).*/\1/p')
bf="$TMP/link/state/binds/booking.com"
t  "N3 the bind went to the login-link server's store" "bind=$vbind" "$(grep '^bind=' "$bf")"
t  "N3 ... with the ticket's own expiry" "expires_at=$(date -u -d 2099-01-01T00:00:00Z +%s)" "$(grep '^expires_at=' "$bf")"
t  "N3 ... not world-readable" "" "$(find "$bf" -perm -o=r)"
"$BROWSER" login-link enable --via=ip >/dev/null 2>&1
out=$(tap_once)
t  "N4 with --via=ip the link host is the bare IP" "192.0.2.10" "$(linkhost "$out")"
reset
out=$(priv handoff tiktok.com "sign in" 2>&1); rc=$?
t  "N4b with it on, a handoff sends the Connect button, not SSH steps" "0 Connect tiktok.com" "$rc $(jq -r 'select(.path|test("sendMessage")) | .form.reply_markup' "$TMP/stub.log" | jq -r '.inline_keyboard[0][0].text')"
tn "N4b ... and no SSH steps" "ssh -N -L" "$out"
reset
out=$(FIVEDIVE_BROWSER_CONNECT_HOME="$TMP/nohome" priv handoff tiktok.com "sign in" 2>&1); rc=$?
t  "N4c ... but a seat with no paired owner still gets the SSH steps, printed" "0 0" "$rc $(grep -c sendMessage "$TMP/stub.log")"
tc "N4c ... (the steps)" "ssh -N -L 5900:127.0.0.1:5917" "$out"
out=$("$BROWSER" login-link status 2>&1)
tc "N5 status says on, and where" "login links: on, via ip — https://192.0.2.10/browser/viewer/" "$out"
# Hosted wins, even over a live opt-in: the same box with a FIVE_DOMAIN.
out=$(FIVEDIVE_PROVISIONING_ENV="$TMP/hosted.env" tap_once)
t  "N6 a FIVE_DOMAIN on the box beats an enabled login link" "box.example.5dive.ai 1" "$(linkhost "$out") $(binds)"
out=$("$BROWSER" login-link disable 2>&1); rc=$?
t  "N7 disable turns it off" "0 off" "$rc $([[ -e "$FIVEDIVE_BROWSER_LINK_CONF" ]] && echo on || echo off)"
t  "N7 ... and removes its units and binds" "" "$(ls -A "$U" 2>/dev/null; ls -A "$TMP/link/state/binds" 2>/dev/null)"
out=$(tap_once); rc=$?
t  "N8 after disable the tap refuses again" 69 "$rc"

# ---- S: the server ---------------------------------------------------------------
NONCE=$(printf 'b%.0s' $(seq 64)); BIND=$(printf 'c%.0s' $(seq 32)); SITE=booking.com
LHOST=192-0-2-10.sslip.io
mkdir -p "$TMP/s/binds" "$TMP/s/novnc/core/input"
printf 'export default class RFB {}\n' >"$TMP/s/novnc/core/rfb.js"
# The websocket bridge: answers the upgrade with 101, then echoes.
cat >"$TMP/ws.py" <<'PY'
import socket, sys, threading
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', 0)); s.listen(5)
open(sys.argv[1], 'w').write(str(s.getsockname()[1]))
def h(c):
    d = b''
    while b'\r\n\r\n' not in d:
        x = c.recv(4096)
        if not x: return
        d += x
    open(sys.argv[2], 'ab').write(d.split(b'\r\n\r\n')[0] + b'\n--\n')
    c.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n')
    while True:
        x = c.recv(4096)
        if not x: break
        c.sendall(b'echo:' + x)
while True:
    c, _ = s.accept(); threading.Thread(target=h, args=(c,), daemon=True).start()
PY
python3 "$TMP/ws.py" "$TMP/ws.port" "$TMP/ws.log" & PIDS+=($!)
WSPORT=$(waitport "$TMP/ws.port")
# viewer-redeem, faked: logs argv and stdin, answers like the real one.
cat >"$TMP/redeem" <<SH
#!/usr/bin/env bash
printf 'argv=%s\n' "\$*" >>"$TMP/redeem.log"
IFS= read -r n; printf 'stdin=%s\n' "\$n" >>"$TMP/redeem.log"
[[ -f "$TMP/redeem.refuse" ]] && { echo "browser: that viewer link has already been used (state: consumed)." >&2; exit 77; }
printf 'target=127.0.0.1:%s\npassword=pw-123\n' "$WSPORT"
SH
chmod +x "$TMP/redeem"
LINK_HOST=$LHOST LINK_PORT=0 LINK_PORT_FILE="$TMP/srv.port" LINK_BIND_DIR="$TMP/s/binds" LINK_NOVNC_DIR="$TMP/s/novnc" \
  LINK_REDEEM_CMD="[\"$TMP/redeem\"]" python3 -I "$SERVER" 2>"$TMP/srv.err" & PIDS+=($!)
SP=$(waitport "$TMP/srv.port")
B="http://127.0.0.1:$SP"
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
redeem() { curl -s -X POST -H "origin: https://$LHOST" -H 'x-5dive-viewer: 1' "$@" "$B/browser/viewer/$SITE/$NONCE/redeem"; }

h=$(curl -s -D - -o "$TMP/page.html" "$B/browser/viewer/$SITE/$NONCE")
tc "S1 the link's page answers 200" " 200 " "$h"
tc "S1 ... never cached" "cache-control: no-store" "${h,,}"
tc "S1 ... scripts only from itself" "script-src 'self'" "$h"
tc "S1 ... and loads the page script" "/browser/viewer/assets/page.js" "$(cat "$TMP/page.html")"
t  "S2 GETTING THE PAGE REDEEMS NOTHING (a link preview cannot spend it)" "" "$(cat "$TMP/redeem.log" 2>/dev/null)"
for p in / /shell/browser-viewer-bind /browser/viewer/ "/browser/viewer/$SITE" "/browser/viewer/$SITE/short" /browser/viewer/assets/novnc/../../../../etc/passwd /browser/viewer/assets/novnc/%2e%2e/%2e%2e/etc/passwd; do
  t "S3 404 for $p" 404 "$(code --path-as-is "$B$p")"
done
t  "S3 404 for a POST anywhere else" 404 "$(code -X POST "$B/shell/browser-viewer-bind")"
t  "S4 a redeem with no Origin is refused" 403 "$(code -X POST -H 'x-5dive-viewer: 1' "$B/browser/viewer/$SITE/$NONCE/redeem")"
t  "S4 ... from another origin too" 403 "$(code -X POST -H 'origin: https://evil.example' -H 'x-5dive-viewer: 1' "$B/browser/viewer/$SITE/$NONCE/redeem")"
t  "S4 ... and without the page's header (a plain form post)" 403 "$(code -X POST -H "origin: https://$LHOST" "$B/browser/viewer/$SITE/$NONCE/redeem")"
t  "S4 none of those reached viewer-redeem" "" "$(cat "$TMP/redeem.log" 2>/dev/null)"
t  "S5 no bind registered for the site: 410" 410 "$(redeem -o /dev/null -w '%{http_code}')"
printf 'bind=%s\nexpires_at=%s\n' "$BIND" "$(( $(date +%s) - 5 ))" >"$TMP/s/binds/$SITE"
t  "S5 an expired bind: 410" 410 "$(redeem -o /dev/null -w '%{http_code}')"
t  "S5 ... neither reached viewer-redeem" "" "$(cat "$TMP/redeem.log" 2>/dev/null)"
printf 'bind=%s\nexpires_at=%s\n' "$BIND" "$(( $(date +%s) + 600 ))" >"$TMP/s/binds/$SITE"
j=$(redeem)
t  "S6 the page's redeem answers the VNC password" "pw-123" "$(jq -r .password <<<"$j")"
WS=$(jq -r .ws <<<"$j")
[[ "$WS" =~ ^/browser/viewer/$SITE/$NONCE/ws/[0-9a-f]{64}$ ]]; t "S6 ... and a one-use socket path under the link" 0 $?
t  "S7 viewer-redeem got the site and the REGISTERED bind as the session" "argv=$SITE --nonce=- --session=$BIND" "$(grep '^argv=' "$TMP/redeem.log")"
t  "S7 ... the nonce on stdin" "stdin=$NONCE" "$(grep '^stdin=' "$TMP/redeem.log")"
tn "S7 ... and never in argv" "$NONCE" "$(grep '^argv=' "$TMP/redeem.log")"
ws_try() {  # raw upgrade + one payload; prints what came back
  python3 - "$SP" "$1" <<'PY'
import socket, sys
s = socket.create_connection(('127.0.0.1', int(sys.argv[1])), timeout=5)
s.sendall(('GET %s HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nOrigin: https://x\r\n\r\n' % sys.argv[2]).encode())
d = b''
try:
    while b'\r\n\r\n' not in d:
        x = s.recv(4096)
        if not x: break
        d += x
    if d.startswith(b'HTTP/1.1 101'):
        s.sendall(b'PING')
        rest = d.split(b'\r\n\r\n', 1)[1]
        while len(rest) < 9:
            x = s.recv(4096)
            if not x: break
            rest += x
        print(d.split(b'\r\n')[0].decode(), rest.decode())
    else:
        print(d.split(b'\r\n')[0].decode())
except socket.timeout:
    print('timeout')
PY
}
out=$(ws_try "$WS")
t  "S8 the socket is spliced onto the viewer's own bridge" "HTTP/1.1 101 Switching Protocols echo:PING" "$out"
tn "S8 ... the bridge never sees the browser's Origin" "Origin" "$(cat "$TMP/ws.log")"
out=$(ws_try "$WS")
tc "S9 the socket path is ONE use" "403" "$out"
out=$(ws_try "/browser/viewer/$SITE/$NONCE/ws/$(printf 'd%.0s' $(seq 64))")
tc "S9 ... a made-up token is refused" "403" "$out"
: >"$TMP/redeem.refuse"
j=$(redeem -w '\n%{http_code}')
t  "S10 a refused redeem is a 403" 403 "$(tail -1 <<<"$j")"
tc "S10 ... carrying viewer-redeem's own reason" "already been used" "$(head -1 <<<"$j")"
tn "S10 ... and no password" "password" "$(head -1 <<<"$j")"
t  "S11 the box's noVNC files are served" "200 export default class RFB {}" "$(code "$B/browser/viewer/assets/novnc/core/rfb.js") $(curl -s "$B/browser/viewer/assets/novnc/core/rfb.js")"
tc "S11 ... as javascript" "text/javascript" "$(curl -s -D - -o /dev/null "$B/browser/viewer/assets/novnc/core/rfb.js")"
t  "S11 the page script is served" 200 "$(code "$B/browser/viewer/assets/page.js")"
tn "S12 THE NONCE IS NEVER LOGGED" "$NONCE" "$(cat "$TMP/srv.err")"
tn "S12 ... nor the password" "pw-123" "$(cat "$TMP/srv.err")"
listen=$(ss -Hltn 2>/dev/null | awk '{print $4}' | grep ":$SP\$")
t  "S13 the server listens on loopback only" "127.0.0.1:$SP" "$listen"

# ---- G: the seams are not a door under root --------------------------------------
blk=$(awk '/^if \[\[ \$EUID -ne 0 && -n "\$\{FIVEDIVE_BROWSER_LINK_CONF:-\}" \]\]; then$/{p=1} p{print} p&&/^fi$/{p=0}' "$BROWSER")
for v in FIVEDIVE_BROWSER_LINK_CONF FIVEDIVE_BROWSER_LINK_STATE FIVEDIVE_BROWSER_LINK_LIB FIVEDIVE_BROWSER_LINK_SYSTEMD_DIR; do
  t "G1 $v is read only inside the non-root block" "$(grep -c "$v" "$BROWSER")" "$(grep -c "$v" <<<"$blk")"
done
t  "G2 the IP seam is behind LINK_SEAM" 1 "$(grep -c '(( LINK_SEAM )) && \[\[ -n "${FIVEDIVE_BROWSER_LINK_IP+x}" \]\]' "$BROWSER")"
t  "G3 login-link stays root under sudo (it installs services)" 1 "$(grep -c '|totp|login-link|-h|--help|help|' "$BROWSER")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
