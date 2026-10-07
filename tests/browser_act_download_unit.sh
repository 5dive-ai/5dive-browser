#!/usr/bin/env bash
# DIVE-5751 — a file an act downloads reaches the seat that asked.
#
# Before: `act` clicked an export button, said "done: every step ran", and the
# file stayed a nameless Playwright temp file in the browser owner's 0700 cache
# until the browser closed. Now both step loops save it (lib/downloads.cjs), and
# act moves it into its artifact directory and prints where.
#
#   U  lib/downloads.cjs in node, against fake Download objects
#      U1 safeName: the site's name is untrusted — last segment, no leading dot,
#         no control characters, never empty, -2 on a repeat
#      U2 save(): a finished download is saved under its safe name; a failed one
#         is an entry with the browser's reason; an unfinished one is cancelled
#         at the deadline; one over the cap is dropped and its size given
#      U3 stream(): the chunk lines rebuild the exact bytes across chunks
#   C  `act` through the real bin/browser and the real driver-playwright, with
#      the recording playwright stub from browser_plugin_unit.sh (PWDOWNLOAD)
#      C1 a click that downloads: `downloaded: <path> (<name>, <bytes> bytes)`,
#         the file under the run's artifact dir, 0600 in a 0700 dir, same bytes
#      C2 --json carries `downloads`
#      C3 a name that climbs (../../x) lands inside downloads/, nowhere else
#      C4 a failed download is named on stderr with the reason; the act still
#         reports its steps ran (rc 0) and saves nothing
#      C5 (control) a click that downloads nothing prints no `downloaded:` line
#      M1 MUTANT: the driver's watch removed -> C1's line is gone
#   L  LIVE, where this machine has Chrome and playwright-core (CI installs it):
#      L1 a local page with a download link: `act` clicks it in real Chrome and
#         prints `downloaded:`; the file under the run's artifact dir has the
#         bytes the server sent, readable by the calling seat
#
# The served browser's half (bytes back over the socket) is graded in
# browser_plugin_unit.sh T49, where the served-session fixtures live.
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
LIB="$ROOT/browser/lib/downloads.cjs"

TMP="$(mktemp -d /tmp/d5751.XXXXXX)"
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
arm 'U1a the last segment only, no leading dot' 'evil.sh authorized_keys bashrc' "$(node -e '
const d=require(process.argv[1]); const t=new Set();
console.log([d.safeName("../../evil.sh",t), d.safeName(".ssh/authorized_keys",t), d.safeName("..\\\\..\\\\.bashrc",t)].join(" "))' "$LIB")"
arm 'U1b control characters gone, never empty' 'ab.csv download download-2' "$(node -e '
const d=require(process.argv[1]); const t=new Set();
console.log([d.safeName("a\nb\t.csv",t), d.safeName("..",t), d.safeName("",t)].join(" "))' "$LIB")"
arm 'U1c a repeated name gets -2, -3, the extension kept' 'r.csv r-2.csv r-3.csv' "$(node -e '
const d=require(process.argv[1]); const t=new Set();
console.log([d.safeName("r.csv",t), d.safeName("r.csv",t), d.safeName("r.csv",t)].join(" "))' "$LIB")"
arm 'U1d a very long name is cut under the filesystem limit, extension kept' 'yes .m4a' "$(node -e '
const d=require(process.argv[1]); const n=d.safeName("é".repeat(300)+".m4a",new Set());
console.log((Buffer.byteLength(n)<=200?"yes":"no")+" "+require("path").extname(n))' "$LIB")"

mkdir -p "$TMP/u2"
u2="$(node -e '
const d=require(process.argv[1]), fs=require("fs"), dir=process.argv[2], cancelled=[];
const fake=(o)=>({ suggestedFilename:()=>o.name, failure:async()=>o.fail||null, cancel:async()=>{ cancelled.push(o.name); },
  saveAs:(p)=>o.hang ? new Promise(()=>{}) : o.fail ? Promise.reject(new Error("Download failed")) : Promise.resolve(fs.writeFileSync(p,o.body)) });
const list=[fake({name:"ok.csv",body:"a,b\n"}), fake({name:"bad.m4a",fail:"net::ERR_FAILED"}),
            fake({name:"big.bin",body:Buffer.alloc(2048)}), fake({name:"slow.zip",hang:true})];
d.save({list}, dir, {waitMs:300, maxBytes:1024}).then((r)=>{ console.log(JSON.stringify(r.map(({name,bytes,error})=>({name,bytes,error}))));
  console.log(cancelled.join(",")||"none"); });' "$LIB" "$TMP/u2")"
arm 'U2a a finished download is saved under its name' '4 a,b' "$(jq -r '.[0].bytes' <<<"$(head -1 <<<"$u2")" 2>/dev/null) $(cat "$TMP/u2/ok.csv")"
arm 'U2b a failed one carries the browser'"'"'s reason, and no file' 'yes no' \
  "$(has 'net::ERR_FAILED' "$(jq -r '.[1].error' <<<"$(head -1 <<<"$u2")")") $(ex "$TMP/u2/bad.m4a")"
arm 'U2c one over the cap is dropped, its size given' '2048 yes no' \
  "$(jq -r '.[2].bytes' <<<"$(head -1 <<<"$u2")") $(has 'over the limit an act hands over (1024 bytes' "$(jq -r '.[2].error' <<<"$(head -1 <<<"$u2")")") $(ex "$TMP/u2/big.bin")"
arm 'U2d an unfinished one (only) is cancelled at the deadline, and said so' 'yes slow.zip' \
  "$(has 'still downloading' "$(jq -r '.[3].error' <<<"$(head -1 <<<"$u2")")") $(sed -n 2p <<<"$u2")"

head -c 2000000 /dev/urandom > "$TMP/u3.bin"
node -e '
const d=require(process.argv[1]); const lines=[];
d.stream([{name:"u3.bin", bytes:2000000, file:process.argv[2]}], (l)=>lines.push(l));
process.stdout.write(lines.join(""));' "$LIB" "$TMP/u3.bin" > "$TMP/u3.jsonl"
arm 'U3a stream: one metadata line, then chunk lines' '1 3' \
  "$(jq -s '[.[]|select(.act_download)]|length' "$TMP/u3.jsonl") $(jq -s '[.[]|select(.act_download_chunk)]|length' "$TMP/u3.jsonl")"
arm 'U3b the chunks concatenate into the exact bytes' "$(sha256sum < "$TMP/u3.bin")" \
  "$(jq -r 'select(.act_download_chunk)|.b64' "$TMP/u3.jsonl" | base64 -d | sha256sum)"

# ================================================================ C  act, cold
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
export FIVEDIVE_BROWSER_EXPECT_WAIT_MS=0
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
arm 'C0 (anchor) the stub was extracted, with the downloading click' yes \
  "$(grep -q 'fireDownloads(process.env.PWDOWNLOAD)' "$PWROOT/node_modules/playwright-core/index.js" && echo yes || echo no)"
export NODE_PATH="$PWROOT/node_modules"
export PWREC="$TMP/pw.jsonl"; : > "$PWREC"
export PWWALK="$TMP/walk.json"; printf '{"nodes":[],"marker":"m-1"}' > "$PWWALK"

URL="https://export.test/report"
CLICK='[{"op":"click","selector":"ref=menuitem/Download"}]'

run env PWDOWNLOAD='[{"name":"report.csv","body":"a,b\n1,2\n"}]' "$BROWSER" act "$URL" --steps="$CLICK" --out="$TMP/c1"
arm 'C1a act exits 0' 0 "$RC"
[[ "$RC" == 0 ]] || gha 'C1 act output' "$OUT $ERR"
arm 'C1b it prints downloaded: <path> (<name>, <bytes> bytes)' yes \
  "$(has "downloaded: $TMP/c1/downloads/report.csv (report.csv, 8 bytes)" "$OUT")"
arm 'C1c the file is under the run'"'"'s artifact dir, with the bytes the page sent' "$(printf 'a,b\n1,2\n' | sha256sum)" \
  "$(sha256sum < "$TMP/c1/downloads/report.csv" 2>/dev/null)"
arm 'C1d ...0600, in a 0700 downloads dir, owned by the calling seat' "600 700 $SEAT" \
  "$(stat -c %a "$TMP/c1/downloads/report.csv" 2>/dev/null) $(stat -c %a "$TMP/c1/downloads" 2>/dev/null) $(stat -c %U "$TMP/c1/downloads/report.csv" 2>/dev/null)"
arm 'C1e the verdict line is still there, before it' yes "$(has 'done: every step ran' "$OUT")"
# The default artifact root, no --out: under the seat's .read-artifacts, as the row asks.
run env PWDOWNLOAD='[{"name":"audio.m4a","body":"m4a-bytes"}]' "$BROWSER" act "$URL" --steps="$CLICK"
dl="$(sed -n 's/^downloaded: \(.*\) (audio\.m4a, 9 bytes)$/\1/p' <<<"$OUT")"
arm 'C1f with no --out it lands under the seat'"'"'s .read-artifacts/<site>.<id>/downloads' yes \
  "$([[ "$dl" == "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT/.read-artifacts/"*/downloads/audio.m4a && -r "$dl" ]] && echo yes || echo no)"

run env PWDOWNLOAD='[{"name":"report.csv","body":"x"}]' "$BROWSER" act "$URL" --steps="$CLICK" --out="$TMP/c2" --json
arm 'C2 --json carries downloads: path, name, bytes' "$TMP/c2/downloads/report.csv report.csv 1" \
  "$(jq -r '.downloads[0] | "\(.path) \(.name) \(.bytes)"' <<<"$OUT" 2>/dev/null)"

run env PWDOWNLOAD='[{"name":"../../c3-escaped.sh","body":"echo pwned"}]' "$BROWSER" act "$URL" --steps="$CLICK" --out="$TMP/c3/run"
arm 'C3 a name that climbs lands inside downloads/, and nowhere above it' 'yes no no' \
  "$(ex "$TMP/c3/run/downloads/c3-escaped.sh") $(ex "$TMP/c3/c3-escaped.sh") $(ex "$TMP/c3-escaped.sh")"

run env PWDOWNLOAD='[{"name":"broken.m4a","fail":"net::ERR_CONNECTION_RESET"}]' "$BROWSER" act "$URL" --steps="$CLICK" --out="$TMP/c4"
arm 'C4a a failed download: the steps still ran (rc 0)' 0 "$RC"
arm 'C4b ...it is named on stderr with the browser'"'"'s reason' 'yes yes' \
  "$(has 'downloaded broken.m4a, and it was NOT saved' "$ERR") $(has 'ERR_CONNECTION_RESET' "$ERR")"
arm 'C4c ...and nothing is saved or claimed' 'no no' "$(ex "$TMP/c4/downloads/broken.m4a") $(has 'downloaded:' "$OUT")"

run "$BROWSER" act "$URL" --steps="$CLICK" --out="$TMP/c5"
arm 'C5 (control) a click that downloads nothing: rc 0, no downloaded line, no downloads dir' '0 no no' \
  "$RC $(has 'downloaded:' "$OUT") $(ex "$TMP/c5/downloads")"

# MUTANT: the one-shot loop never watches. A whole copy of the plugin, because the
# script finds its driver and lib/ beside itself.
cp -r "$ROOT/browser" "$TMP/mut1"
sed -i 's/dl = downloads.watch(ctx, page);/dl = null;/' "$TMP/mut1/bin/driver-playwright"
arm 'M1 (anchor) mutant applied' yes "$(cmp -s "$TMP/mut1/bin/driver-playwright" "$ROOT/browser/bin/driver-playwright" && echo no || echo yes)"
run env PWDOWNLOAD='[{"name":"report.csv","body":"a"}]' "$TMP/mut1/bin/browser" act "$URL" --steps="$CLICK" --out="$TMP/m1"
arm 'M1 MUTANT (no watch): the file never reaches the seat (C1 goes red)' 'no no' \
  "$(has 'downloaded:' "$OUT") $(ex "$TMP/m1/downloads/report.csv")"

# ================================================================ L  LIVE
REAL_CHROME="$(PATH="$REALPATH" command -v google-chrome || PATH="$REALPATH" command -v chromium || true)"
PW_OK=no; [[ -d "$ROOT/browser/node_modules/playwright-core" ]] && PW_OK=yes
if [[ -z "$REAL_CHROME" || "$PW_OK" != yes ]]; then
  SKIP=$((SKIP+1)); printf 'SKIP: L live arm — chrome: %s, playwright-core next to the plugin: %s\n' "${REAL_CHROME:-none}" "$PW_OK"
else
  # A page with an Export link the server answers as an attachment, the shape of
  # a real export button: no stable file URL in the page, a name from the header.
  cat > "$TMP/site.cjs" <<'JS'
const http = require('http'), fs = require('fs');
const body = fs.readFileSync(process.argv[2]);
http.createServer((req, res) => {
  if (req.url === '/export') {
    res.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': body.length,
      'content-disposition': 'attachment; filename="quarterly report.csv"' });
    res.end(body); return;
  }
  res.setHeader('content-type', 'text/html');
  res.end('<html><head><title>Reports</title></head><body><h1>Reports</h1><a id="export" href="/export">Export CSV</a></body></html>');
}).listen(0, '127.0.0.1', function () { console.log(this.address().port); });
JS
  head -c 300000 /dev/urandom | base64 > "$TMP/live.csv"
  node "$TMP/site.cjs" "$TMP/live.csv" > "$TMP/port" & _KILL+=($!)
  for _ in $(seq 50); do [[ -s "$TMP/port" ]] && break; sleep 0.1; done
  PORT="$(cat "$TMP/port")"
  run env -u NODE_PATH -u PWWALK -u FIVEDIVE_BROWSER_DRIVER PATH="$REALPATH" FIVEDIVE_BROWSER_RUN_SETTLE_MS=500 \
    "$BROWSER" act "http://localhost:$PORT/" --steps='[{"op":"click","selector":"#export"}]' --out="$TMP/live"
  arm 'L1a act in real Chrome exits 0' 0 "$RC"
  [[ "$RC" == 0 ]] || gha 'L1 act output' "$OUT $ERR"
  arm 'L1b it prints downloaded: with the server'"'"'s filename and size' yes \
    "$(has "downloaded: $TMP/live/downloads/quarterly report.csv (quarterly report.csv, $(stat -c %s "$TMP/live.csv") bytes)" "$OUT")"
  arm 'L1c the file has the bytes the server sent, readable by this seat' "$(sha256sum < "$TMP/live.csv") yes" \
    "$(sha256sum < "$TMP/live/downloads/quarterly report.csv" 2>/dev/null) $([[ -r "$TMP/live/downloads/quarterly report.csv" ]] && echo yes || echo no)"
fi

printf '\n%d pass, %d fail, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
