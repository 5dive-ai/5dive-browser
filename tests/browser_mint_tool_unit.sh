#!/usr/bin/env bash
# DIVE-9033 — mint a site task into a TOOL (named, typed inputs and outputs) that
# any agent on the box replays with new inputs and no model.
#
# Runs the real bin/browser and driver-playwright on the main suite's recording
# playwright stub (cold, no served browser), wrapped with a CDP session that
# answers Runtime.evaluate with "EVAL:<expression>" — so every read is a string.
#
#   M  mint
#      M1 a URL template + one string output + an example: exit 0, the file on the
#         shelf (0644), the example's value nowhere in it, the stub opened the
#         example's URL
#      M2 an output typed number that reads a string: NOT minted, exit 1, no file
#      M3 refusals before anything runs (64, no goto): a {{input}} in the host, an
#         unused input, an undeclared placeholder, an eval step, a saved login, no
#         --example on a read tool, --no-trial on a read tool, no --task, bad type
#      M4 --private: the seat's own directory, 0600, not on the shelf
#      M5 --from-routine: a recorded routine's slot becomes a named input
#   R  replay <site> <tool> --input
#      R1 a new input: verdict ok, the typed output, 0 model calls, the new URL opened
#      R2 a second input with / + and a space: percent-encoded in the path, same host
#      R3 bad inputs refused (64, no goto): unknown name, missing, wrong type, not JSON
#      R4 --values against a tool, --input against a name with no tool: 64
#      R5 a read tool takes no --approved
#      R6 a fill + press tool (not a read-only act): the input typed, outputs read
#         off the act's stderr
#      R7 a read tool that reaches a pay step stops, says it was minted wrong
#      R8 another seat calls the shelf's tool, and lists it
#      R9 a world-writable tool file is not run
#   T  tools ls / show / forget, usage
#   X  MUTANT: the output check removed -> M2's tool mints (the arm sees it)
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"

TMP="$(mktemp -d /tmp/d9033.XXXXXX)"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

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
gotos() { grep -c '"call":"goto"' "$PWREC"; }

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
export FIVEDIVE_BROWSER_TOOLS_DIR="$TMP/shelf"
mkdir -p "$FIVEDIVE_BROWSER_TOOLS_DIR"; chmod 1777 "$FIVEDIVE_BROWSER_TOOLS_DIR"
mkdir -p "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT" "$FIVEDIVE_BROWSER_PROFILE_ROOT/other-seat"
chmod 711 "$FIVEDIVE_BROWSER_PROFILE_ROOT"; chmod 700 "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT" "$FIVEDIVE_BROWSER_PROFILE_ROOT/other-seat"
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == --version ]] && { echo "Google Chrome 153"; exit 0; }\necho "<html><body>public</body></html>"\n' > "$FAKEBIN/google-chrome"
chmod +x "$FAKEBIN/google-chrome"
export PATH="$FAKEBIN:$PATH"

PWROOT="$TMP/pw"; mkdir -p "$PWROOT/node_modules/playwright-core"
printf '{ "name": "playwright-core", "version": "0.0.0-stub", "main": "index.js" }\n' > "$PWROOT/node_modules/playwright-core/package.json"
sed -n "/^cat > \"\$PWROOT\/node_modules\/playwright-core\/index.js\" <<'PWJS'$/,/^PWJS$/p" tests/browser_plugin_unit.sh \
  | sed '1d;$d' > "$PWROOT/node_modules/playwright-core/base.js"
arm 'M0 (anchor) the cold stub was extracted from the main suite' yes \
  "$(grep -q 'launchPersistentContext' "$PWROOT/node_modules/playwright-core/base.js" && echo yes || echo no)"
cat > "$PWROOT/node_modules/playwright-core/index.js" <<'JS'
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
export NODE_PATH="$PWROOT/node_modules"
export PWREC="$TMP/pw.jsonl"; : > "$PWREC"
export PWWALK="$TMP/walk.json"
jq -nc '{nodes:[{ref:"textbox/Search", role:"textbox", name:"Search"}], marker:"m-1"}' > "$PWWALK"
export PWTITLE="Wiki" PWHTML="<html><body><h1>Wiki</h1></body></html>" PWTEXT="Wiki"

SHELF="$FIVEDIVE_BROWSER_TOOLS_DIR"
OUTS='{"title":"document.title"}'

# ================================================================ M  mint
: > "$PWREC"
run "$BROWSER" mint 'https://wiki.test/wiki/{{topic}}' wiki-title --task="Read a wiki article's title" \
  --inputs='{"topic":"the article to open"}' --outputs="$OUTS" --example='{"topic":"Pythonexample"}'
F="$SHELF/wiki.test+wiki-title.json"
arm 'M1a mint exits 0' 0 "$RC"; [[ "$RC" == 0 ]] || gha 'M1 output' "$OUT $ERR"
arm 'M1b ...the tool is on the shelf, 0644' 'yes 644' "$([[ -f "$F" ]] && echo yes || echo no) $(stat -c %a "$F" 2>/dev/null)"
arm 'M1c ...the example ran: the stub opened its URL' 1 "$(grep -c '"url":"https://wiki.test/wiki/Pythonexample"' "$PWREC")"
arm 'M1d ...the example value is nowhere in the file' no "$(has Pythonexample "$(cat "$F" 2>/dev/null)")"
arm 'M1e ...typed schema, a read, the URL template, access read, trial true' \
  'string|string|document.title|https://wiki.test/wiki/{{topic}}|read|true|["topic"]' \
  "$(jq -r '"\(.inputs.properties.topic.type)|\(.outputs.properties.title.type)|\(.reads[0].expr)|\(.acts[0].url)|\(.access)|\(.trial)|\(.inputs.required|tojson)"' "$F" 2>/dev/null)"
arm 'M1f ...prints the call line for other agents' yes "$(has "call: 5dive browser replay wiki.test wiki-title --input='{\"topic\":\"…\"}'" "$OUT")"

: > "$PWREC"
run "$BROWSER" mint 'https://wiki.test/wiki/{{topic}}' wiki-count --task="Count" \
  --inputs='{"topic":"t"}' --outputs='{"n":{"type":"number","read":"document.links.length"}}' --example='{"topic":"X"}'
arm 'M2 an output that reads the wrong type: NOT minted, exit 1, no file, says why' '1|no|yes|yes' \
  "$RC|$([[ -e "$SHELF/wiki.test+wiki-count.json" ]] && echo yes || echo no)|$(has 'NOT minted' "$ERR")|$(has 'n should be a number' "$ERR")"

refuse() {  # <arm> <needle> <mint args…>
  local a="$1" n="$2"; shift 2; : > "$PWREC"
  run "$BROWSER" mint "$@"
  arm "$a" "64|yes|0" "$RC|$(has "$n" "$ERR")|$(gotos)"
}
refuse 'M3a a {{input}} in the host is refused' 'host is fixed' 'https://{{h}}.test/x' t1 --task=x --inputs='{"h":"h"}' --outputs="$OUTS" --example='{"h":"a"}'
refuse 'M3b an unused input is refused' 'input extra is not used' 'https://wiki.test/wiki/{{topic}}' t2 --task=x --inputs='{"topic":"t","extra":"e"}' --outputs="$OUTS" --example='{"topic":"a","extra":"b"}'
refuse 'M3c an undeclared placeholder is refused' '{{other}} is used and is not in --inputs' 'https://wiki.test/wiki/{{topic}}/{{other}}' t3 --task=x --inputs='{"topic":"t"}' --outputs="$OUTS" --example='{"topic":"a"}'
refuse 'M3d an eval step is refused (outputs are the reads)' "'eval' is not a step a tool keeps" 'https://wiki.test/' t4 --task=x --outputs="$OUTS" --steps='[{"op":"eval","expr":"1"}]' --example='{}'
refuse 'M3e a saved login step is refused' 'does not type a saved login' 'https://wiki.test/' t5 --task=x --outputs="$OUTS" --steps='[{"op":"fill","selector":"#p","saved":"wiki.password"}]' --example='{}'
refuse 'M3f a read tool needs --example' '--example is one real run' 'https://wiki.test/' t6 --task=x --outputs="$OUTS"
refuse 'M3g --no-trial is refused on a read tool' '--no-trial is for a --write tool only' 'https://wiki.test/' t7 --task=x --outputs="$OUTS" --no-trial
refuse 'M3h no --task is refused' '--task says in plain words' 'https://wiki.test/' t8 --outputs="$OUTS" --example='{}'
refuse 'M3i a bad output type is refused' 'type float is not one of' 'https://wiki.test/' t9 --task=x --outputs='{"n":{"type":"float","read":"1"}}' --example='{}'

run "$BROWSER" mint 'https://wiki.test/wiki/{{topic}}' wiki-private --task="private" --inputs='{"topic":"t"}' --outputs="$OUTS" --example='{"topic":"a"}' --private
PF="$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT/.tools/wiki.test/wiki-private.json"
arm 'M4 --private: in the seat dir, 0600, not on the shelf' '0|600|no|yes' \
  "$RC|$(stat -c %a "$PF" 2>/dev/null)|$([[ -e "$SHELF/wiki.test+wiki-private.json" ]] && echo yes || echo no)|$(has 'this seat only' "$OUT")"

# A routine recorded the old way: one fill slot.
RD="$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT/.routines/wiki.test"; mkdir -p "$RD"
jq -nc '{version:1, site:"wiki.test", profile:"_public", name:"search", slots:1, replays:0,
  acts:[{url:"https://wiki.test/", steps:[{op:"fill", selector:"#q", slot:1}, {op:"press", selector:"#q", key:"Enter"}], expect:null, wait_for:null}]}' > "$RD/search.json"
: > "$PWREC"
run "$BROWSER" mint 'https://wiki.test/' wiki-search --task="Search the wiki" --from-routine=search \
  --inputs='{"query":"what to search for"}' --outputs="$OUTS" --example='{"query":"Exampleq"}'
SF="$SHELF/wiki.test+wiki-search.json"
arm 'M5a --from-routine mints, the slot becomes {{query}}' '0|{{query}}|Enter' "$RC|$(jq -r '.acts[0].steps[0].value' "$SF" 2>/dev/null)|$(jq -r '.acts[0].steps[1].key' "$SF" 2>/dev/null)"
[[ "$RC" == 0 ]] || gha 'M5 output' "$OUT $ERR"
arm 'M5b ...the example was typed into the field, and is not in the file' '1|no' \
  "$(grep -c '"call":"fill","sel":"#q","val":"Exampleq"' "$PWREC")|$(has Exampleq "$(cat "$SF" 2>/dev/null)")"

# ================================================================ R  replay
: > "$PWREC"
run "$BROWSER" replay wiki.test wiki-title --input='{"topic":"Rust"}' --json
arm 'R1a replay with a new input: ok, the typed output, 0 model calls' 'ok|EVAL:document.title|0|read' \
  "$(jq -r '"\(.verdict)|\(.outputs.title)|\(.model_calls)|\(.access)"' <<<"$OUT" 2>/dev/null)"
[[ "$RC" == 0 ]] || gha 'R1 output' "$OUT $ERR"
arm 'R1b ...it opened the new URL' 1 "$(grep -c '"url":"https://wiki.test/wiki/Rust"' "$PWREC")"

: > "$PWREC"
run "$BROWSER" replay https://wiki.test/ wiki-title --input='{"topic":"C++ / x"}'
arm 'R2a a second input, plain mode: exit 0, title printed' '0|yes' "$RC|$(has 'title: EVAL:document.title' "$OUT")"
arm 'R2b ...percent-encoded in the path, same host' 1 "$(grep -c '"url":"https://wiki.test/wiki/C%2B%2B%20%2F%20x"' "$PWREC")"
arm 'R2c ...run count went up on the owner'"'"'s file' 2 "$(jq -r '.runs' "$F")"

bad() {  # <arm> <needle> <input>
  : > "$PWREC"; run "$BROWSER" replay wiki.test wiki-title --input="$3"
  arm "$1" "64|yes|0" "$RC|$(has "$2" "$ERR")|$(gotos)"
}
bad 'R3a an unknown input name' 'nope is not an input of wiki-title' '{"topic":"a","nope":1}'
bad 'R3b a missing input' 'wiki-title needs topic' '{}'
bad 'R3c an input of the wrong type' 'topic is a string, got 5' '{"topic":5}'
bad 'R3d inputs that are not JSON' 'not JSON' '{topic'

run "$BROWSER" replay wiki.test wiki-title --values='["a"]'
arm 'R4a --values against a tool: 64, names --input' '64|yes' "$RC|$(has 'takes named inputs' "$ERR")"
run "$BROWSER" replay wiki.test no-such --input='{}'
arm 'R4b --input with no such tool: 64' '64|yes' "$RC|$(has "no tool 'no-such'" "$ERR")"
run "$BROWSER" replay wiki.test wiki-title --input='{"topic":"a"}' --approved=x-0123456789ab
arm 'R5 a read tool takes no --approved' '64|yes' "$RC|$(has 'read tool: it never needs' "$ERR")"

: > "$PWREC"
run "$BROWSER" replay wiki.test wiki-search --input='{"query":"Second search"}' --json
arm 'R6 fill+press tool: ok, the input typed, the output read off stderr' 'ok|EVAL:document.title|1' \
  "$(jq -r '"\(.verdict)|\(.outputs.title)"' <<<"$OUT" 2>/dev/null)|$(grep -c '"call":"fill","sel":"#q","val":"Second search"' "$PWREC")"
[[ "$RC" == 0 ]] || gha 'R6 output' "$OUT $ERR"

# A "read" tool whose click lands on a pay button.
jq -c '.name = "wiki-buy" | .acts[0].steps = [{op:"click", selector:"#buy"}]' "$F" > "$SHELF/wiki.test+wiki-buy.json"; chmod 644 "$SHELF/wiki.test+wiki-buy.json"
run env PWLABEL="Place your order" "$BROWSER" replay wiki.test wiki-buy --input='{"topic":"a"}' --json
arm 'R7 a read tool that reaches a pay step: 73, needs_owner, says minted wrong' '73|needs_owner|yes' \
  "$RC|$(jq -r '.verdict' <<<"$OUT" 2>/dev/null)|$(has 'it was minted wrong' "$ERR")"

: > "$PWREC"
run env FIVEDIVE_BROWSER_SEAT=other-seat "$BROWSER" replay wiki.test wiki-title --input='{"topic":"Go"}' --json
arm 'R8a another seat calls the shelf tool' '0|ok|1' "$RC|$(jq -r '.verdict' <<<"$OUT" 2>/dev/null)|$(grep -c '"url":"https://wiki.test/wiki/Go"' "$PWREC")"
[[ "$RC" == 0 ]] || gha 'R8 output' "$OUT $ERR"
run env FIVEDIVE_BROWSER_SEAT=other-seat "$BROWSER" tools ls
arm 'R8b ...and lists it, with the owner' yes "$(has "by $SEAT" "$OUT")"

chmod 666 "$F"
run "$BROWSER" replay wiki.test wiki-title --input='{"topic":"a"}'
arm 'R9 a world-writable tool file is not run' '64|yes' "$RC|$(has "no tool 'wiki-title'" "$ERR")"
chmod 644 "$F"

# ================================================================ T  tools
run "$BROWSER" tools wiki.test --json
arm 'T1 tools --json lists each tool once, typed' 'wiki-buy wiki-private wiki-search wiki-title|{"topic":"string"}|{"title":"string"}' \
  "$(jq -rs 'map(.name) | sort | join(" ")' <<<"$OUT")|$(jq -rc 'select(.name=="wiki-title") | .inputs' <<<"$OUT")|$(jq -rc 'select(.name=="wiki-title") | .outputs' <<<"$OUT")"
run "$BROWSER" tools show wiki.test wiki-title
arm 'T2 tools show names inputs, outputs and the read' 'yes yes' "$(has 'topic (string): the article to open' "$OUT") $(has 'title (string) <- document.title' "$OUT")"
run "$BROWSER" tools forget wiki.test wiki-private
arm 'T3 tools forget removes the owner'"'"'s tool' '0|no' "$RC|$([[ -e "$PF" ]] && echo yes || echo no)"
run "$BROWSER" --help
arm 'T4 usage names mint and tools' 'yes yes' "$(has '5dive browser mint <url-with-{{input}}>' "$OUT$ERR") $(has '5dive browser tools [<site>]' "$OUT$ERR")"

# ================================================================ X  mutant
MUT="$TMP/mut"; cp -a "$ROOT/browser" "$MUT"
python3 - "$MUT/bin/browser" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
old='  why="$(_tool_check_outputs "$t" "$outputs")"\n'
assert s.count(old)==1; s=s.replace(old,'  why=""\n'); open(p,'w').write(s)
PY
run "$MUT/bin/browser" mint 'https://wiki.test/wiki/{{topic}}' wiki-count --task="Count" \
  --inputs='{"topic":"t"}' --outputs='{"n":{"type":"number","read":"document.links.length"}}' --example='{"topic":"X"}'
arm 'X1 MUTANT (no output check): M2'"'"'s wrong-typed tool is minted — the arm sees it' '0|yes' \
  "$RC|$([[ -e "$SHELF/wiki.test+wiki-count.json" ]] && echo yes || echo no)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
