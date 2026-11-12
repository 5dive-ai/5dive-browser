#!/usr/bin/env bash
# DIVE-8263 — a site the owner connected (Done) reads `connected`, not
# `unconfirmed`, so agents stop refusing it.
#
# Box bug 902 (kostya on instagram.com) and lodar's producthunt.com on
# chill-gorge: after the owner's Connect + Done, a site with no adapter read
# `UNKNOWN/unconfirmed (no adapter …)` forever, and agents stopped on it. Root's
# Done path now runs the box seat's `status <site>` with
# FIVEDIVE_BROWSER_OWNER_DONE=1; the probe records the time, and a later
# no-adapter check that finds no sign-in form says `connected`.
#
# Driven through the real bin/browser with a fake google-chrome that serves
# the site's front page from <profile>/.fake-dom-front and any other page from
# .fake-dom-page (the browser_generic_memo_unit.sh shape).
#
#   D1  no adapter, no Done, a live page: status keeps UNKNOWN (no adapter …) and
#       now names the next step (page verbs work; shot shows the page)
#   D2  the owner's Done (the flag root's Done path sets): `connected (signed in
#       by the owner <time> …). Agents: use it.`, rc 0, recorded 0600, tile stamp
#       `authenticated`
#   D3  a later status with no flag still reads connected (the record persists)
#   D4  a Done, then the front page is a sign-in form: session expired, rc 1, and
#       the Done is forgotten (a live page afterwards reads UNKNOWN again)
#   D5  a page verb (read) on a Done site: says connected and proceeds; the
#       remembered check on the next verb says connected too
#   D6  ...and the page guard still fails closed: a Done site whose page is a
#       sign-in form is refused
#   D7  run (an adapter with an action and no probe markers) accepts connected:
#       it reaches the driver; with no Done it refuses as before
#   D8  root's Done path passes the flag to the seat it runs status as, and a
#       caller's own stray flag is not passed on by any other root call
#   D10 a seat that uses the box login (brokered) cannot open the owner's 0700
#       store: the Done is also published 0640 beside <site>.offered, a brokered
#       read finds it there, and an expired read removes it
#   D9  NEGATIVE CONTROL: origin/main's bin/browser ignores the Done (UNKNOWN)
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"

TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0
arm() {  # arm <name> <expected> <got>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n   last stderr: %s\n' "$1" "$2" "$3" "$(tail -c 400 "$TMP/err" 2>/dev/null)"; fi
}
has() { if grep -qF -- "$1" <<<"$2"; then echo yes; else echo no; fi; }

export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/profiles"
export FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/adapters"; mkdir -p "$FIVEDIVE_BROWSER_ADAPTER_DIR"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/no-rendezvous"
export FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/no-session-daemon"
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli"
export FIVEDIVE_BROWSER_TMP_ROOT="$TMP/tmproot"
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
export FIVEDIVE_BROWSER_PROBE_WAIT_MS=400
unset FIVEDIVE_BROWSER_GENERIC_MEMO_TTL FIVEDIVE_BROWSER_OWNER_DONE
ME="$(id -un)"
SEAT="$FIVEDIVE_BROWSER_PROFILE_ROOT/$ME"
LOG="$TMP/chrome.log"; export LOG

LIVE_DOM='<html><body><div id="feed">posts</div></body></html>'
DEAD_DOM='<html><body><form action="/login"><input type="password" name="pw"></form></body></html>'

FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/google-chrome" <<'CHROME'
#!/usr/bin/env bash
[[ "${1:-}" == --version ]] && { echo 'Google Chrome 153.0.8010.36'; exit 0; }
d="" shot="" dump="" u=""
for a in "$@"; do
  case "$a" in
    --user-data-dir=*) d="${a#*=}" ;;
    --screenshot=*) shot="${a#*=}" ;;
    --dump-dom) dump=1 ;;
    -*) ;;
    *) u="$a" ;;
  esac
done
printf '%s %s\n' "$([[ -n "$shot" ]] && echo RENDER || echo LOAD)" "$u" >> "$LOG"
[[ -n "$shot" ]] && printf '\x89PNG fake\n' > "$shot"
if [[ -n "$dump" || -z "$shot" ]]; then
  if [[ "$u" =~ ^https?://[^/]+/?$ && -f "$d/.fake-dom-front" ]]; then cat "$d/.fake-dom-front"
  else cat "$d/.fake-dom-page" 2>/dev/null; fi
fi
exit 0
CHROME
chmod +x "$FAKEBIN/google-chrome"
export PATH="$FAKEBIN:$PATH"

SITE=noad.example.com
fresh() {  # a seat with one connected no-adapter login, its pages live
  rm -rf "$FIVEDIVE_BROWSER_PROFILE_ROOT" "$LOG"; : > "$LOG"
  mkdir -p "$SEAT"; chmod 711 "$FIVEDIVE_BROWSER_PROFILE_ROOT"; chmod 700 "$SEAT"
  mkdir -m 700 "$SEAT/$SITE"
  printf '%s' "$LIVE_DOM" > "$SEAT/$SITE/.fake-dom-front"
  printf '%s' "$LIVE_DOM" > "$SEAT/$SITE/.fake-dom-page"
}
DONEF="$SEAT/$SITE/.5dive-owner-done"
status() {  # status [env...] -> OUT RC (the site's own line)
  OUT=$(env "$@" "$BROWSER" status "$SITE" 2>"$TMP/err"); RC=$?
  OUT=$(grep -F "$SITE" <<<"$OUT" | head -1)
}
N=0
readp() {  # readp <browser> -> RC ERR
  N=$((N+1)); mkdir -m 700 "$TMP/r$N"
  "$1" read "https://$SITE/page" --out="$TMP/r$N" >/dev/null 2>"$TMP/err"; RC=$?
  ERR=$(cat "$TMP/err")
}

# ---------------------------------------------------------------- D1
fresh
status
arm 'D1 no Done: status still says UNKNOWN (no adapter …)'   yes "$(has 'UNKNOWN (no adapter for noad.example.com' "$OUT")"
arm 'D1 ...rc 0 (quiet, as before)'                          0 "$RC"
arm 'D1 ...and names the next step: page verbs work'         yes "$(has 'Not a stop sign: read, links, snapshot and act still work' "$OUT")"
arm 'D1 ...and never says connected'                         no "$(has 'connected (' "$OUT")"

# ---------------------------------------------------------------- D2
fresh
status FIVEDIVE_BROWSER_OWNER_DONE=1
arm 'D2 the owner'"'"'s Done: status reads connected'        yes "$(has 'connected (signed in by the owner ' "$OUT")"
arm 'D2 ...leads with the verdict'                           yes "$([[ "$OUT" =~ $SITE[[:space:]]+connected\ \( ]] && echo yes || echo no)"
arm 'D2 ...tells agents to use it'                           yes "$(has 'Agents: use it.' "$OUT")"
arm 'D2 ...rc 0'                                             0 "$RC"
arm 'D2 ...the Done is recorded, 0600, as a time'            "600 yes" \
  "$(stat -c %a "$DONEF" 2>/dev/null) $(grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z$' "$DONEF" 2>/dev/null && echo yes || echo no)"
arm 'D2 ...the tile stamp says authenticated'                authenticated "$(awk '{print $2}' "$SEAT/$SITE/.5dive-liveness" 2>/dev/null)"

# ---------------------------------------------------------------- D3
status
arm 'D3 a later check with no flag still reads connected'    yes "$(has 'connected (signed in by the owner ' "$OUT")"
arm 'D3 ...rc 0'                                             0 "$RC"

# ---------------------------------------------------------------- D4
printf '%s' "$DEAD_DOM" > "$SEAT/$SITE/.fake-dom-front"
status
arm 'D4 a Done, then a sign-in form: session expired'        yes "$(has 'session expired — human action required' "$OUT")"
arm 'D4 ...rc 75 (cold, as any signed-out site)'             75 "$RC"
arm 'D4 ...the Done is forgotten'                            gone "$([[ -e "$DONEF" ]] && echo kept || echo gone)"
printf '%s' "$LIVE_DOM" > "$SEAT/$SITE/.fake-dom-front"
status
arm 'D4 ...a live page afterwards is UNKNOWN again, not connected' "yes no" \
  "$(has 'UNKNOWN (no adapter' "$OUT") $(has 'connected (' "$OUT")"

# ---------------------------------------------------------------- D5
fresh
status FIVEDIVE_BROWSER_OWNER_DONE=1
readp "$BROWSER"
arm 'D5 read on a Done site proceeds'                        0 "$RC"
arm 'D5 ...and says connected'                               yes "$(has 'connected (signed in by the owner' "$ERR")"
arm 'D5 ...not unconfirmed'                                  no "$(has 'unconfirmed' "$ERR")"
readp "$BROWSER"
arm 'D5 the remembered check on the next verb says connected' "0 yes yes" \
  "$RC $(has 'not again now' "$ERR") $(has 'connected (signed in by the owner' "$ERR")"

# ---------------------------------------------------------------- D6
printf '%s' "$DEAD_DOM" > "$SEAT/$SITE/.fake-dom-page"
readp "$BROWSER"
arm 'D6 a Done site whose page is a sign-in form is refused' yes "$([[ $RC -ne 0 ]] && echo yes || echo no)"
arm 'D6 ...by the page guard'                                yes "$(has 'sign-in form, not the page you asked for' "$ERR")"

# ---------------------------------------------------------------- D7
cat > "$FIVEDIVE_BROWSER_ADAPTER_DIR/$SITE.json" <<JSON
{ "site": "$SITE",
  "actions": { "publish": {
      "steps": [ {"op":"goto","url":"https://$SITE/compose"} ],
      "verify": { "url": "https://$SITE/out", "expect": "posts" } } } }
JSON
cat > "$TMP/driver" <<DRV
#!/usr/bin/env bash
cat > "$TMP/driver-plan.json"
exit 0
DRV
chmod +x "$TMP/driver"
fresh
"$BROWSER" run "$SITE" publish >/dev/null 2>"$TMP/err"; RC=$?
arm 'D7 run with no Done refuses (cannot confirm)'           "yes no" \
  "$(has 'cannot confirm the noad.example.com session is live' "$(cat "$TMP/err")") $([[ -f "$TMP/driver-plan.json" ]] && echo yes || echo no)"
status FIVEDIVE_BROWSER_OWNER_DONE=1
FIVEDIVE_BROWSER_DRIVER="$TMP/driver" "$BROWSER" run "$SITE" publish >/dev/null 2>"$TMP/err"; RC=$?
arm 'D7 run on a connected site reaches the driver'          yes "$([[ -f "$TMP/driver-plan.json" ]] && echo yes || echo no)"
arm 'D7 ...past the liveness gate'                           no "$(has 'cannot confirm' "$(cat "$TMP/err")")"
rm -f "$FIVEDIVE_BROWSER_ADAPTER_DIR/$SITE.json"

# ---------------------------------------------------------------- D8
# _connect_as_seat, lifted out of the script, run as a non-root caller (its
# else-branch) with CONNECT_SELF a probe that prints the flag it was given.
FN="$TMP/fn.sh"
awk '/^_connect_as_seat\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$BROWSER" > "$FN"
printf '#!/usr/bin/env bash\necho "flag=${FIVEDIVE_BROWSER_OWNER_DONE:-none}"\n' > "$TMP/self"; chmod +x "$TMP/self"
export SELF="$TMP/self"
arm 'D8 the Done path passes the flag'                       flag=1 \
  "$(bash -c 'source "$1"; CONNECT_SELF="$SELF"; CONNECT_OWNER_DONE=1 _connect_as_seat x status s' _ "$FN")"
arm 'D8 ...any other root call does not, even with a stray flag in its env' flag=none \
  "$(FIVEDIVE_BROWSER_OWNER_DONE=1 bash -c 'source "$1"; CONNECT_SELF="$SELF"; _connect_as_seat x status s' _ "$FN")"
arm 'D8 the login Done path sets it (box seat and owner seat)' 2 \
  "$(grep -c 'CONNECT_OWNER_DONE=1 _connect_as_\(box\|seat\) [^ ]* *status\|CONNECT_OWNER_DONE=1 _connect_as_box status' "$BROWSER")"

# ---------------------------------------------------------------- D10
RV="$FIVEDIVE_BROWSER_SESSION_ROOT/$ME"
fresh; mkdir -p "$RV"; chmod 710 "$RV"
status FIVEDIVE_BROWSER_OWNER_DONE=1
arm 'D10 the Done is published beside the offer, 0640'      640 "$(stat -c %a "$RV/$SITE.done" 2>/dev/null)"
FNS="$TMP/fns.sh"
for f in _rv_dir _site_state _owner_done_file _owner_done_public _owner_done_at; do
  awk -v f="$f" '$0 ~ "^"f"\\(\\) *\\{" {p=1} p{print} p&&/^\}/{exit}' "$BROWSER" >> "$FNS"
done
arm 'D10 ...a brokered read (the owner store unreadable) finds it' "$(cat "$RV/$SITE.done" 2>/dev/null)" \
  "$(SESSION_ROOT="$FIVEDIVE_BROWSER_SESSION_ROOT" bash -c 'source "$1"; _SITE_BROKERED=1 _SITE_OWNER="$2"; _owner_done_at "/nonexistent/$2/$3"' _ "$FNS" "$ME" "$SITE")"
arm 'D10 ...and with no published Done it finds none'       none \
  "$(SESSION_ROOT="$TMP/empty" bash -c 'source "$1"; _SITE_BROKERED=1 _SITE_OWNER="$2"; _owner_done_at "/nonexistent/$2/$3" || echo none' _ "$FNS" "$ME" "$SITE")"
printf '%s' "$DEAD_DOM" > "$SEAT/$SITE/.fake-dom-front"
status
arm 'D10 ...an expired read removes the public one too'     gone "$([[ -e "$RV/$SITE.done" ]] && echo kept || echo gone)"
rm -rf "$RV"

# ---------------------------------------------------------------- D9
OLD="$TMP/old"
if git -C "$ROOT" cat-file -e origin/main:browser/bin/browser 2>/dev/null \
   && ! git -C "$ROOT" grep -q '_owner_done_note' origin/main -- browser/bin/browser 2>/dev/null; then
  mkdir -p "$OLD/bin" "$OLD/lib"
  git -C "$ROOT" show origin/main:browser/bin/browser > "$OLD/bin/browser"; chmod +x "$OLD/bin/browser"
  cp -r "$ROOT/browser/lib/." "$OLD/lib/"
  fresh
  OUT=$(FIVEDIVE_BROWSER_OWNER_DONE=1 "$OLD/bin/browser" status "$SITE" 2>/dev/null | grep -F "$SITE" | head -1)
  arm 'D9 NEGATIVE CONTROL: origin/main ignores the Done (UNKNOWN, not connected)' "yes no" \
    "$(has 'UNKNOWN (no adapter' "$OUT") $(has 'connected (' "$OUT")"
else
  printf 'SKIP: D9 (origin/main already carries the fix, or is not fetched)\n'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
