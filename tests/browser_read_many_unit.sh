#!/usr/bin/env bash
# DIVE-6732 — `browser read` is cheaper per job: several pages in one call, loaded side by
# side, and a print that stops at the page's head.
#
# The bench's R1 (three Wikipedia pages) took ~37 s against OpenClaw's 22 s: the agent sent
# three `read`s at once and they came back ~9 s apart, because one profile is one Chrome and
# the lease queued them. And every read printed the whole article (40-110 KB), which every
# later model call of the job read again.
#
# M arms: `read <url> <url> <url>` makes ONE executor call with every page in it, prints the
# pages in order, each with its own artifacts, and finishes in about one page's time. A fake
# executor takes 2 s per page; FIVEDIVE_FAKE_SERIAL=1 makes it load them one after another,
# which is the control that shows the clock arm can fail.
# C arms: a big page prints its front matter, its facts and the head of its text, cut at a
# line with one line naming page.md; --full and page.md on disk keep all of it.
#
# On 1.49.0 (git show 0209f3a:browser/bin/browser) 16 of the 28 fail (M1-M3, M5-M11, M16, C3-C5, C8,
# C11): a second url is "unexpected argument" and a read prints the whole page.md.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
PASS=0; FAIL=0; SKIP=0
t() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
yn() { if grep -qF -- "$1"; then echo yes; else echo no; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
unset BASH_ENV ENV
export FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/no-session-daemon" FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli" \
       FIVEDIVE_BROWSER_WAKE_PRIV="$TMP/no-wake" FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 \
       FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/profiles" FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/adapters" \
       FIVEDIVE_BROWSER_APPROVAL_DIR="$TMP/approvals" FIVEDIVE_BROWSER_STACK=off \
       FIVEDIVE_BROWSER_DRIVER="$TMP/bin/driver" FAKE_LOG="$TMP/driver.log"
mkdir -p "$TMP/bin" "$FIVEDIVE_BROWSER_ADAPTER_DIR" "$TMP/pages"
SEATD="$FIVEDIVE_BROWSER_PROFILE_ROOT/$(id -un)"; mkdir -p "$SEATD"; chmod 700 "$FIVEDIVE_BROWSER_PROFILE_ROOT" "$SEATD"

cat > "$TMP/bin/google-chrome" <<'CHROME'
#!/usr/bin/env bash
# A cold one-url read (--dump-dom <url>): the same pages the executor serves.
u="${*: -1}"; host="${u#*://}"; host="${host%%/*}"
cat "$PAGES/$host.html" 2>/dev/null || echo "<html><body>blank</body></html>"
CHROME
# The executor: one plan per call, logged; every page takes 2 s and is served from
# $TMP/pages/<host>.html. A host named fail.test is a page that does not load.
cat > "$TMP/bin/driver" <<'DRIVER'
#!/usr/bin/env bash
plan=$(cat); printf '%s\n' "$plan" >> "$FAKE_LOG"
n=$(jq '.pages | length' <<<"$plan")
one() {
  local u h; u=$(jq -r --argjson k "$1" '.pages[$k].url' <<<"$plan"); h=$(jq -r --argjson k "$1" '.pages[$k].html' <<<"$plan")
  sleep 2
  local host="${u#*://}"; host="${host%%/*}"
  if [[ "$host" == fail.test ]]; then printf '{"url":"%s","ok":false,"error":"net::ERR_NAME_NOT_RESOLVED"}' "$u" > "$h.res"; return; fi
  cp "$PAGES/$host.html" "$h"; printf '{"url":"%s","ok":true}' "$u" > "$h.res"
}
for ((k = 0; k < n; k++)); do
  if [[ "${FIVEDIVE_FAKE_SERIAL:-0}" == 1 ]]; then one "$k"; else one "$k" & fi
done
wait
jq -s '{pages: ., browser_mode: "headless"}' $(jq -r '.pages[].html + ".res"' <<<"$plan")
for f in $(jq -r '.pages[].html + ".res"' <<<"$plan"); do rm -f "$f"; done
DRIVER
chmod +x "$TMP/bin/google-chrome" "$TMP/bin/driver"
REALPATH="$PATH"
export PATH="$TMP/bin:$PATH" PAGES="$TMP/pages"

for h in a.test b.test c.test; do
  printf '<html><head><title>Page %s</title></head><body><main><article><h1>Page %s</h1><p>This is the article of %s, with enough words in it to be an article that a reader would keep.</p></article></main></body></html>' "$h" "$h" "$h" > "$TMP/pages/$h.html"
done
# A big page: an infobox, then ~40 KB of article.
{
  printf '<html><head><title>Big</title></head><body><main><article><h1>Big</h1>'
  printf '<table class="infobox"><tr><th>Initial release</th><td>8 July 1996</td></tr><tr><th>License</th><td>PostgreSQL License</td></tr></table>'
  for i in $(seq 1 200); do printf '<p>Paragraph %d of the history of the project, long enough to count as real text in the article body here.</p>' "$i"; done
  printf '<p>THE-LAST-LINE of the article.</p></article></main></body></html>'
} > "$TMP/pages/big.test.html"

run() { local t0; t0=$(date +%s%N); OUT=$(bash "$BROWSER" "$@" 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err"); MS=$(( ($(date +%s%N) - t0) / 1000000 )); }

# ---- M: several pages, one call -------------------------------------------------------
: > "$FAKE_LOG"
run read https://a.test/x https://b.test/y https://c.test/z
t 'M1 three urls read in one call exit 0' 0 "$RC"
t 'M2 ...through ONE executor call' 1 "$(wc -l < "$FAKE_LOG")"
t 'M3 ...that carries all three pages' 3 "$(jq '.pages | length' "$FAKE_LOG" 2>/dev/null | head -1)"
t 'M4 three 2 s pages finish well inside the 6 s a line of them takes' yes "$( (( MS < 5000 )) && echo yes || echo "no (${MS} ms)")"
t 'M5 the pages print in the order asked, each under its url' \
  '==> https://a.test/x <== ==> https://b.test/y <== ==> https://c.test/z <==' "$(grep '^==> ' <<<"$OUT" | xargs)"
t 'M6 ...each with its own text' 'yes yes yes' \
  "$(for h in a.test b.test c.test; do yn "This is the article of $h" <<<"$OUT"; done | xargs)"
DIRS=$(grep -o 'artifacts: .*' <<<"$ERR" | cut -d' ' -f2)
t 'M7 ...and its own artifacts directory with page.md in it' '3 3' \
  "$(sort -u <<<"$DIRS" | wc -l) $(for d in $DIRS; do [[ -s "$d/page.md" ]] && echo x; done | wc -l)"
: > "$FAKE_LOG"
FIVEDIVE_FAKE_SERIAL=1 run read https://a.test/x https://b.test/y https://c.test/z
t 'M8 control: pages loaded one after another take the 6 s (the clock in M4 can say no)' yes \
  "$( (( MS >= 6000 )) && echo yes || echo "no (${MS} ms)")"
run read https://a.test/x https://fail.test/y https://c.test/z
t 'M9 a page that does not load fails the call...' 69 "$RC"
t 'M10 ...names itself under its url' yes "$(grep -A1 '^==> https://fail.test/y <==' <<<"$OUT" | yn 'net::ERR_NAME_NOT_RESOLVED')"
t 'M11 ...and the other two are still read' 'yes yes' \
  "$(for h in a.test c.test; do yn "This is the article of $h" <<<"$OUT"; done | xargs)"
t 'M12 ...and it leaves no empty artifacts directory behind' 0 "$(find "$SEATD/.read-artifacts" -mindepth 1 -maxdepth 1 -type d -empty | wc -l)"

run read https://a.test/x https://b.test/y --out="$TMP/o"
t 'M13 --out with several urls is refused' 64 "$RC"
run read https://a.test/1 https://a.test/2 https://a.test/3 https://a.test/4 https://a.test/5 https://a.test/6
t 'M14 more than five urls is refused' 64 "$RC"
mkdir -p "$SEATD/b.test"; chmod 700 "$SEATD/b.test"
run read https://a.test/x https://b.test/y
t 'M15 a url with a login of its own is not read logged out beside public ones' 64 "$RC"
t 'M16 ...and the refusal says to read it on its own' yes "$(yn 'read https://b.test/y' <<<"$ERR")"
rm -rf "$SEATD/b.test"
run links https://a.test/x https://b.test/y
t 'M17 links still takes one url' 64 "$RC"

# ---- C: the print stops at the page's head --------------------------------------------
run read https://big.test/p
t 'C1 a big read exits 0' 0 "$RC"
t 'C2 its facts are printed' 'yes yes' "$(yn '- Initial release: 8 July 1996' <<<"$OUT") $(yn '- License: PostgreSQL License' <<<"$OUT")"
t 'C3 the text is cut: the last line is not printed' no "$(yn 'THE-LAST-LINE' <<<"$OUT")"
t 'C4 the print is held near the budget' yes "$( (( ${#OUT} <= 6600 )) && echo yes || echo "no (${#OUT} chars)")"
D=$(grep -o 'artifacts: .*' <<<"$ERR" | cut -d' ' -f2)
t 'C5 one line says where the rest is' yes "$(yn "The whole page is in $D/page.md" <<<"$OUT")"
t 'C6 page.md on disk has all of it' yes "$(yn 'THE-LAST-LINE' < "$D/page.md")"
t 'C7 the front matter is printed whole' yes "$(head -1 <<<"$OUT" | yn -- '---')"
run read https://big.test/p --full
t 'C8 --full prints all of it' yes "$(yn 'THE-LAST-LINE' <<<"$OUT")"
run read https://a.test/x
D=$(grep -o 'artifacts: .*' <<<"$ERR" | cut -d' ' -f2)
t 'C9 a small page prints exactly its page.md, as before' yes "$([[ "$OUT" == "$(cat "$D/page.md")" ]] && echo yes || echo no)"
run read https://big.test/p https://a.test/x https://b.test/y
t 'C10 several pages share the budget, so three print about what one does' yes \
  "$( (( ${#OUT} <= 6600 + 3 * 600 )) && echo yes || echo "no (${#OUT} chars)")"
t 'C11 ...and the big one still prints its facts' yes "$(yn '- Initial release: 8 July 1996' <<<"$OUT")"

# ---- L: LIVE, where this machine has Chrome and playwright-core (CI installs it) ------
# The real executor and real Chrome against a local server that holds every page for
# 1.5 s and counts how many it is holding at once: three pages in one `read` must be in
# flight together (L2), where three one-url reads are not.
REAL_CHROME="$(PATH="$REALPATH" command -v google-chrome || PATH="$REALPATH" command -v chromium || true)"
PW_OK=no; [[ -d "$ROOT/browser/node_modules/playwright-core" ]] && PW_OK=yes
if [[ -z "$REAL_CHROME" || "$PW_OK" != yes ]]; then
  SKIP=$((SKIP+1)); printf 'SKIP: L live arms — chrome: %s, playwright-core next to the plugin: %s\n' "${REAL_CHROME:-none}" "$PW_OK"
else
  cat > "$TMP/site.cjs" <<'JS'
const http = require('http'), fs = require('fs');
let now = 0, peak = 0;
http.createServer((req, res) => {
  if (req.url === '/peak') { res.end(String(peak)); return; }
  if (req.url === '/reset') { peak = 0; res.end('0'); return; }
  if (!/^\/p[0-9]$/.test(req.url)) { res.statusCode = 404; res.end(); return; }
  now++; peak = Math.max(peak, now);
  setTimeout(() => {
    now--;
    res.setHeader('content-type', 'text/html');
    res.end(`<html><head><title>Live ${req.url}</title></head><body><main><article><h1>Live ${req.url}</h1>` +
      `<p>The live article at ${req.url}, with enough words in it to be an article a reader keeps.</p></article></main></body></html>`);
  }, 1500);
}).listen(0, '127.0.0.1', function () { fs.writeFileSync(process.argv[2], String(this.address().port)); });
JS
  node "$TMP/site.cjs" "$TMP/port" & SITE_PID=$!
  for _ in $(seq 50); do [[ -s "$TMP/port" ]] && break; sleep 0.1; done
  PORT="$(cat "$TMP/port")"; B="http://localhost:$PORT"
  live() { env -u FIVEDIVE_BROWSER_DRIVER PATH="$REALPATH" FIVEDIVE_BROWSER_TREE_SETTLE_MS=200 bash "$BROWSER" "$@"; }
  t0=$(date +%s%N); OUT=$(live read "$B/p1" "$B/p2" "$B/p3" 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err")
  MANY=$(( ($(date +%s%N) - t0) / 1000000 ))
  t 'L1 three pages in real Chrome exit 0' 0 "$RC"
  [[ "$RC" == 0 ]] || printf '%s\n' "$ERR" | tail -5
  t 'L2 ...and the server held all three at once' 3 "$(curl -s "$B/peak")"
  t 'L3 ...each page printed under its url' 'yes yes yes' \
    "$(for k in 1 2 3; do grep -A12 "^==> $B/p$k <==" <<<"$OUT" | yn "The live article at /p$k"; done | xargs)"
  curl -s "$B/reset" >/dev/null
  t0=$(date +%s%N); for k in 1 2 3; do live read "$B/p$k" >/dev/null 2>&1; done
  ONE=$(( ($(date +%s%N) - t0) / 1000000 ))
  t 'L4 control: three one-url reads never hold two pages at once' 1 "$(curl -s "$B/peak")"
  t 'L5 one read of three is faster than three reads of one' yes \
    "$( (( MANY < ONE )) && echo yes || echo "no (${MANY} ms against ${ONE} ms)")"
  printf 'L timing: one read of three %s ms, three reads of one %s ms\n' "$MANY" "$ONE"
  kill "$SITE_PID" 2>/dev/null
fi

printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
