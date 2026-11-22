#!/usr/bin/env bash
# DIVE-9033 — the live arm: on en.wikipedia.org in real Chrome, mint ONE read tool
# with an example, then replay it twice with two other inputs. Each replay must
# answer its own article, typed, with 0 model calls (no reflex is configured on a
# runner, so a re-pick could not hide: a miss would fail the run).
#
# It needs a real google-chrome, the pinned playwright-core (npm install in
# browser/) and the network. It refuses rather than measuring a fake. CI runs it in
# the routine-bench job; never on the production host.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
command -v google-chrome >/dev/null 2>&1 || { echo "no google-chrome — this arm runs a real browser or nothing" >&2; exit 69; }
node -e 'require("'"$ROOT"'/browser/node_modules/playwright-core/package.json")' 2>/dev/null \
  || { echo "playwright-core is not installed next to the plugin (npm install --prefix browser)" >&2; exit 69; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/profiles"
export FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/adapters"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/sessions"
export FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/no-session-daemon"
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli"
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
export FIVEDIVE_BROWSER_APPROVAL_DIR="$TMP/approvals" FIVEDIVE_BROWSER_APPROVAL_POLICY="$TMP/policy.json"
export FIVEDIVE_BROWSER_TOOLS_DIR="$TMP/shelf"
SEAT="$(id -un)"
mkdir -p "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT" "$FIVEDIVE_BROWSER_ADAPTER_DIR" "$FIVEDIVE_BROWSER_TOOLS_DIR"
chmod 711 "$FIVEDIVE_BROWSER_PROFILE_ROOT"; chmod 700 "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT"; chmod 1777 "$FIVEDIVE_BROWSER_TOOLS_DIR"

PASS=0; FAIL=0
arm() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"
    [[ "${GITHUB_ACTIONS:-}" == true ]] && printf '::error title=%s::expected %s got %s\n' "${1//[:,]/ }" "$2" "$3"; fi
}
run() { "$BROWSER" "$@" >"$TMP/out" 2>"$TMP/err"; RC=$?; OUT=$(cat "$TMP/out"); ERR=$(cat "$TMP/err"); }

OUTS='{"title":"document.querySelector(\"#firstHeading\").textContent.trim()",
       "paragraphs":{"type":"integer","read":"document.querySelectorAll(\"#mw-content-text p\").length","description":"paragraphs in the article"}}'

# DIVE-9042: THE COLD BOX. Everything below runs with no session daemon, so no
# act ever starts a served browser, and this arm stayed green while the first mint
# on lodar's box died: the act that "started a served browser for the public
# profile" lost its goto to that browser's own start load (net::ERR_ABORTED). Here
# the real daemon is on, and each mint starts from a public profile that does not
# exist yet and no browser running: the first use a box ever makes. Three times,
# because the race is timing; each must start a served browser and mint first time.
if command -v Xvfb >/dev/null 2>&1; then
  COLD_ENV=(env -u FIVEDIVE_BROWSER_SESSION_DAEMON -u FIVEDIVE_BROWSER_NO_DAEMON
            FIVEDIVE_BROWSER_SEAT="$SEAT" FIVEDIVE_BROWSER_BOX_SEAT="$SEAT"
            FIVEDIVE_BROWSER_TMP_ROOT="$TMP/tmproot" STATE_DIR="$TMP/state")
  mkdir -p "$TMP/tmproot" "$TMP/state" "$FIVEDIVE_BROWSER_SESSION_ROOT/$SEAT"
  cold_stop() { "${COLD_ENV[@]}" "$BROWSER" serve _public --stop >/dev/null 2>&1; pkill -f -- "$TMP/profiles" 2>/dev/null; sleep 1; rm -rf "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT/_public"; }
  for i in 1 2 3; do
    cold_stop
    echo "cold mint $i: wiki-cold-$i, a public profile that does not exist yet, the real daemon" >&2
    "${COLD_ENV[@]}" "$BROWSER" mint 'https://en.wikipedia.org/wiki/{{topic}}' "wiki-cold-$i" --private \
      --task="Open a Wikipedia article and read its title" --inputs='{"topic":"the article name as in its URL"}' \
      --outputs='{"title":"document.querySelector(\"#firstHeading\").textContent.trim()"}' --example='{"topic":"Grace_Hopper"}' --json \
      >"$TMP/out" 2>"$TMP/err"; RC=$?
    (( RC == 0 )) || sed 's/^/    | /' "$TMP/err" | tail -30
    arm "L0 cold box, run $i: the mint started a served browser and minted first time (Grace Hopper)" 'served|true|Grace Hopper' \
      "$(grep -q 'started a served browser' "$TMP/err" && printf served || printf no-served-browser)|$(jq -r '"\(.minted)|\(.trial.outputs.title)"' "$TMP/out" 2>/dev/null)"
  done
  cold_stop
else
  arm 'L0 cold box: Xvfb is here to serve a browser on' yes no
fi

echo "mint: wiki-heading, example Grace_Hopper" >&2
run mint 'https://en.wikipedia.org/wiki/{{topic}}' wiki-heading --task="Open a Wikipedia article and read its title and how many paragraphs it has" \
  --inputs='{"topic":"the article name as in its URL, e.g. Ada_Lovelace"}' --outputs="$OUTS" --example='{"topic":"Grace_Hopper"}' --json
arm 'L1 mint on en.wikipedia.org: minted, the example answered its own title' 'true|Grace Hopper' \
  "$(jq -r '"\(.minted)|\(.trial.outputs.title)"' <<<"$OUT" 2>/dev/null)"
(( RC == 0 )) || { sed 's/^/    | /' "$TMP/err" | tail -30; }
printf '  %s\n' "$OUT" >&2

for pair in "Ada_Lovelace|Ada Lovelace" "Alan_Turing|Alan Turing"; do
  topic="${pair%%|*}"; want="${pair#*|}"
  run replay en.wikipedia.org wiki-heading --input="$(jq -nc --arg t "$topic" '{topic:$t}')" --json
  printf '  replay %s: %s\n' "$topic" "$OUT" >&2
  (( RC == 0 )) || sed 's/^/    | /' "$TMP/err" | tail -30
  arm "L2 replay $topic: ok, its own title, an integer paragraph count > 0, 0 model calls" "ok|$want|true|0" \
    "$(jq -r '"\(.verdict)|\(.outputs.title)|\((.outputs.paragraphs | type) == "number" and .outputs.paragraphs > 0)|\(.model_calls)"' <<<"$OUT" 2>/dev/null)"
done
run tools en.wikipedia.org --json
arm 'L3 the tool is listed for every agent, run twice' 'wiki-heading|read|2' "$(jq -r '"\(.name)|\(.access)|\(.runs)"' <<<"$OUT" 2>/dev/null)"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  { echo "### DIVE-9033 mint live arm (en.wikipedia.org, real Chrome)"; echo; echo "$PASS passed, $FAIL failed"; } >> "$GITHUB_STEP_SUMMARY"
fi
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
