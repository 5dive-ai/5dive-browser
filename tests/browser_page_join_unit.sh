#!/usr/bin/env bash
# DIVE-7076 — a page verb on a NEW site uses the sign-in already in the default group.
#
# Dropshipping trial (DIVE-6902, 2026-10-26): the seat's Main held a live Google
# sign-in, Clicker opened shopify.com's sign-up with a page verb, and it ran in the
# PUBLIC profile, so "Continue with Google" asked for an email. Joining a group
# happened only in `auth`/`serve`, the person's verbs, and `group move` refused a
# site with no profile.
#
# Driven through the real bin/browser as a subprocess. `shot` launches
# `google-chrome --headless --user-data-dir=<profile> --screenshot=<png> <url>`
# itself, so a FAKE google-chrome first on PATH records which profile the render
# ran in and writes the PNG.
#
#   J1  Main holds google.com: `shot <new site url>` links the site into Main and
#       renders in Main's profile, and says so in one line. It is no login yet:
#       not probed, not in `status`; `auth` (a person signing in) clears that
#   J2  `group default --none`: the same call renders in the public profile
#   J3  Main exists with no site in it (no sign-in to share): public profile
#   J4  one account per site: Main holds shopify.com_work, so shopify.com stays public
#   J5  the named form (`shot shopify.com <url>`) joins the same way
#   J6  an existing per-site profile is never moved by a page verb
#   J7  an IP host never joins
#   J8  `group move <site> main` on a site with no profile links it (seat-runnable
#       join, no person step); `--own` then gives it a profile of its own
#   J9  NEGATIVE CONTROL: origin/main's bin/browser renders J1 in the public profile
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
  else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi
}
has() { if grep -qF -- "$1" <<<"$2"; then echo yes; else echo no; fi; }

export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/profiles"
export FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/adapters"; mkdir -p "$FIVEDIVE_BROWSER_ADAPTER_DIR"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/no-rendezvous"
export FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/no-session-daemon"
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli"
export FIVEDIVE_BROWSER_TMP_ROOT="$TMP/tmproot"
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
ME="$(id -un)"
SEAT="$FIVEDIVE_BROWSER_PROFILE_ROOT/$ME"
SEEN="$TMP/seen"; export SEEN

FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/google-chrome" <<'CHROME'
#!/usr/bin/env bash
[[ "${1:-}" == --version ]] && { echo 'Google Chrome 153.0.8010.36'; exit 0; }
dir="" png=""
for a in "$@"; do case "$a" in --user-data-dir=*) dir="${a#--user-data-dir=}" ;; --screenshot=*) png="${a#--screenshot=}" ;; esac; done
[[ -n "$dir" ]] && printf '%s\n' "$dir" > "$SEEN"
[[ -n "$png" ]] && printf '\x89PNG fake\n' > "$png"
exit 0
CHROME
chmod +x "$FAKEBIN/google-chrome"
export PATH="$FAKEBIN:$PATH"

# fresh [--main-empty] — a seat whose Main holds google.com (the trial box's shape).
fresh() {
  rm -rf "$FIVEDIVE_BROWSER_PROFILE_ROOT" "$SEEN"
  mkdir -p "$SEAT"; chmod 711 "$FIVEDIVE_BROWSER_PROFILE_ROOT"; chmod 700 "$SEAT"
  mkdir -m 700 "$SEAT/.group-main"; printf 'Main\n' > "$SEAT/.group-main/.5dive-group-name"
  [[ "${1:-}" == --main-empty ]] || ln -s .group-main "$SEAT/google.com"
}
# shot <args...> — the real verb; RC, ERR, and DIR = the profile the render ran in.
BIN="$BROWSER"
shot() {
  rm -f "$SEEN" "$TMP/s.png"
  "$BIN" shot "$@" --out="$TMP/s.png" >/dev/null 2>"$TMP/err"; RC=$?
  ERR=$(cat "$TMP/err"); DIR=$(readlink -f "$(cat "$SEEN" 2>/dev/null)" 2>/dev/null || true)
}
MAIN() { readlink -f "$SEAT/.group-main"; }
PUB() { readlink -f "$SEAT/_public" 2>/dev/null || echo "$SEAT/_public"; }

j1_arms() {  # j1_arms <label> — what a revert of the page-verb join turns red
  arm "$1 shot exits 0"                                  0 "$RC"
  arm "$1 shopify.com is now a link into Main"           .group-main "$(readlink "$SEAT/shopify.com" 2>/dev/null)"
  arm "$1 the render ran in Main's profile"              "$(MAIN)" "$DIR"
  arm "$1 one line says it joined Main, and what Main holds" yes "$(has 'shopify.com joined Main, so it opens in Main'"'"'s browser and the sign-ins there (google.com) count here.' "$ERR")"
}

# ---------------------------------------------------------------- J1
fresh; shot https://www.shopify.com/signup
j1_arms J1
arm 'J1 ...and names the way out'                        yes "$(has 'To keep it apart: 5dive browser group move shopify.com --own' "$ERR")"
arm 'J1 ...no person step was started (no auth window)'  no "$(has 'browser auth' "$ERR")"
arm 'J1 ...it is marked joined-by-a-page in Main'       yes "$([[ -f "$SEAT/.group-main/.5dive-page-joined.shopify.com" ]] && echo yes || echo no)"
st=$("$BROWSER" status 2>&1)
arm 'J1 ...status does not probe it or call it logged out' no "$(has 'shopify.com' "$st")"
shot https://shopify.com/pricing
arm 'J1b a second page of the site: same profile, said once' "$(MAIN)|no" "$DIR|$(has 'joined Main' "$ERR")"

# J1c a person signing in to it (auth) makes it a login: the note goes.
DISPLAY=:99 "$BROWSER" auth shopify.com >/dev/null 2>&1
arm 'J1c auth clears the joined-by-a-page note'          no "$([[ -f "$SEAT/.group-main/.5dive-page-joined.shopify.com" ]] && echo yes || echo no)"
arm 'J1c ...and it stays in Main'                        .group-main "$(readlink "$SEAT/shopify.com" 2>/dev/null)"

# ---------------------------------------------------------------- J2
fresh; "$BROWSER" group default --none >/dev/null 2>&1
shot https://www.shopify.com/signup
arm 'J2 default --none: shot exits 0'                    0 "$RC"
arm 'J2 ...nothing is linked'                            no "$([[ -e "$SEAT/shopify.com" || -L "$SEAT/shopify.com" ]] && echo yes || echo no)"
arm 'J2 ...the render ran in the public profile'         "$(PUB)" "$DIR"

# ---------------------------------------------------------------- J3
fresh --main-empty; shot https://www.shopify.com/signup
arm 'J3 an empty Main: public profile, nothing linked'   "$(PUB)|no" "$DIR|$([[ -L "$SEAT/shopify.com" ]] && echo yes || echo no)"

# ---------------------------------------------------------------- J4
fresh; ln -s .group-main "$SEAT/shopify.com_work"
shot https://www.shopify.com/signup
arm 'J4 Main holds shopify.com_work: shopify.com stays out of it' no "$([[ -L "$SEAT/shopify.com" ]] && echo yes || echo no)"

# ---------------------------------------------------------------- J5
fresh; shot shopify.com https://www.shopify.com/signup
arm 'J5 named form: linked into Main'                    .group-main "$(readlink "$SEAT/shopify.com" 2>/dev/null)"
arm 'J5 ...rendered in Main'"'"'s profile'               "$(MAIN)" "$DIR"
arm 'J5 ...said once'                                    1 "$(grep -c 'joined Main' <<<"$ERR")"

# ---------------------------------------------------------------- J6
fresh; mkdir -m 700 "$SEAT/etsy.com"; shot https://www.etsy.com/
arm 'J6 an existing own profile is not moved'            dir "$([[ -d "$SEAT/etsy.com" && ! -L "$SEAT/etsy.com" ]] && echo dir || echo changed)"
arm 'J6 ...and nothing says it joined'                   no "$(has 'joined Main' "$ERR")"

# ---------------------------------------------------------------- J7
fresh; shot http://127.0.0.1:8080/
arm 'J7 an IP host never joins'                          no "$([[ -L "$SEAT/127.0.0.1" ]] && echo yes || echo no)"

# ---------------------------------------------------------------- J8
fresh; out=$("$BROWSER" group move etsy.com main 2>&1); rc=$?
arm 'J8 group move of a site with no profile: rc 0'      0 "$rc"
arm 'J8 ...linked into Main'                             .group-main "$(readlink "$SEAT/etsy.com" 2>/dev/null)"
arm 'J8 ...nothing claimed to be kept aside'             no "$(has 'kept aside' "$out")"
arm 'J8 ...no aside dir made'                            no "$([[ -e "$SEAT/.own-etsy.com" ]] && echo yes || echo no)"
out=$("$BROWSER" group move etsy.com --own 2>&1); rc=$?
arm 'J8 --own then: a profile of its own'                "0 dir" "$rc $([[ -d "$SEAT/etsy.com" && ! -L "$SEAT/etsy.com" ]] && echo dir || echo other)"
out=$("$BROWSER" group move nothere.com --own 2>&1); rc=$?
arm 'J8 --own on a site with no profile: rc 0, says so'  "0 yes" "$rc $(has 'has no profile on this seat yet' "$out")"

# ---------------------------------------------------------------- J9 negative control
if git -C "$ROOT" cat-file -e origin/main:browser/bin/browser 2>/dev/null \
   && ! git -C "$ROOT" show origin/main:browser/bin/browser | grep -q '_page_join_default'; then
  OLD="$TMP/old"; cp -r "$ROOT/browser" "$OLD"
  git -C "$ROOT" show origin/main:browser/bin/browser > "$OLD/bin/browser"; chmod +x "$OLD/bin/browser"
  BIN="$OLD/bin/browser"; fresh; shot https://www.shopify.com/signup
  P0=$PASS F0=$FAIL; j1_arms J9m >/dev/null; RED=$((FAIL-F0)); PASS=$P0; FAIL=$F0
  arm 'J9 origin/main: the J1 arms go red (>= 3)'        yes "$( (( RED >= 3 )) && echo yes || echo "no (red=$RED)")"
  arm 'J9 ...it rendered in the public profile'          "$(PUB)" "$DIR"
  BIN="$BROWSER"
else
  echo 'J9 skipped: origin/main already carries the join (or is not fetched)'
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
