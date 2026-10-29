#!/usr/bin/env bash
# DIVE-7257 — the viewer for one site of a sign-in group shows THAT site's tab.
#
# lodar, 10-29, chill-gorge: the sign-in link for bing.com showed the Google Play
# console. The sites of a group share one Chrome, bing.com and Play were two tabs
# of it, and nothing brought bing.com's tab forward before the window was shown.
#
#   U  lib/front-tab.cjs against fake pages
#      U1 on-site: the host or one under it, www. either way, never a look-alike
#      U2 pick: the driven tab when it is on the site, else the first on it, else none
#   S  the real bin/session-daemon over its socket, with a several-tab stub
#      S1 Play in front, a bing.com tab behind: `front` brings bing.com forward,
#         opens nothing, navigates nothing
#      S2 the agent's next act lands in that same tab (pageOf follows it)
#      S3 no tab on the site: one new tab on its URL, in front; the others untouched
#      S4 input mode: nothing moves, and it says why (read in the source: it
#         needs a real window)
#      S5 a request with no http(s) url is refused, nothing moves
#   E  end to end: two sites in one group, `viewer-redeem` through the real
#      bin/browser and daemon
#      E1 Play in front -> redeem bing.com -> bing.com's tab is in front; the
#         relay's answer is still exactly target= and password=
#      E2 no bing.com tab -> one new tab on https://bing.com/, in front
#      E3 a site with its own profile (one tab, on the site) reads unchanged
#      E4 the local (SSH) viewer brings the tab forward too, before it prints
#         where to connect
#      N1 control: the pre-fix tree leaves Play in front (skipped where the base
#         commit is not in the checkout)
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
DAEMON="$ROOT/browser/bin/session-daemon"
LIB="$ROOT/browser/lib/front-tab.cjs"
BASE=0dce134   # 5dive-browser main before DIVE-7257
TMP="$(mktemp -d /tmp/d7257.XXXXXX)"   # short: a unix socket path is capped at 108 bytes
_KILL=()
trap 'rc=$?; for p in "${_KILL[@]}"; do kill "$p" 2>/dev/null; done; pkill -f "$TMP/" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0; SKIP=0
arm() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
        else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
yn() { if "$@"; then echo yes; else echo no; fi; }
command -v jq >/dev/null && command -v node >/dev/null || { echo "SKIP: needs jq and node"; exit 1; }

# ================================================================ U  lib
u=$(node -e '
const t = require(process.argv[1]);
const pg = (u, closed) => ({ url: () => u, isClosed: () => !!closed });
const o = {};
o.u1 = [t.onSite("https://www.bing.com/x", "bing.com"), t.onSite("https://bing.com/", "www.bing.com"),
        t.onSite("https://cn.bing.com/", "bing.com"), t.onSite("https://notbing.com/", "bing.com"),
        t.onSite("https://bing.com.evil.test/", "bing.com"), t.onSite("about:blank", "bing.com")].join(" ");
const play = pg("https://play.google.com/console"), b1 = pg("https://www.bing.com/"), b2 = pg("https://bing.com/search"), gone = pg("https://bing.com/", true);
o.u2 = [t.pick([play, b1, b2], "bing.com", play) === b1, t.pick([play, b1, b2], "bing.com", b2) === b2,
        t.pick([play, gone], "bing.com", play) === null, t.pick([gone, b1], "bing.com", gone) === b1].join(" ");
console.log(JSON.stringify(o));' "$LIB")
arm 'U1 on the site: the host, one under it, www. either way; never a look-alike or a blank tab' \
  'true true true false false false' "$(jq -r .u1 <<<"$u")"
arm 'U2 pick: the first tab on the site, the driven one when it is on it, none when only a closed one is' \
  'true true true true' "$(jq -r .u2 <<<"$u")"

# ================================================================ the stub
# Several tabs. PWTABS is the urls the browser opens with, PWFRONT the one in
# front; every page records what it is asked, and PWFRONTFILE is rewritten with
# which tab is in front and where each tab is.
PW="$TMP/pw/node_modules/playwright-core"; mkdir -p "$PW"
printf '{ "name": "playwright-core", "version": "0.0.0-stub", "main": "index.js" }\n' > "$PW/package.json"
cat > "$PW/index.js" <<'PWJS'
const fs = require('fs');
const rec = (o) => { if (process.env.PWREC) fs.appendFileSync(process.env.PWREC, JSON.stringify(o) + '\n'); };
let n = 0; let frontId = null; const pages = [];
const dump = () => { if (process.env.PWFRONTFILE) fs.writeFileSync(process.env.PWFRONTFILE,
  JSON.stringify({ front: frontId, tabs: pages.map((p) => p.url()) }) + '\n'); };
const mk = (url) => {
  const id = n++; let u = url;
  const p = { id, url: () => u, isClosed: () => false, setDefaultTimeout: () => {},
    on: () => {}, off: () => {}, once: () => {},
    goto: async (x) => { rec({ call: 'goto', tab: id, url: x }); u = x; dump(); return null; },
    bringToFront: async () => { rec({ call: 'bringToFront', tab: id }); frontId = id; dump(); },
    waitForLoadState: async () => {}, waitForTimeout: async () => {},
    title: async () => 'tab' + id, content: async () => '<html></html>',
    evaluate: async () => ({ nodes: [], marker: null }), screenshot: async () => Buffer.from('') };
  pages.push(p); return p;
};
for (const u of JSON.parse(process.env.PWTABS || '["about:blank"]')) mk(u);
frontId = Number(process.env.PWFRONT || 0); dump();
const ctx = { pages: () => pages.slice(), on: () => {}, close: async () => {},
  newPage: async () => { const p = mk('about:blank'); rec({ call: 'newPage', tab: p.id }); dump(); return p; } };
module.exports = { chromium: { launchPersistentContext: async () => ctx } };
PWJS
export NODE_PATH="$TMP/pw/node_modules" FIVEDIVE_BROWSER_CHROME=/bin/true FIVEDIVE_BROWSER_HEADLESS=1
PLAY='https://play.google.com/console/u/0/developers'

# start_daemon <daemon> <profile> <sock> <tabs-json> <front> <tag> [--input]
start_daemon() {
  local d="$1" prof="$2" sock="$3" tabs="$4" front="$5" tag="$6"; shift 6
  : > "$TMP/$tag.rec"
  PWTABS="$tabs" PWFRONT="$front" PWREC="$TMP/$tag.rec" PWFRONTFILE="$TMP/$tag.front" \
    node "$d" serve "$prof" "$sock" "$@" > "$TMP/$tag.ready" 2> "$TMP/$tag.err" &
  _KILL+=($!); DPID=$!
  for _ in $(seq 100); do grep -q '^ready' "$TMP/$tag.ready" 2>/dev/null && return 0; sleep 0.05; done
  cat "$TMP/$tag.err" >&2; return 1
}
front_of() { jq -r '.front' "$TMP/$1.front"; }
tabs_of() { jq -r '.tabs | join(" ")' "$TMP/$1.front"; }
calls() { jq -r -s --arg c "$2" '[.[] | select(.call==$c) | (.tab|tostring) + (if .url then "@" + .url else "" end)] | join(" ")' "$TMP/$1.rec"; }

# ================================================================ S  daemon
mkdir -p "$TMP/s1"; chmod 700 "$TMP/s1"
start_daemon "$DAEMON" "$TMP/s1" "$TMP/s1.sock" "[\"$PLAY\",\"https://www.bing.com/\"]" 0 s1 \
  || arm 'S0 the daemon is up on the stub' yes no
o=$(node "$DAEMON" call "$TMP/s1.sock" <<<'{"op":"front","url":"https://bing.com/"}'); rc=$?
arm 'S1 Play in front, a bing.com tab behind: front brings the bing.com tab forward' "0 1" "$rc $(front_of s1)"
arm 'S1 ...opens no tab and navigates none' "|" "$(calls s1 newPage)|$(calls s1 goto)"
arm 'S1 ...and says which tab' '{"host":"bing.com","moved":true,"opened":false,"tab":1}' "$o"
node "$DAEMON" call "$TMP/s1.sock" >/dev/null 2>&1 \
  <<<'{"op":"plan","steps":[{"op":"goto","url":"https://bing.com/search?q=x"}],"args":{},"literal":true,"report":{"tree":false}}'
arm 'S2 the agent'"'"'s next act lands in the tab the person is shown, not in tab 0' \
  "1@https://bing.com/search?q=x" "$(calls s1 goto)"
arm 'S2 ...and the Play tab is left where it was' "$PLAY https://bing.com/search?q=x" "$(tabs_of s1)"

mkdir -p "$TMP/s3"; chmod 700 "$TMP/s3"
start_daemon "$DAEMON" "$TMP/s3" "$TMP/s3.sock" "[\"$PLAY\"]" 0 s3 || arm 'S3 the daemon is up' yes no
o=$(node "$DAEMON" call "$TMP/s3.sock" <<<'{"op":"front","url":"https://bing.com/"}'); rc=$?
arm 'S3 no tab on the site: one new tab, on its url, in front' "0 1 1 1@https://bing.com/" \
  "$rc $(calls s3 newPage) $(front_of s3) $(calls s3 goto)"
arm 'S3 ...the Play tab untouched' "$PLAY https://bing.com/" "$(tabs_of s3)"

# Input mode needs a real window on an X display, so this one is read in the
# source: its branch answers before any page is touched.
arm 'S4 input mode: frontRequest answers moved:false, and why, before it touches a tab' 1 \
  "$(awk '/^async function frontRequest\(/{p=1} p&&/if \(input\) \{ out\(\{ host, moved: false, why: .input mode/{i=NR} p&&/frontTab\.pick\(/{k=NR} p&&/^}/{p=0} END{print (i && k > i) ? 1 : 0}' "$DAEMON")"

o=$(node "$DAEMON" call "$TMP/s1.sock" <<<'{"op":"front","url":"javascript:alert(1)"}' 2>&1); rc=$?
arm 'S5 a front with no http(s) url is refused (nothing ran), nothing moves' "70 1" "$rc $(front_of s1)"

# ================================================================ E  end to end
export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/pr" FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/ad"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/rv" FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli"
export FIVEDIVE_BROWSER_TMP_ROOT="$TMP/tmproot" FIVEDIVE_BROWSER_AUTO_PROPOSE=0
SEAT="$(id -un)"
mkdir -p "$TMP/ad" "$TMP/rv/$SEAT"; chmod 711 "$TMP"

# group <tag> <browser> <daemon> <tabs-json>: bing.com and play.google.com in
# one group, its browser served by <daemon>, a viewer for bing.com minted.
group() {
  local tag="$1" br="$2" dm="$3" tabs="$4" P="$TMP/pr-$1" G
  export FIVEDIVE_BROWSER_PROFILE_ROOT="$P"
  G="$P/$SEAT/.group-main"; mkdir -p "$G"; chmod 711 "$P"; chmod 700 "$P/$SEAT" "$G"
  printf 'Main\n' > "$G/.5dive-group-name"
  ln -s .group-main "$P/$SEAT/bing.com"; ln -s .group-main "$P/$SEAT/play.google.com"
  start_daemon "$dm" "$G" "$TMP/$tag.sock" "$tabs" 0 "$tag" || return 1
  printf 'daemon_pid=%s\nsock=%s\ndisplay=\n' "$DPID" "$TMP/$tag.sock" > "$G/.5dive-serve"
  mint "$G"
}
# A viewer ticket the way `viewer` writes one (its x11vnc stands in as a sleep).
mint() {
  local d="$1"; NONCE=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
  sleep 300 & _KILL+=($!)
  ( umask 077
    printf 'vnc_pid=%s\nws_pid=%s\nport=6080\nvnc_port=5900\n' "$!" "$!" > "$d/.5dive-viewer"
    printf 'pw-%s\n' "$1" | tr -d '/' | head -c 40 > "$d/.5dive-viewer.pw"
    printf 'hash=%s\nexpires_at=%s\nbind=s1\nstate=open\nminted_at=%s\nport=6080\n' \
      "$(printf '%s' "$NONCE" | sha256sum | cut -d' ' -f1)" "$(( $(date -u +%s) + 600 ))" "$(date -u +%s)" > "$d/.5dive-viewer.ticket" )
}
redeem() { printf '%s' "$NONCE" | "$1" viewer-redeem "$2" --nonce=- --session=s1 2>"$TMP/redeem.err"; }

group e1 "$BROWSER" "$DAEMON" "[\"$PLAY\",\"https://www.bing.com/\"]" || arm 'E0 the group browser is up' yes no
o=$(redeem "$BROWSER" bing.com); rc=$?
arm 'E1 two sites in one group, Play in front: the bing.com viewer shows the bing.com tab' "0 1" "$rc $(front_of e1)"
arm 'E1 ...the relay'"'"'s answer is still only target= and password=' "target password" \
  "$(cut -d= -f1 <<<"$o" | tr '\n' ' ' | sed 's/ $//')"
arm 'E1 ...and no tab was opened or navigated' "|" "$(calls e1 newPage)|$(calls e1 goto)"
[[ "$rc" == 0 ]] || cat "$TMP/redeem.err"

group e2 "$BROWSER" "$DAEMON" "[\"$PLAY\"]" || arm 'E2 the group browser is up' yes no
o=$(redeem "$BROWSER" bing.com); rc=$?
arm 'E2 no tab on bing.com: one new tab on https://bing.com/, in front' "0 1 1@https://bing.com/ 1" \
  "$rc $(calls e2 newPage) $(calls e2 goto) $(front_of e2)"

# A site with its own profile: one tab, already on the site.
P="$TMP/pr-e3"; export FIVEDIVE_BROWSER_PROFILE_ROOT="$P"
mkdir -p "$P/$SEAT/bing.com"; chmod 711 "$P"; chmod 700 "$P/$SEAT" "$P/$SEAT/bing.com"
start_daemon "$DAEMON" "$P/$SEAT/bing.com" "$TMP/e3.sock" '["https://www.bing.com/"]' 0 e3
printf 'daemon_pid=%s\nsock=%s\ndisplay=\n' "$DPID" "$TMP/e3.sock" > "$P/$SEAT/bing.com/.5dive-serve"
mint "$P/$SEAT/bing.com"
o=$(redeem "$BROWSER" bing.com); rc=$?
arm 'E3 a site with its own profile reads unchanged: its one tab, nothing opened or navigated' "0 0 https://www.bing.com/ |" \
  "$rc $(front_of e3) $(tabs_of e3) $(calls e3 newPage)|$(calls e3 goto)"

# The SSH way in (asks open with login links off) mints a --bind=local view and
# is never redeemed, so the mint brings the tab forward, before the line that
# says where to connect.
arm 'E4 the local (SSH) viewer brings the site'"'"'s tab forward before it prints where to connect' 1 \
  "$(awk '/^cmd_viewer\(\) \{/{p=1} p&&/if \[\[ "\$bind" == local \]\]/{l=NR} p&&/_viewer_front "\$dir" "\$site"/{f=NR} p&&/local view: VNC on/{v=NR} p&&/^}/{p=0} END{print (l && f > l && v > f) ? 1 : 0}' "$BROWSER")"
arm 'E4 ...and the redeem does it after the ticket is spent, before the relay is answered' 1 \
  "$(awk '/^cmd_viewer_redeem\(\) \{/{p=1} p&&/_viewer_revoke_file "\$dir" consumed/{c=NR} p&&/_viewer_front "\$dir" "\$site"/{f=NR} p&&/printf .target=/{t=NR} p&&/^}/{p=0} END{print (c && f > c && t > f) ? 1 : 0}' "$BROWSER")"

# ================================================================ N  control
if git -C "$ROOT" cat-file -e "$BASE:browser/bin/browser" 2>/dev/null; then
  mkdir -p "$TMP/old"; git -C "$ROOT" archive "$BASE" browser | tar -x -C "$TMP/old"
  group n1 "$TMP/old/browser/bin/browser" "$TMP/old/browser/bin/session-daemon" "[\"$PLAY\",\"https://www.bing.com/\"]" \
    || arm 'N0 the pre-fix group browser is up' yes no
  o=$(redeem "$TMP/old/browser/bin/browser" bing.com); rc=$?
  arm 'N1 control: before the fix, the bing.com viewer is handed over with Play still in front' "0 0" "$rc $(front_of n1)"
else
  SKIP=$((SKIP+1)); echo "SKIP: N1 — base $BASE is not in this checkout"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
