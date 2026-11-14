#!/usr/bin/env bash
# DIVE-8443 — an act whose steps are only page scripts saves nothing of the page.
#
# Box report 970: an owner let his agent read ONE flag per chat (muted or not)
# off his Telegram, and never a muted chat's text. Every act, even one whose only
# step was `eval`, also wrote page.md (the page's text), page.html, tree.json and
# page.png, and a served act printed "what changed": on Telegram's chat list that
# is every chat's last message, muted ones included. So no read-only path existed.
#
# The page here carries a SENTINEL in its text, document, title and refs. A
# read-only act must leave it nowhere: not in --out, not on stdout or stderr.
#
#   C  `act`, cold, through the real bin/browser and driver-playwright on the
#      main suite's recording playwright stub (wrapped with a CDP session that
#      answers Runtime.evaluate)
#      C1 an eval-only act: exit 0, the answer on stdout, no page.md, page.html,
#         tree.json, page.png or after.json in --out, the sentinel absent from
#         stdout and stderr
#      C2 --json: read_only, the answer parsed, no artifacts, no sentinel
#      C3 with no --out: no artifact directory is made, and no file anywhere under
#         the harness's roots holds the sentinel
#      C4 a wait_for before the eval is still read-only; --wait-for becomes that step
#      C5 --expect on an eval-only act is refused before anything runs
#      C6 (control, no regression) the same act with a click step writes page.html,
#         tree.json and page.png, and page.html holds the sentinel
#      C7 --full reads the page: page.html is written again
#      M1 MUTANT: the read-only switch removed -> C1 goes red (the sentinel is in --out)
#   S  the served browser (bin/session-daemon on the main suite's daemon stub)
#      S1 a plan whose report is {bare:true}: one act_report line with the url only,
#         no document, picture or refs lines, no sentinel; the eval answer is logged
#      S2 (control) the same plan with the old report: the sentinel comes back
#   B  bin/browser's half on canned payloads (no daemon)
#      B1 _act_session in a read-only act asks for {bare:true} and no look
#      B2 a served browser older than this one sends the whole page anyway: only
#         {url} lands in the stage, no page.html, page.png or tree.json
#   D  documented: act --help, SKILL.md, references/telegram-web.md
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
DAEMON="$ROOT/browser/bin/session-daemon"

TMP="$(mktemp -d /tmp/d8443.XXXXXX)"
_KILL=()
trap 'rc=$?; for p in "${_KILL[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0
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
run() { local o="$TMP/.o" e="$TMP/.e"; "$@" >"$o" 2>"$e"; RC=$?; OUT=$(cat "$o"); ERR=$(cat "$e"); return 0; }
files() { local d="$1" f r=""; for f in page.md page.html tree.json page.png after.json page.meta.json; do [[ -e "$d/$f" ]] && r+="$f "; done; printf '%s' "${r% }"; }

SENT="SENTINEL-MUTED-PREVIEW-8443"

# A CDP session for the stubs: Runtime.evaluate answers "EVAL:<expression>", the
# rest answers {}. Wraps whichever stub base.js is, cold or served.
cdpwrap() {  # <dir holding base.js>
  cat > "$1/index.js" <<'JS'
const base = require('./base.js');
const cdp = { send: async (m, p) => (m === 'Runtime.evaluate' ? { result: { type: 'string', value: 'EVAL:' + p.expression } } : {}),
  detach: async () => {} };
exports.chromium = {
  launchPersistentContext: async (profile, opts) => {
    const ctx = await base.chromium.launchPersistentContext(profile, opts);
    ctx.newCDPSession = async () => cdp;
    const patch = (p) => { if (p && !p.context) p.context = () => ctx; return p; };
    for (const p of ctx.pages()) patch(p);
    const np = ctx.newPage; ctx.newPage = async () => patch(await np());
    return ctx;
  },
};
JS
}

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
export FIVEDIVE_BROWSER_EXPECT_WAIT_MS=0 FIVEDIVE_BROWSER_POPUP_WAIT_MS=0
export FIVEDIVE_BROWSER_HEADLESS=1
mkdir -p "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT"
chmod 711 "$FIVEDIVE_BROWSER_PROFILE_ROOT"; chmod 700 "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT"
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == --version ]] && { echo "Google Chrome 153"; exit 0; }\necho "<html><body>public</body></html>"\n' > "$FAKEBIN/google-chrome"
chmod +x "$FAKEBIN/google-chrome"
export PATH="$FAKEBIN:$PATH"

PWROOT="$TMP/pw"; mkdir -p "$PWROOT/node_modules/playwright-core"
printf '{ "name": "playwright-core", "version": "0.0.0-stub", "main": "index.js" }\n' > "$PWROOT/node_modules/playwright-core/package.json"
sed -n "/^cat > \"\$PWROOT\/node_modules\/playwright-core\/index.js\" <<'PWJS'$/,/^PWJS$/p" tests/browser_plugin_unit.sh \
  | sed '1d;$d' > "$PWROOT/node_modules/playwright-core/base.js"
arm 'C0 (anchor) the cold stub was extracted from the main suite' yes \
  "$(grep -q 'launchPersistentContext' "$PWROOT/node_modules/playwright-core/base.js" && echo yes || echo no)"
cdpwrap "$PWROOT/node_modules/playwright-core"
export NODE_PATH="$PWROOT/node_modules"
export PWREC="$TMP/pw.jsonl"; : > "$PWREC"
export PWWALK="$TMP/walk.json"
jq -nc --arg s "$SENT" '{nodes:[{ref:("link/" + $s), role:"link", name:$s}], marker:"m-1"}' > "$PWWALK"
export PWTITLE="Chats ($SENT)" PWHTML="<html><body><ul><li>$SENT: see you at 9</li></ul></body></html>" PWTEXT="$SENT: see you at 9"

URL="https://web.telegram.test/k/"
EVAL='[{"op":"eval","expr":"document.title.length"}]'

run "$BROWSER" act "$URL" --steps="$EVAL" --out="$TMP/c1"
arm 'C1a an eval-only act exits 0' 0 "$RC"
[[ "$RC" == 0 ]] || gha 'C1 act output' "$OUT $ERR"
arm 'C1b ...and prints the answer on stdout, and only that' 'step 2 (eval) = "EVAL:document.title.length"' "$OUT"
arm 'C1c ...no page.md, page.html, tree.json, page.png or after.json in --out' '' "$(files "$TMP/c1")"
arm 'C1d ...the sentinel is on neither stdout nor stderr' 'no no' "$(has "$SENT" "$OUT") $(has "$SENT" "$ERR")"
arm 'C1e ...stderr says nothing of the page was saved' yes "$(has 'Read-only: nothing of the page was saved or printed' "$ERR")"
arm 'C1f ...the script did run (the stub saw the goto)' 1 "$(grep -c '"call":"goto"' "$PWREC")"

run "$BROWSER" act "$URL" --steps="$EVAL" --out="$TMP/c2" --json
arm 'C2 --json: read_only, the answer, no artifacts key, no sentinel' 'true|EVAL:document.title.length|false|0|no' \
  "$(jq -r '"\(.read_only)|\(.evals[0].value)|\(has("artifacts"))|\(.executor_rc)"' <<<"$OUT" 2>/dev/null)|$(has "$SENT" "$OUT$ERR")"
arm 'C2b ...and nothing in --out' '' "$(files "$TMP/c2")"

ART="$TMP/home"; mkdir -p "$ART"
run env HOME="$ART" "$BROWSER" act "$URL" --steps="$EVAL"
arm 'C3a with no --out: exit 0, the answer printed' '0 yes' "$RC $(has '(eval) = "EVAL:' "$OUT")"
arm 'C3b ...no artifact directory was made' 0 "$(find "$TMP" -path '*/.read-artifacts/*' -mindepth 1 2>/dev/null | wc -l)"
arm 'C3c ...and no file under the harness roots holds the sentinel' '' \
  "$(grep -rlF "$SENT" "$TMP" 2>/dev/null | grep -v -e "$TMP/pw/" -e "$TMP/walk.json" -e "$TMP/pw.jsonl" -e "$TMP/.o" -e "$TMP/.e" -e "$TMP/served" -e "$TMP/c6" -e "$TMP/c7" | tr '\n' ' ')"

run "$BROWSER" act "$URL" --steps='[{"op":"wait_for","selector":".chatlist"},{"op":"eval","expr":"1"}]' --out="$TMP/c4"
arm 'C4a a wait_for before the eval: still read-only' '0||no' "$RC|$(files "$TMP/c4")|$(has "$SENT" "$OUT$ERR")"
run "$BROWSER" act "$URL" --steps="$EVAL" --wait-for=.chatlist --out="$TMP/c4b"
arm 'C4b --wait-for becomes a wait_for step before the eval' '0|yes|yes|' \
  "$RC|$(has 'step 2 (wait_for) ok' "$ERR")|$(has 'step 3 (eval) = ' "$OUT")|$(files "$TMP/c4b")"

: > "$PWREC"
run "$BROWSER" act "$URL" --steps="$EVAL" --expect='see you' --out="$TMP/c5"
arm 'C5 --expect on an eval-only act is refused (64) before anything runs' '64 yes 0' \
  "$RC $(has 'Check it inside the expression instead' "$ERR") $(grep -c '"call":"goto"' "$PWREC")"

run "$BROWSER" act "$URL" --steps='[{"op":"click","selector":"#chat"},{"op":"eval","expr":"1"}]' --out="$TMP/c6"
arm 'C6a (control) an act with a click still writes the page' 'page.html tree.json page.png after.json' \
  "$(files "$TMP/c6" | sed 's/page.md //; s/ page.meta.json//')"
arm 'C6b ...and page.html holds the sentinel (the fixture really carries it)' yes "$(has "$SENT" "$(cat "$TMP/c6/page.html" 2>/dev/null)")"
arm 'C6c ...page.md is derived from it as before' yes "$([[ -s "$TMP/c6/page.md" ]] && echo yes || echo no)"

run "$BROWSER" act "$URL" --steps="$EVAL" --full --out="$TMP/c7"
arm 'C7 --full on an eval-only act reads the page: page.html is written' yes "$([[ -s "$TMP/c7/page.html" ]] && echo yes || echo no)"

# M1: the read-only switch removed. The same act must leave the sentinel behind.
cp -a "$ROOT/browser" "$TMP/mut"
sed -i 's/    _ACT_RO=1; shot=0$/    _ACT_RO=0/' "$TMP/mut/bin/browser"
arm 'M1 (anchor) mutant applied: the switch never turns on' 0 "$(grep -c '_ACT_RO=1; shot=0' "$TMP/mut/bin/browser")"
run "$TMP/mut/bin/browser" act "$URL" --steps="$EVAL" --out="$TMP/m1"
arm 'M1 MUTANT (no read-only switch): C1 goes red, the page and its sentinel are in --out' 'yes yes' \
  "$([[ -n "$(files "$TMP/m1")" ]] && echo yes || echo no) $(has "$SENT" "$(cat "$TMP/m1"/* 2>/dev/null)")"

# ================================================================ S  served
DSTUB="$TMP/dpw"; mkdir -p "$DSTUB/node_modules/playwright-core"
printf '{ "name": "playwright-core", "version": "0.0.0-daemon-stub", "main": "index.js" }\n' > "$DSTUB/node_modules/playwright-core/package.json"
sed -n "/^cat > \"\$DSTUB\/node_modules\/playwright-core\/index.js\" <<'DPWJS'$/,/^DPWJS$/p" tests/browser_plugin_unit.sh \
  | sed '1d;$d' > "$DSTUB/node_modules/playwright-core/base.js"
arm 'S0 (anchor) the daemon stub was extracted from the main suite' yes \
  "$(grep -q 'DPWREFS' "$DSTUB/node_modules/playwright-core/base.js" && echo yes || echo no)"
cdpwrap "$DSTUB/node_modules/playwright-core"
printf '<html><body>%s: see you at 9</body></html>' "$SENT" > "$TMP/dom.html"
jq -nc --arg s "$SENT" '{nodes:[{ref:("link/" + $s),role:"link",name:$s}], title:"Chats", url:"https://web.telegram.test/k/", html:"<html></html>"}' > "$TMP/snap.json"
jq -nc --arg s "$SENT" '{nodes:[{ref:("link/" + $s),role:"link",name:$s}]}' > "$TMP/refs.json"
SPROF="$TMP/served"; mkdir -p "$SPROF"; chmod 700 "$SPROF"; SOCK="$TMP/s.sock"
env NODE_PATH="$DSTUB/node_modules" PWREC="$TMP/rec.jsonl" DPWDOM="$TMP/dom.html" DPWSNAP="$TMP/snap.json" \
    DPWREFS="$TMP/refs.json" DPWTEXT="$SENT: see you at 9" FIVEDIVE_BROWSER_CHROME="$FAKEBIN/google-chrome" \
    FIVEDIVE_BROWSER_HEADLESS=1 FIVEDIVE_BROWSER_RUN_SETTLE_MS=0 FIVEDIVE_BROWSER_TREE_SETTLE_MS=0 FIVEDIVE_BROWSER_POPUP_WAIT_MS=0 \
    node "$DAEMON" serve "$SPROF" "$SOCK" > "$TMP/s.ready" 2> "$TMP/s.err" &
_KILL+=($!)
for _ in $(seq 50); do grep -q '^ready' "$TMP/s.ready" 2>/dev/null && break; sleep 0.1; done
arm 'S0 (anchor) the served daemon is up on the stub' yes "$(grep -q '^ready' "$TMP/s.ready" && echo yes || { cat "$TMP/s.err" >&2; echo no; })"
call() { node "$DAEMON" call "$SOCK" <<<"$1"; }
plan() { jq -nc --arg u "$URL" --argjson r "$1" --argjson l "$2" '{op:"plan", steps:[{op:"goto",url:$u},{op:"eval",expr:"document.title.length"}],
  args:{}, literal:true, guard:true, look:$l, split:true, report:$r}'; }
run call "$(plan '{"bare":true}' false)"
arm 'S1a served, report {bare:true}: exit 0, one line, the url only' '0|1|["act_report","bare","url"]' \
  "$RC|$(grep -c . <<<"$OUT")|$(jq -c 'keys' <<<"$OUT" 2>/dev/null)"
arm 'S1b ...no document, picture or refs line, and no sentinel anywhere' 'no no no no' \
  "$(has act_html_b64 "$OUT") $(has act_png_b64 "$OUT") $(has act_tree "$OUT") $(has "$SENT" "$OUT$ERR")"
arm 'S1c ...the eval answer is logged' yes "$(has 'step 2 (eval) = "EVAL:document.title.length"' "$ERR")"
run call "$(plan '{"tree":true,"shot":true}' true)"
arm 'S2 (control) the same plan with the old report: the sentinel comes back' yes "$(has "$SENT" "$OUT")"

# ================================================================ B  bin/browser's half
_gates_json() { echo '{"gates":[]}'; }
eval "$(awk '/^_act_session\(\) \{/{f=1} f{print} f&&/^}/{f=0}' "$BROWSER")"
_daemon_lease_json() { echo '{}'; }; _settle_json() { echo '{}'; }; _landing_json() { echo '{}'; }
_extract_sha() { echo SHA; }; _act_downloads_unpack() { :; }; _take_extracted() { :; }
_daemon_call() { printf '%s\n' "$2" > "$TMP/plan.sent"; cat "$CANNED"; }
_PG_DIR=x; _ACT_STAY=0; ACT_STEP_MS=10000; _ACT_FULL=0
CANNED="$TMP/old.out"
{ jq -nc --arg s "$SENT" '{act_report:true, url:"https://web.telegram.test/k/", title:"Chats", text:($s + ": see you at 9"), browser_mode:"headed", popup:null,
    look:{first:true,same_url:false,refs_total:1,refs_added:[("link/" + $s)],refs_added_total:1,refs_removed:[],refs_removed_total:0,text_added:[$s],text_added_total:1,text_removed_total:0}}'
  printf '{"act_html_b64":"%s"}\n' "$(base64 -w0 < "$TMP/dom.html")"
  printf '{"act_png_b64":"%s"}\n' "$(printf 'PNG' | base64 -w0)"
  jq -nc --arg s "$SENT" '{act_tree:true, url:"u", title:"t", nodes:[{ref:("link/" + $s)}]}'
} > "$CANNED"
ST="$TMP/b1"; mkdir -p "$ST"; _ACT_RO=1
_act_session web.telegram.test "$EVAL" false 0 "" '{}' '[]' "$ST" "$TMP/b1.err"
arm 'B1 a read-only act asks the served browser for {bare:true} and no look' '{"bare":true} false' \
  "$(jq -c '.report' "$TMP/plan.sent") $(jq -c '.look' "$TMP/plan.sent")"
arm 'B2 an older served browser sent the whole page: only {url} lands, nothing else is staged' \
  '{"url":"https://web.telegram.test/k/"}|after.json|no' \
  "$(cat "$ST/after.json" 2>/dev/null)|$(ls "$ST" | grep -v steps.session.json | tr "\n" " " | sed "s/ $//")|$(has "$SENT" "$(cat "$ST"/* 2>/dev/null)")"
ST="$TMP/b3"; mkdir -p "$ST"; _ACT_RO=0
_act_session web.telegram.test "$EVAL" false 1 "" '{}' '[]' "$ST" "$TMP/b3.err"
arm 'B3 (control) the same payload in a normal act lands the page as before' 'yes yes' \
  "$([[ -s "$ST/page.html" ]] && echo yes || echo no) $(has "$SENT" "$(cat "$ST/page.html" 2>/dev/null)")"

# ================================================================ D  documented
HELP="$(env FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/p" "$BROWSER" act --help 2>&1)"
arm 'D1 act --help says an eval-only act is read-only' yes "$(has 'READ-ONLY: an act whose steps are only eval' "$HELP")"
SK="$ROOT/browser/skills/use-browser"
arm 'D2 SKILL.md says it, and points at the Telegram notes' 'yes yes' \
  "$(has 'is read-only' "$(cat "$SK/SKILL.md")") $(has 'references/telegram-web.md' "$(cat "$SK/SKILL.md")")"
TG="$(cat "$SK/references/telegram-web.md" 2>/dev/null)"
arm 'D3 the Telegram notes: the mute class, the transition, the own id, the unknown rule' 'yes yes yes yes' \
  "$(has 'is-muted' "$TG") $(has 'backwards' "$TG") $(has 'rootScope.myId' "$TG") $(has 'Treat `"unknown"` as muted' "$TG")"
arm 'D4 ...and they say they were read from source, not measured' yes "$(has 'not yet measured on a live' "$TG")"

printf '\n%d pass, %d fail\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
