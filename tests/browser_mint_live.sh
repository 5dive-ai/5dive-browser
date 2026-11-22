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
trap 'pkill -f -- "$TMP/" 2>/dev/null; rm -rf "$TMP"' EXIT
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

# DIVE-9042: THE COLD BOX. L1-L3 run with no session daemon, so no act ever starts
# a served browser, and they stayed green while the first mint on lodar's box
# died: the act that "started a served browser for the public profile" lost its
# goto to that browser's own start load (net::ERR_ABORTED). Here the real daemon
# is on, and each mint starts from a public profile that does not exist yet and no
# browser running: the first use a box ever makes. Three times, because the race
# is timing; each must start a served browser and mint first time.
#
# It runs AFTER L1-L3 and in roots of its own (profiles, sessions, tools, state),
# so nothing it leaves can reach what they read: no served browser, no _public
# profile, no cold tool in L3's listing (1.97.1's first try put L0 first in the
# shared roots, and L1-L3 went red behind it).
#
# "Served" is read from the profile itself (the daemon's pidfile names a live pid
# and its socket exists), not from mint's stderr: a trial that passes drops its
# act's stderr, so "started a served browser" never reaches the caller there.
if command -v Xvfb >/dev/null 2>&1; then
  COLD="$TMP/cold"
  COLD_ENV=(env -u FIVEDIVE_BROWSER_SESSION_DAEMON -u FIVEDIVE_BROWSER_NO_DAEMON
            FIVEDIVE_BROWSER_SEAT="$SEAT" FIVEDIVE_BROWSER_BOX_SEAT="$SEAT"
            FIVEDIVE_BROWSER_PROFILE_ROOT="$COLD/profiles" FIVEDIVE_BROWSER_ADAPTER_DIR="$COLD/adapters"
            FIVEDIVE_BROWSER_SESSION_ROOT="$COLD/sessions" FIVEDIVE_BROWSER_TOOLS_DIR="$COLD/shelf"
            FIVEDIVE_BROWSER_APPROVAL_DIR="$COLD/approvals" FIVEDIVE_BROWSER_APPROVAL_POLICY="$COLD/policy.json"
            FIVEDIVE_BROWSER_TMP_ROOT="$COLD/tmproot" STATE_DIR="$COLD/state")
  PUB="$COLD/profiles/$SEAT/_public"
  mkdir -p "$COLD/profiles/$SEAT" "$COLD/adapters" "$COLD/sessions/$SEAT" "$COLD/shelf" "$COLD/tmproot" "$COLD/state"
  chmod 711 "$COLD/profiles"; chmod 700 "$COLD/profiles/$SEAT"; chmod 1777 "$COLD/shelf"
  cold_served() {  # the public profile's daemon: a live pid in its pidfile, and its socket
    local f="$PUB/.5dive-serve" p s; [[ -f "$f" ]] || return 1
    p=$(sed -n 's/^daemon_pid=//p' "$f" | head -1); s=$(sed -n 's/^sock=//p' "$f" | head -1)
    [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && [[ -S "${s:-$PUB/.5dive-session.sock}" ]]
  }
  cold_stop() {  # back to a box that never browsed: nothing served, no public profile
    "${COLD_ENV[@]}" "$BROWSER" serve _public --stop >/dev/null 2>&1
    pkill -f -- "$COLD/" 2>/dev/null
    local n; for n in 1 2 3 4 5 6 7 8 9 10; do pgrep -f -- "$COLD/" >/dev/null || break; sleep 0.5; done
    pkill -9 -f -- "$COLD/" 2>/dev/null
    rm -rf -- "$PUB"
  }
  # SETUP, graded on its own: can this runner serve a browser at all? If not, L0
  # says so in serve's own words and grades no mint (a mint through the one-off
  # browser would pass without ever taking the cold served path).
  cold_stop
  "${COLD_ENV[@]}" "$BROWSER" serve _public --url=https://en.wikipedia.org/wiki/Main_Page >"$TMP/out" 2>"$TMP/err"; RC=$?
  if cold_served; then SETUP=yes; else SETUP=no; sed 's/^/    | /' "$TMP/err" | tail -30; fi
  arm "L0 setup: this runner serves a browser for the public profile (serve rc $RC)" yes "$SETUP"
  if [[ "$SETUP" == yes ]]; then
    for i in 1 2 3; do
      cold_stop
      [[ -d "$PUB" ]] && arm "L0 run $i: the public profile is gone before the mint" gone there
      echo "cold mint $i: wiki-cold-$i, a public profile that does not exist yet, the real daemon" >&2
      "${COLD_ENV[@]}" "$BROWSER" mint 'https://en.wikipedia.org/wiki/{{topic}}' "wiki-cold-$i" \
        --task="Open a Wikipedia article and read its title" --inputs='{"topic":"the article name as in its URL"}' \
        --outputs='{"title":"document.querySelector(\"#firstHeading\").textContent.trim()"}' --example='{"topic":"Grace_Hopper"}' --json \
        >"$TMP/out" 2>"$TMP/err"; RC=$?
      (( RC == 0 )) || sed 's/^/    | /' "$TMP/err" | tail -30
      arm "L0 cold box, run $i: the mint started a served browser and minted first time (Grace Hopper)" 'served|true|Grace Hopper' \
        "$(cold_served && printf served || printf no-served-browser)|$(jq -r '"\(.minted)|\(.trial.outputs.title)"' "$TMP/out" 2>/dev/null)"
    done
  fi
  cold_stop
else
  arm 'L0 cold box: Xvfb is here to serve a browser on' yes no
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  { echo "### DIVE-9033 mint live arm (en.wikipedia.org, real Chrome)"; echo; echo "$PASS passed, $FAIL failed"; } >> "$GITHUB_STEP_SUMMARY"
fi
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
