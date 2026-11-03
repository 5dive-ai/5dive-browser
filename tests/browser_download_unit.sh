#!/usr/bin/env bash
# DIVE-7646 — `browser download <site> <url>` saves the FILE at a URL, and an act
# whose goto lands on a PDF hands it over.
#
# Before: Chrome opens a PDF in its own viewer. `read`/`snapshot` got an empty
# <body>, `shot` a PNG, and an act clicking the viewer's Download button timed out
# after 30 s (the viewer is an extension Playwright cannot drive). Box bug 677: an
# owner's Amazon invoices, wanted as real files. Now the bytes are fetched through
# the profile's own browser context, so its cookies ride along (lib/downloads.cjs).
#
#   U  lib/downloads.cjs in node
#      U1 nameFrom: Content-Disposition filename*= and filename=, else the URL's
#         last segment, decoded
#      U2 isFileResponse: a PDF or an attachment is a file; a page is not
#   S  a local server: the invoice is served ONLY with the cookie /login sets;
#      without it the server redirects to a sign-in page with a password field
#   C  `download` through the real bin/browser and driver, with the recording
#      playwright stub from browser_plugin_unit.sh (its context's request client
#      sends the profile's cookie jar; a bare fetch() would not)
#      C1 with no cookie: exit 75, "got a sign-in page, not a file", nothing saved
#      C2 after a prior page set the cookie: downloaded: <path> (<name>, <bytes>
#         bytes, application/pdf), sha256 = what the server sent, 0600, this seat's,
#         under .read-artifacts/<site>.<id>/downloads/
#      C3 the server's climbing name (../../Rechnung 123.pdf) lands inside downloads/
#      C4 --out=<dir> and --out=<file>; an existing --out file is refused
#      C5 a plain web page, a 404, and a file over the size cap: refused, nothing saved
#      C6 --json carries path, name, bytes, type
#   A  `act` whose goto lands on the PDF: the same downloaded line, the same bytes
#      A1 the navigation's own body
#      A2 a viewer that will not give the body back: fetched again through the context
#   M  MUTANTS
#      M1 lib fetches with a bare fetch() (no cookie jar): C2 goes red
#      M2 the driver's goto never keeps the response: A1 goes red
#   L  LIVE, where this machine has Chrome and playwright-core (CI installs it):
#      L1 in real Chrome an act signs in on one page and its goto lands on the PDF:
#         the downloaded line, with the bytes the server sent
#
# The served browser's half (the bytes back over the socket) is graded in
# browser_plugin_unit.sh T49d-g, where the served-session fixtures live.
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
LIB="$ROOT/browser/lib/downloads.cjs"

TMP="$(mktemp -d /tmp/d7646.XXXXXX)"
_KILL=()
trap 'rc=$?; for p in "${_KILL[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0; SKIP=0
gha() {
  [[ "${GITHUB_ACTIONS:-}" == true ]] || return 0
  local m="$2"; m="${m//'%'/%25}"; m="${m//$'\r'/%0D}"; m="${m//$'\n'/%0A}"
  printf '::error title=%s::%s\n' "${1//[:,]/ }" "$m"
}
arm() {  # arm <name> <expected> <got>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; gha "$1" "expected: $2 got: $3"; fi
}
has() { [[ "$2" == *"$1"* ]] && echo yes || echo no; }
ex() { [[ -e "$1" ]] && echo yes || echo no; }
run() { local o="$TMP/.o" e="$TMP/.e"; "$@" >"$o" 2>"$e"; RC=$?; OUT=$(cat "$o"); ERR=$(cat "$e"); return 0; }

# ================================================================ U  lib
arm 'U1a filename*= wins, percent-decoded' 'Rechnung ä.pdf' "$(node -e '
const d=require(process.argv[1]); console.log(d.nameFrom({"content-disposition":"attachment; filename=\"x.pdf\"; filename*=UTF-8'"''"'Rechnung%20%C3%A4.pdf"},"https://a.test/1"))' "$LIB")"
arm 'U1b filename= quoted and bare' 'a b.pdf c.csv' "$(node -e '
const d=require(process.argv[1]); console.log(d.nameFrom({"content-disposition":"inline; filename=\"a b.pdf\""},"x"), d.nameFrom({"content-disposition":"attachment; filename=c.csv"},"x"))' "$LIB")"
arm 'U1c no header: the URL'"'"'s last segment, decoded, no query' 'inv 1.pdf' "$(node -e '
const d=require(process.argv[1]); console.log(d.nameFrom({},"https://a.test/x/inv%201.pdf?sig=1"))' "$LIB")"
arm 'U2 a PDF or an attachment is a file, a page is not' 'true true false' "$(node -e '
const d=require(process.argv[1]); console.log(d.isFileResponse({"content-type":"application/pdf; q=1"}), d.isFileResponse({"content-type":"text/csv","content-disposition":"attachment"}), d.isFileResponse({"content-type":"text/html"}))' "$LIB")"

# ================================================================ S  the site
cat > "$TMP/site.cjs" <<'JS'
const http = require('http'), fs = require('fs');
const pdf = fs.readFileSync(process.argv[2]), big = Buffer.alloc(2 * 1024 * 1024, 7);
const SID = 'sid=s3cret-7646';
http.createServer((req, res) => {
  const signedIn = String(req.headers.cookie || '').split(/;\s*/).includes(SID);
  if (req.url === '/login') {
    res.writeHead(200, { 'content-type': 'text/html', 'set-cookie': `${SID}; Path=/; Max-Age=3600` });
    res.end('<html><head><title>Your orders</title></head><body><h1>Signed in</h1></body></html>'); return;
  }
  if (req.url === '/inv/invoice-123.pdf') {
    if (!signedIn) { res.writeHead(302, { location: '/ap/signin' }); res.end(); return; }
    res.writeHead(200, { 'content-type': 'application/pdf', 'content-length': pdf.length,
      'content-disposition': 'inline; filename="../../Rechnung 123.pdf"' });
    res.end(pdf); return;
  }
  if (req.url === '/ap/signin') {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end('<html><body><form><input name="email"><input type="password" name="password"></form></body></html>'); return;
  }
  if (req.url === '/page') { res.writeHead(200, { 'content-type': 'text/html' }); res.end('<html><body>hello</body></html>'); return; }
  if (req.url === '/big.bin') { res.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': big.length }); res.end(big); return; }
  res.writeHead(404, { 'content-type': 'text/plain' }); res.end('no');
}).listen(0, '127.0.0.1', function () { console.log(this.address().port); });
JS
{ printf '%%PDF-1.4\n'; head -c 300000 /dev/urandom; printf '\n%%%%EOF\n'; } > "$TMP/invoice.pdf"
node "$TMP/site.cjs" "$TMP/invoice.pdf" > "$TMP/port" & _KILL+=($!)
for _ in $(seq 50); do [[ -s "$TMP/port" ]] && break; sleep 0.1; done
PORT="$(cat "$TMP/port")"
arm 'S0 (anchor) the fixture site is up' yes "$([[ "$PORT" =~ ^[0-9]+$ ]] && echo yes || echo no)"
BASE="http://127.0.0.1:$PORT"
PDFURL="$BASE/inv/invoice-123.pdf"
PDFSUM="$(sha256sum < "$TMP/invoice.pdf")"
PDFLEN="$(stat -c %s "$TMP/invoice.pdf")"
arm 'S1 (anchor) the server hands the invoice over only with the cookie' '302 200' \
  "$(curl -s -o /dev/null -w '%{http_code}' "$PDFURL") $(curl -s -o /dev/null -w '%{http_code}' -H 'Cookie: sid=s3cret-7646' "$PDFURL")"

# ================================================================ C  download, cold
SEAT="$(id -un)"
export FIVEDIVE_BROWSER_TMP_ROOT="$TMP/tmproot"
export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/profiles"
export FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/adapters"; mkdir -p "$FIVEDIVE_BROWSER_ADAPTER_DIR"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/sessions"
export FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/no-session-daemon"
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli"
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
export FIVEDIVE_BROWSER_APPROVAL_DIR="$TMP/approvals" FIVEDIVE_BROWSER_APPROVAL_POLICY="$TMP/policy.json"
export FIVEDIVE_BROWSER_GRANT_UID="$(id -u)" FIVEDIVE_BROWSER_RUN_SETTLE_MS=0 FIVEDIVE_BROWSER_TREE_SETTLE_MS=0
export FIVEDIVE_BROWSER_EXPECT_WAIT_MS=0 FIVEDIVE_BROWSER_PUBLIC_KEEP=0
mkdir -p "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT"
chmod 711 "$FIVEDIVE_BROWSER_PROFILE_ROOT"; chmod 700 "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT"

FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == --version ]] && { echo "Google Chrome 153"; exit 0; }\necho "<html><body>public</body></html>"\n' > "$FAKEBIN/google-chrome"
chmod +x "$FAKEBIN/google-chrome"
REALPATH="$PATH"
export PATH="$FAKEBIN:$PATH"

# THE STUB, from the main suite, so the two cannot grade two different stubs.
PWROOT="$TMP/pw"; mkdir -p "$PWROOT/node_modules/playwright-core"
printf '{ "name": "playwright-core", "version": "0.0.0-stub", "main": "index.js" }\n' > "$PWROOT/node_modules/playwright-core/package.json"
sed -n "/^cat > \"\$PWROOT\/node_modules\/playwright-core\/index.js\" <<'PWJS'$/,/^PWJS$/p" tests/browser_plugin_unit.sh \
  | sed '1d;$d' > "$PWROOT/node_modules/playwright-core/index.js"
arm 'C0 (anchor) the stub was extracted, with the request client that sends the jar' yes \
  "$(grep -q "const request = { get:" "$PWROOT/node_modules/playwright-core/index.js" && echo yes || echo no)"
export NODE_PATH="$PWROOT/node_modules"
export PWREC="$TMP/pw.jsonl"; : > "$PWREC"
export PWWALK="$TMP/walk.json"; printf '{"nodes":[],"marker":"m-1"}' > "$PWWALK"

run "$BROWSER" download "$PDFURL"
arm 'C1a with no cookie the invoice URL gives the sign-in page: exit 75' 75 "$RC"
arm 'C1b ...said in words, and no downloaded line' 'yes no' \
  "$(has 'got a sign-in page, not a file' "$ERR") $(has 'downloaded:' "$OUT")"
arm 'C1c ...and nothing is saved anywhere under the artifacts root' 0 \
  "$(find "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT/.read-artifacts" -type f 2>/dev/null | wc -l)"
arm 'C1d ...it went through the context'"'"'s request client' yes \
  "$(jq -rs --arg u "$PDFURL" 'any(.[]; .call=="request.get" and .url==$u)|if . then "yes" else "no" end' "$PWREC")"

# A PRIOR PAGE SIGNS IN: an act loads /login, whose Set-Cookie lands in the profile.
run env PWGOTO_FETCH=1 "$BROWSER" act "$BASE/login" --steps='[{"op":"wait_for","selector":"h1"}]' --out="$TMP/signin"
arm 'C2 (precondition) the sign-in act ran and the profile now holds the cookie' '0 yes' \
  "$RC $(grep -qx 'sid=s3cret-7646' "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT/_public/.stub-cookies" 2>/dev/null && echo yes || echo no)"
[[ "$RC" == 0 ]] || gha 'C2 sign-in act output' "$OUT $ERR"
run "$BROWSER" download "$PDFURL"
arm 'C2a with the cookie: exit 0' 0 "$RC"
[[ "$RC" == 0 ]] || gha 'C2 download output' "$OUT $ERR"
dl="$(sed -n "s/^downloaded: \(.*\) (Rechnung 123\.pdf, $PDFLEN bytes, application\/pdf)$/\1/p" <<<"$OUT")"
arm 'C2b it prints downloaded: <path> (<name>, <bytes> bytes, application/pdf)' yes "$([[ -n "$dl" ]] && echo yes || echo no)"
arm 'C2c the file is the bytes the server sent' "$PDFSUM" "$(sha256sum < "$dl" 2>/dev/null)"
arm 'C2d ...0600, owned by the calling seat' "600 $SEAT" "$(stat -c '%a %U' "$dl" 2>/dev/null)"
arm 'C3 under .read-artifacts/<site>.<id>/downloads/, the climbing name kept inside' yes \
  "$([[ "$dl" == "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT/.read-artifacts/_public."*/downloads/"Rechnung 123.pdf" ]] && echo yes || echo no)"

mkdir -p "$TMP/c4"
run "$BROWSER" download "$PDFURL" --out="$TMP/c4"
arm 'C4a --out=<dir>: the file lands in that directory, under its name' "0 $PDFSUM" "$RC $(sha256sum < "$TMP/c4/Rechnung 123.pdf" 2>/dev/null)"
run "$BROWSER" download "$PDFURL" --out="$TMP/c4"
arm 'C4b ...a second one is not overwritten: -2' "0 yes" "$RC $(ex "$TMP/c4/Rechnung 123-2.pdf")"
run "$BROWSER" download "$PDFURL" --out="$TMP/c4/inv-123.pdf"
arm 'C4c --out=<file>: exactly that path, 0600' "0 $PDFSUM 600" \
  "$RC $(sha256sum < "$TMP/c4/inv-123.pdf" 2>/dev/null) $(stat -c %a "$TMP/c4/inv-123.pdf" 2>/dev/null)"
run "$BROWSER" download "$PDFURL" --out="$TMP/c4/inv-123.pdf"
arm 'C4d ...an --out file that exists is refused before anything runs (exit 64), left as it was' "64 $PDFSUM" \
  "$RC $(sha256sum < "$TMP/c4/inv-123.pdf" 2>/dev/null)"

mkdir -p "$TMP/c5"
run "$BROWSER" download "$BASE/page" --out="$TMP/c5"
arm 'C5a a web page where a file was asked for: refused, named as a page, nothing saved' '69 yes 0' \
  "$RC $(has 'got a web page, not a file' "$ERR") $(find "$TMP/c5" -type f | wc -l)"
run "$BROWSER" download "$BASE/gone.pdf" --out="$TMP/c5"
arm 'C5b a 404: refused with the status, nothing saved' '69 yes 0' \
  "$RC $(has 'answered 404' "$ERR") $(find "$TMP/c5" -type f | wc -l)"
run env FIVEDIVE_BROWSER_DOWNLOAD_MAX_MB=1 "$BROWSER" download "$BASE/big.bin" --out="$TMP/c5"
arm 'C5c over the size cap: refused with the size, nothing saved' '69 yes 0' \
  "$RC $(has 'over the 1 MB a download hands over' "$ERR") $(find "$TMP/c5" -type f | wc -l)"

run "$BROWSER" download "$PDFURL" --out="$TMP/c6/" --json
arm 'C6 --json carries path, name, bytes, type (a new --out dir/ with its slash)' "$TMP/c6/Rechnung 123.pdf Rechnung 123.pdf $PDFLEN application/pdf" \
  "$(jq -r '"\(.path) \(.name) \(.bytes) \(.type)"' <<<"$OUT" 2>/dev/null)"

# ================================================================ A  act lands on the PDF
GOTO_PDF="[{\"op\":\"goto\",\"url\":\"$PDFURL\"}]"
run env PWGOTO_FETCH=1 "$BROWSER" act "$BASE/login" --steps="$GOTO_PDF" --out="$TMP/a1"
arm 'A1a an act whose goto lands on the PDF: rc 0' 0 "$RC"
[[ "$RC" == 0 ]] || gha 'A1 act output' "$OUT $ERR"
arm 'A1b ...prints the downloaded line' yes \
  "$(has "downloaded: $TMP/a1/downloads/Rechnung 123.pdf (Rechnung 123.pdf, $PDFLEN bytes, application/pdf)" "$OUT")"
arm 'A1c ...with the bytes the server sent, 0600' "$PDFSUM 600" \
  "$(sha256sum < "$TMP/a1/downloads/Rechnung 123.pdf" 2>/dev/null) $(stat -c %a "$TMP/a1/downloads/Rechnung 123.pdf" 2>/dev/null)"
run env PWGOTO_FETCH=1 PWGOTO_NOBODY=1 "$BROWSER" act "$BASE/login" --steps="$GOTO_PDF" --out="$TMP/a2"
arm 'A2 a viewer that keeps the body: fetched again through the context, same bytes' "0 $PDFSUM" \
  "$RC $(sha256sum < "$TMP/a2/downloads/Rechnung 123.pdf" 2>/dev/null)"
run env PWGOTO_FETCH=1 "$BROWSER" act "$BASE/login" --steps='[{"op":"goto","url":"'"$BASE/page"'"}]' --out="$TMP/a3"
arm 'A3 (control) a goto to a page hands nothing over' '0 no no' "$RC $(has 'downloaded:' "$OUT") $(ex "$TMP/a3/downloads")"

# ================================================================ M  mutants
# A whole copy of the plugin: the script finds its driver and lib/ beside itself.
cp -r "$ROOT/browser" "$TMP/mut1"
sed -i 's|r = await ctx.request.get(url, { timeout, failOnStatusCode: false });|r = await (async () => { const x = await fetch(url); const b = Buffer.from(await x.arrayBuffer()); const h = {}; x.headers.forEach((v, k) => { h[k] = v; }); return { status: () => x.status, headers: () => h, url: () => x.url, body: async () => b }; })();|' \
  "$TMP/mut1/lib/downloads.cjs"
arm 'M1 (anchor) mutant applied' yes "$(cmp -s "$TMP/mut1/lib/downloads.cjs" "$LIB" && echo no || echo yes)"
run "$TMP/mut1/bin/browser" download "$PDFURL" --out="$TMP/m1"
arm 'M1 MUTANT (a bare fetch, no cookie jar): the sign-in page, no file (C2 goes red)' 'no yes no' \
  "$(has 'downloaded:' "$OUT") $(has 'got a sign-in page' "$ERR") $(ex "$TMP/m1/Rechnung 123.pdf")"
cp -r "$ROOT/browser" "$TMP/mut2"
sed -i 's|const kept = await downloads.keepResponse(dl, ctx, resp);|const kept = null;|' "$TMP/mut2/bin/driver-playwright"
arm 'M2 (anchor) mutant applied' yes "$(cmp -s "$TMP/mut2/bin/driver-playwright" "$ROOT/browser/bin/driver-playwright" && echo no || echo yes)"
run env PWGOTO_FETCH=1 "$TMP/mut2/bin/browser" act "$BASE/login" --steps="$GOTO_PDF" --out="$TMP/m2"
arm 'M2 MUTANT (the goto keeps no response): no downloaded line, no file (A1 goes red)' 'no no' \
  "$(has 'downloaded:' "$OUT") $(ex "$TMP/m2/downloads/Rechnung 123.pdf")"

# ================================================================ L  LIVE
REAL_CHROME="$(PATH="$REALPATH" command -v google-chrome || PATH="$REALPATH" command -v chromium || true)"
PW_OK=no; [[ -d "$ROOT/browser/node_modules/playwright-core" ]] && PW_OK=yes
if [[ -z "$REAL_CHROME" || "$PW_OK" != yes ]]; then
  SKIP=$((SKIP+1)); printf 'SKIP: L live arm — chrome: %s, playwright-core next to the plugin: %s\n' "${REAL_CHROME:-none}" "$PW_OK"
else
  # localhost, not 127.0.0.1: the same server, a host Chrome keeps cookies for by name.
  LBASE="http://localhost:$PORT"
  run env -u NODE_PATH -u PWWALK -u FIVEDIVE_BROWSER_DRIVER PATH="$REALPATH" FIVEDIVE_BROWSER_RUN_SETTLE_MS=500 \
    "$BROWSER" act "$LBASE/login" --steps="[{\"op\":\"goto\",\"url\":\"$LBASE/inv/invoice-123.pdf\"}]" --out="$TMP/live"
  arm 'L1a act in real Chrome, signed in by its first page, exits 0' 0 "$RC"
  [[ "$RC" == 0 ]] || gha 'L1 act output' "$OUT $ERR"
  # Chrome may show the PDF in its viewer (the body is kept) or download it (the
  # watch has it, under the server's name): either way the line and the bytes.
  arm 'L1b it prints downloaded: with the server'"'"'s filename and size' yes \
    "$(has "downloaded: $TMP/live/downloads/Rechnung 123.pdf (Rechnung 123.pdf, $PDFLEN bytes" "$OUT")"
  arm 'L1c the file has the bytes the server sent' "$PDFSUM" "$(sha256sum < "$TMP/live/downloads/Rechnung 123.pdf" 2>/dev/null)"
fi

printf '\n%d pass, %d fail, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
