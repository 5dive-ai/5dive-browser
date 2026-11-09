#!/usr/bin/env bash
# DIVE-7725 — THE SPEED GATE. A release that makes every step slower does not
# merge.
#
# Two releases slowed every step on every box and nothing here noticed. A
# 100-task bench found each one days later:
#   1. 1.64.2 .. 1.67.3 (fixed in DIVE-7637): on a site in the seat's Google group,
#      one box offer anywhere in the group meant "no served browser kept", so
#      every act opened a new Chrome. At home a command took 13.6 s, not 5.5 s.
#   2. .. 1.68.1 (fixed in DIVE-7722): on a site the owner joined to the group
#      that has no adapter, every page verb first ran a sign-in check on the
#      site's front page. 1,308 checks in one run; read 12 -> 34 s.
# The light bench passed 12/12 on a build that had bug 1. Its pages were a local
# fixture and Wikipedia, both on the public profile, so neither path ran.
#
# SO THIS RUNS ONE TASK THE WAY A REAL BOX HAS IT, through the real bin/browser,
# the real session daemon and real Chrome:
#   - the seat's Main group holds google.com (the owner's Google sign-in), and
#     this seat offers it to the box (google.com.offered), as every box that ever
#     served Main does;
#   - shop.localhost is a site the owner joined to Main: a link into the group,
#     no adapter, no page-joined note (a person's Connect clears that note);
#   - news.localhost is a site with no login, which a page verb joins to Main.
# Both are a local HTTPS server (Chrome resolves *.localhost to loopback). The
# sign-in check of an adapter-less site loads https://<site>/ and no step does,
# so a GET / in the server's log IS a sign-in check, whatever line printed it.
#
#   step 1  act   shop /home -> list      open + act (may start a browser)
#   step 2  act   shop /list  search      act
#   step 3  act   shop /list?q  item      act
#   step 4  read  shop /item/1            read
#   step 5  act   news /home -> story     act on another site in the group
#   step 6  read  news /story/1           read
#
# IT FAILS, with the reason, if:
#   keep    any step prints "no served browser kept" / "one-off browser", or any
#           step after the first launches Chrome (a shim on PATH logs launches);
#   signin  any step after the first runs a sign-in check (a GET / on the site,
#           or the check's own "the generic check found no sign-in form" line);
#   budget  step 1 takes over SPEED_GATE_FIRST_MS (default 30000) or any other
#           step over SPEED_GATE_STEP_MS (default 8000);
#   broken  any step exits non-zero (a gate that cannot run is red, never skipped).
#
#   bash tests/browser_speed_gate.sh                       this tree's browser/
#   bash tests/browser_speed_gate.sh --tree=<git ref>      that commit's browser/
#   bash tests/browser_speed_gate.sh --tree=<ref> --expect-red=keep|signin|budget
#        a negative control: exit 0 only if that criterion went red.
#
# Needs real Chrome, Xvfb, node, openssl, playwright-core installed next to the
# plugin (npm install --prefix browser) and port 443 open to this user (CI:
# sysctl net.ipv4.ip_unprivileged_port_start=443). CI has all of them. It runs in
# CI only: Chrome must not run on the shared agent host. FIVEDIVE_SPEED_GATE_LOCAL=1
# runs it elsewhere on purpose.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

TREE=""; EXPECT_RED=""
for a in "$@"; do
  case "$a" in
    --tree=*) TREE="${a#--tree=}" ;;
    --expect-red=*) EXPECT_RED="${a#--expect-red=}" ;;
    *) echo "usage: $0 [--tree=<git ref>] [--expect-red=keep|signin|budget]" >&2; exit 64 ;;
  esac
done
[[ -z "$EXPECT_RED" || "$EXPECT_RED" =~ ^(keep|signin|budget)$ ]] || { echo "--expect-red takes keep, signin or budget" >&2; exit 64; }
FIRST_MS="${SPEED_GATE_FIRST_MS:-30000}"
STEP_MS="${SPEED_GATE_STEP_MS:-8000}"

say() { printf '%s\n' "$*"; }
gha() {  # an annotation on the run, so a red gate says why on the PR page
  [[ "${GITHUB_ACTIONS:-}" == true ]] || return 0
  local m="$2"; m="${m//'%'/%25}"; m="${m//$'\r'/%0D}"; m="${m//$'\n'/%0A}"
  printf '::%s title=%s::%s\n' "$1" "speed gate" "$m"
}
# A gate that cannot run is red. Only a deliberate local run may skip.
cannot() {
  say "CANNOT RUN: $*"
  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then gha error "cannot run: $*"; exit 1; fi
  exit 69
}
if [[ "${GITHUB_ACTIONS:-}" != true && "${FIVEDIVE_SPEED_GATE_LOCAL:-}" != 1 ]]; then
  cannot "this starts real Chrome; it runs in CI. FIVEDIVE_SPEED_GATE_LOCAL=1 runs it here on purpose."
fi

REAL_CHROME="$(command -v google-chrome || command -v chromium || true)"
[[ -n "$REAL_CHROME" ]] || cannot "no google-chrome"
REAL_CHROME="$(readlink -f "$REAL_CHROME")"
command -v Xvfb >/dev/null || cannot "no Xvfb (serve needs a display)"
command -v node >/dev/null || cannot "no node"
command -v openssl >/dev/null || cannot "no openssl"
command -v jq >/dev/null || cannot "no jq"
[[ -d "$ROOT/browser/node_modules/playwright-core" ]] || cannot "playwright-core is not installed next to the plugin: npm install --prefix browser"

TMP="$(mktemp -d /tmp/speedgate.XXXXXX)"
chmod 755 "$TMP"
_KILL=()
cleanup() {
  [[ -n "${BROWSER:-}" ]] && for s in shop.localhost news.localhost; do "$BROWSER" serve "$s" --stop >/dev/null 2>&1; done
  local p; for p in "${_KILL[@]}"; do kill "$p" 2>/dev/null; done
  # Everything this run started has $TMP on its command line: Chrome (its profile),
  # the daemon (its socket), Xvfb's auth file. Nothing else on the machine does.
  pkill -f -- "$TMP" 2>/dev/null; sleep 0.5; pkill -9 -f -- "$TMP" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

# ------------------------------------------------------------- the tree graded
LABEL="this tree ($(git rev-parse --short HEAD 2>/dev/null || echo '?'))"
PLUGIN="$ROOT/browser"
if [[ -n "$TREE" ]]; then
  git rev-parse -q --verify "$TREE^{commit}" >/dev/null || cannot "no commit $TREE (CI checks out with fetch-depth: 0)"
  mkdir -p "$TMP/tree"
  git archive "$TREE" browser | tar -x -C "$TMP/tree" || cannot "git archive $TREE failed"
  ln -s "$ROOT/browser/node_modules" "$TMP/tree/browser/node_modules"
  PLUGIN="$TMP/tree/browser"
  LABEL="$TREE ($(git rev-parse --short "$TREE"))"
fi
BROWSER="$PLUGIN/bin/browser"
VERSION="$(jq -r .version "$PLUGIN/.claude-plugin/plugin.json" 2>/dev/null || echo '?')"
say "speed gate: grading $LABEL, browser $VERSION"

# ------------------------------------------------------------- Chrome, counted
# Every launch goes through this shim: bin/browser finds Chrome on PATH and hands
# the same path to the daemon's Playwright. It logs the launch and runs the real
# one, trusting the fixture's own certificate (--ignore-certificate-errors).
SHIMBIN="$TMP/bin"; mkdir -p "$SHIMBIN"
LAUNCHES="$TMP/launches.log"; : > "$LAUNCHES"
cat > "$SHIMBIN/google-chrome" <<SH
#!/usr/bin/env bash
case " \$* " in *" --version "*) exec "$REAL_CHROME" "\$@" ;; esac
t=\${EPOCHREALTIME//[!0-9]/}; printf '%s %s\n' "\$(( t / 1000 ))" "\$*" >> "$LAUNCHES"   # not date +%s%3N (DIVE-7978)
exec "$REAL_CHROME" --ignore-certificate-errors "\$@"
SH
chmod +x "$SHIMBIN/google-chrome"
export PATH="$SHIMBIN:$PATH"

# ------------------------------------------------------------- the fixture site
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=shop.localhost" \
  -addext "subjectAltName=DNS:shop.localhost,DNS:news.localhost,DNS:localhost" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" >/dev/null 2>&1 || cannot "openssl could not make the fixture's certificate"
HITS="$TMP/hits.log"; : > "$HITS"
cat > "$TMP/site.cjs" <<'JS'
const https = require('https'), fs = require('fs');
const [key, cert, log, ready] = process.argv.slice(2);
const page = (title, body) => `<!doctype html><html><head><title>${title}</title></head><body>${body}</body></html>`;
const pages = {
  'shop.localhost': (u) => {
    if (u.pathname === '/') return page('Shop', '<h1>Shop</h1><a href="/home">Enter the shop</a>');
    if (u.pathname === '/home') return page('Shop home', '<h1>Welcome</h1><a id="to-list" href="/list">All products</a>');
    if (u.pathname === '/list') {
      const q = u.searchParams.get('q') || '';
      const rows = q ? `<a id="item-1" href="/item/1">${q} kettle</a> <a id="item-2" href="/item/2">${q} mug</a>` : 'Search to see products.';
      return page('Products', `<h1>Products</h1><form action="/list" method="get"><input id="q" name="q" value="${q}"><button id="go" type="submit">Search</button></form><div id="rows">${rows}</div>`);
    }
    if (u.pathname.startsWith('/item/')) return page('Item', '<h1>Blue kettle</h1><p>Price: 24 EUR. In stock.</p>');
    return null;
  },
  'news.localhost': (u) => {
    if (u.pathname === '/') return page('News', '<h1>News</h1><a href="/home">Front page</a>');
    if (u.pathname === '/home') return page('News home', '<h1>Today</h1><a id="story" href="/story/1">Local bakery wins prize</a>');
    if (u.pathname.startsWith('/story/')) return page('Story', '<h1>Local bakery wins prize</h1><p>The judges liked the rye.</p>');
    return null;
  },
};
const handler = (req, res) => {
  const host = String(req.headers.host || '').replace(/:\d+$/, '');
  const u = new URL(req.url, `https://${host}`);
  fs.appendFileSync(log, `${Date.now()} ${host} ${req.method} ${u.pathname}\n`);
  const html = pages[host] && pages[host](u);
  if (!html) { res.writeHead(404, { 'content-type': 'text/plain' }); res.end('no'); return; }
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }); res.end(html);
};
let up = 0;
for (const h of ['127.0.0.1', '::1']) {
  https.createServer({ key: fs.readFileSync(key), cert: fs.readFileSync(cert) }, handler)
    .on('error', (e) => { console.error(`${h}: ${e.message}`); if (h === '127.0.0.1') process.exit(1); })
    .listen(443, h, () => { if (++up === 1) fs.writeFileSync(ready, 'up'); });
}
JS
node "$TMP/site.cjs" "$TMP/key.pem" "$TMP/cert.pem" "$HITS" "$TMP/site.ready" 2>"$TMP/site.err" & _KILL+=($!)
for _ in $(seq 1 50); do [[ -s "$TMP/site.ready" ]] && break; sleep 0.1; done
[[ -s "$TMP/site.ready" ]] || cannot "the fixture site did not listen on 443 ($(head -c 300 "$TMP/site.err")). CI: sudo sysctl -w net.ipv4.ip_unprivileged_port_start=443"
[[ "$(curl -sk --resolve shop.localhost:443:127.0.0.1 https://shop.localhost/home -o /dev/null -w '%{http_code}')" == 200 ]] \
  || cannot "the fixture site does not answer"
: > "$HITS"

# ------------------------------------------------------------- the box's state
SEAT="$(id -un)"
PR="$TMP/profiles"; RV="$TMP/rv"
export FIVEDIVE_BROWSER_PROFILE_ROOT="$PR" FIVEDIVE_BROWSER_SESSION_ROOT="$RV"
export FIVEDIVE_BROWSER_BOX_SEAT="$SEAT" FIVEDIVE_BROWSER_SEAT="$SEAT"
export FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/adapters"           # no adapter for either site
export FIVEDIVE_BROWSER_TMP_ROOT="$TMP/tmproot"
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli"
export FIVEDIVE_BROWSER_APPROVAL_DIR="$TMP/approvals" FIVEDIVE_BROWSER_APPROVAL_POLICY="$TMP/policy.json"
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0
export STATE_DIR="$TMP/state"
unset FIVEDIVE_BROWSER_NO_DAEMON FIVEDIVE_BROWSER_DRIVER FIVEDIVE_BROWSER_SESSION_DAEMON NODE_PATH
mkdir -p "$PR/$SEAT/.group-main" "$RV/$SEAT" "$FIVEDIVE_BROWSER_ADAPTER_DIR" "$FIVEDIVE_BROWSER_TMP_ROOT" "$FIVEDIVE_BROWSER_APPROVAL_DIR" "$STATE_DIR"
chmod 711 "$PR" "$RV"; chmod 700 "$PR/$SEAT" "$PR/$SEAT/.group-main"; chmod 710 "$RV/$SEAT"
printf 'Main\n' > "$PR/$SEAT/.group-main/.5dive-group-name"
ln -s .group-main "$PR/$SEAT/google.com"        # the owner's Google sign-in lives in Main
ln -s .group-main "$PR/$SEAT/shop.localhost"    # joined by the owner: no page-joined note
( umask 037; printf 'site=google.com\nowner=%s\n' "$SEAT" > "$RV/$SEAT/google.com.offered" )

# ------------------------------------------------------------- the task
STEPS=(
  "act|https://shop.localhost/home|[{\"op\":\"click\",\"selector\":\"#to-list\"}]"
  "act|https://shop.localhost/list|[{\"op\":\"fill\",\"selector\":\"#q\",\"value\":\"blue\"},{\"op\":\"click\",\"selector\":\"#go\"}]"
  "act|https://shop.localhost/list?q=blue|[{\"op\":\"click\",\"selector\":\"#item-1\"}]"
  "read|https://shop.localhost/item/1|"
  "act|https://news.localhost/home|[{\"op\":\"click\",\"selector\":\"#story\"}]"
  "read|https://news.localhost/story/1|"
)
KEEP_RE='no served browser kept for|runs in a one-off browser|the next act opens the page again'
CHECK_RE='the generic check found no sign-in form'

RED_KEEP=(); RED_SIGNIN=(); RED_BUDGET=(); RED_BROKEN=()
ROWS=()
now_ms() { local t="${EPOCHREALTIME//[!0-9]/}"; echo $(( t / 1000 )); }  # not date +%s%3N: uutils misprints it (DIVE-7978)
i=0
for s in "${STEPS[@]}"; do
  i=$((i+1))
  IFS='|' read -r verb url steps <<<"$s"
  host="${url#https://}"; host="${host%%/*}"
  l0=$(wc -l < "$LAUNCHES"); h0=$(wc -l < "$HITS")
  t0=$(now_ms)
  if [[ "$verb" == act ]]; then
    "$BROWSER" act "$url" --steps="$steps" --out="$TMP/out/$i" >"$TMP/s$i.out" 2>"$TMP/s$i.err"; rc=$?
  else
    "$BROWSER" read "$url" --out="$TMP/out/$i" >"$TMP/s$i.out" 2>"$TMP/s$i.err"; rc=$?
  fi
  ms=$(( $(now_ms) - t0 ))
  launches=$(( $(wc -l < "$LAUNCHES") - l0 ))
  checks=$(tail -n +"$((h0+1))" "$HITS" | awk '$3=="GET" && $4=="/"' | wc -l)
  keepln=$(grep -cE "$KEEP_RE" "$TMP/s$i.err")
  checkln=$(grep -cE "$CHECK_RE" "$TMP/s$i.err")
  why=()
  (( rc == 0 )) || { RED_BROKEN+=("step $i ($verb $url) exited $rc: $(grep -v '^$' "$TMP/s$i.err" | tail -n2 | tr '\n' ' ' | cut -c1-300)"); why+=("exit $rc"); }
  (( keepln > 0 )) && { RED_KEEP+=("step $i ($verb $host): $(grep -m1 -oE "($KEEP_RE).{0,120}" "$TMP/s$i.err")"); why+=("no kept browser"); }
  (( i > 1 && launches > 0 )) && { RED_KEEP+=("step $i ($verb $host) launched Chrome $launches time(s)"); why+=("$launches launch(es)"); }
  if (( i > 1 && (checks > 0 || checkln > 0) )); then
    RED_SIGNIN+=("step $i ($verb $host) ran a sign-in check: $checks GET / on the site, $checkln check line(s)"); why+=("sign-in check")
  fi
  budget=$STEP_MS; (( i == 1 )) && budget=$FIRST_MS
  (( ms > budget )) && { RED_BUDGET+=("step $i ($verb $host) took ${ms} ms, budget ${budget} ms"); why+=("over budget"); }
  ROWS+=("| $i | $verb | ${url#https://} | $ms | $budget | $launches | $checks | ${why[*]:-ok} |")
  if (( ${#why[@]} )); then
    say "--- step $i stderr ($verb $url):"; sed 's/^/    /' "$TMP/s$i.err" | head -40
  fi
done

# ------------------------------------------------------------- the verdict
TABLE=$(printf '| step | verb | page | ms | budget ms | Chrome launches | sign-in checks (GET /) | |\n|---|---|---|---|---|---|---|---|\n'; printf '%s\n' "${ROWS[@]}")
say ""; say "$TABLE"; say ""
crit() {  # <name> <array name>
  local -n arr="$2"
  if (( ${#arr[@]} )); then say "RED: $1"; printf '   %s\n' "${arr[@]}"; return 1; fi
  say "green: $1"; return 0
}
red=()
crit "keep    (no new browser after the first step)" RED_KEEP || red+=(keep)
crit "signin  (no sign-in check after the first step)" RED_SIGNIN || red+=(signin)
crit "budget  (step 1 <= ${FIRST_MS} ms, others <= ${STEP_MS} ms)" RED_BUDGET || red+=(budget)
crit "broken  (every step exits 0)" RED_BROKEN || red+=(broken)

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    printf '### Speed gate: %s, browser %s%s\n\n' "$LABEL" "$VERSION" "${EXPECT_RED:+ (negative control: must be red on $EXPECT_RED)}"
    printf '%s\n\n' "$TABLE"
    printf 'Red: %s\n\n' "${red[*]:-none}"
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [[ -n "$EXPECT_RED" ]]; then
  if [[ " ${red[*]} " == *" $EXPECT_RED "* ]]; then
    say "CONTROL OK: $LABEL is red on $EXPECT_RED, as it must be"; exit 0
  fi
  say "CONTROL FAILED: $LABEL should be red on $EXPECT_RED and is not (red: ${red[*]:-none}). The gate would let this regression through."
  gha error "negative control $LABEL is not red on $EXPECT_RED"
  exit 1
fi
if (( ${#red[@]} )); then
  say "SPEED GATE RED on $LABEL: ${red[*]}. This release slows every step; it does not merge."
  gha error "red on ${red[*]} — see the step table in the job summary"
  exit 1
fi
say "SPEED GATE GREEN on $LABEL"
exit 0
