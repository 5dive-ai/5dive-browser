#!/usr/bin/env bash
# DIVE-7722 — a site with no adapter is checked once, not before every page verb.
#
# DIVE-7690's home rerun: 1,308 page verbs on 59 no-adapter sites each opened a
# separate cold Chrome on the site's front page first ("unconfirmed (no adapter
# for X) … the generic check found no sign-in form"), +5-10 s a verb, timeouts
# 9 -> 22. The check's answer for such a site is "unconfirmed" and the page goes
# ahead anyway, guarded by _signin_guard on the page itself. So the answer is
# kept (FIVEDIVE_BROWSER_GENERIC_MEMO_TTL, default 30 min) and the cold Chrome
# runs once.
#
# Arms send `read` (it guards its page; so do links, snapshot and act).
# Driven through the real bin/browser, and through the REAL `5dive` CLI (the
# path the row was found on), pointed at this build by a scratch STATE_DIR whose
# plugin record names it. A fake google-chrome logs every launch; the check is
# the launch that dumps the site's FRONT page (https://<site>/), the render is
# the one with --screenshot.
#
#   G1  a connected site, no adapter: three shots -> ONE front-page check; the
#       2nd and 3rd say the check is not run again (direct and via the CLI)
#   G2  a site a page verb joined (marker present): no check at all (unchanged)
#   G3  a signed-out site (its front page is a sign-in form): every shot refuses,
#       and nothing is remembered
#   G4  remembered, then the page itself is a sign-in form: refused by the page
#       guard, the memo is dropped, so the next verb checks the front page again
#   G5  TTL=0 turns the memo off: a check per verb, as before
#   G6  an expired memo is not used
#   G7  a memo about another profile directory is not used
#   G8  `auth` drops the memo
#   G10 shot, which has no page guard, never uses the memo
#   G9  NEGATIVE CONTROL: origin/main's bin/browser, via the CLI, checks on every verb
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
unset FIVEDIVE_BROWSER_GENERIC_MEMO_TTL
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
# The front page and the page asked for can differ: .fake-dom-front / .fake-dom-page.
if [[ -n "$dump" || -z "$shot" ]]; then
  if [[ "$u" =~ ^https?://[^/]+/?$ && -f "$d/.fake-dom-front" ]]; then cat "$d/.fake-dom-front"
  else cat "$d/.fake-dom-page" 2>/dev/null; fi
fi
exit 0
CHROME
chmod +x "$FAKEBIN/google-chrome"
export PATH="$FAKEBIN:$PATH"

SITE=noad.example.com
fresh() {  # a seat with one connected no-adapter login, and Main holding google.com
  rm -rf "$FIVEDIVE_BROWSER_PROFILE_ROOT" "$LOG"; : > "$LOG"
  mkdir -p "$SEAT"; chmod 711 "$FIVEDIVE_BROWSER_PROFILE_ROOT"; chmod 700 "$SEAT"
  mkdir -m 700 "$SEAT/$SITE"
  printf '%s' "$LIVE_DOM" > "$SEAT/$SITE/.fake-dom-front"
  printf '%s' "$LIVE_DOM" > "$SEAT/$SITE/.fake-dom-page"
  mkdir -m 700 "$SEAT/.group-main"; printf 'Main\n' > "$SEAT/.group-main/.5dive-group-name"
  ln -s .group-main "$SEAT/google.com"
}
checks() { grep -c "^LOAD https://$1/\?\$" "$LOG" 2>/dev/null || true; }  # front-page checks so far
MEMO() { echo "$SEAT/.5dive-generic-unconfirmed.$1"; }

# A scratch STATE_DIR whose plugin record sends `5dive browser` to <plugin dir>.
mkcli() {  # mkcli <state-dir> <plugin-dir>
  mkdir -p "$1/plugins/enabled"
  printf '{"browser@5dive-browser":{"enabled":true,"capabilities":["channel","verb","skill"],"verbs":[{"name":"browser"}]}}\n' > "$1/plugins/installed.json"
  ln -sfn "$2" "$1/plugins/enabled/browser@5dive-browser"
}
CLI_STATE="$TMP/state-new"; mkcli "$CLI_STATE" "$ROOT/browser"
via_cli() { STATE_DIR="$1" 5dive browser "${@:2}"; }
HAVE_CLI=0; command -v 5dive >/dev/null 2>&1 && HAVE_CLI=1

N=0
# shot <runner...> -- <url>: a `read` (a verb that guards its page); sets RC ERR.
# VERB=shot sends the real `shot` instead (a verb with no page guard).
renders() { if [[ "${VERB:-read}" == shot ]]; then grep -c '^RENDER ' "$LOG"; else grep -c "^LOAD https://.*/[a-z]\$" "$LOG"; fi; }
shot() {
  local -a run=(); while [[ "$1" != -- ]]; do run+=("$1"); shift; done; shift
  N=$((N+1))
  if [[ "${VERB:-read}" == shot ]]; then
    "${run[@]}" shot "$@" --out="$TMP/s$N.png" >/dev/null 2>"$TMP/err"; RC=$?
  else
    mkdir -m 700 "$TMP/r$N"; "${run[@]}" read "$@" --out="$TMP/r$N" >/dev/null 2>"$TMP/err"; RC=$?
  fi
  ERR=$(cat "$TMP/err")
}

# ---------------------------------------------------------------- G1 direct
fresh
shot "$BROWSER" -- "https://$SITE/a"
arm 'G1 first shot renders'                              0 "$RC"
arm 'G1 ...and runs the front-page check once'           1 "$(checks $SITE)"
arm 'G1 ...and remembers the answer'                     yes "$([[ -f "$(MEMO $SITE)" ]] && echo yes || echo no)"
shot "$BROWSER" -- "https://$SITE/b"
shot "$BROWSER" -- "https://$SITE/c"
arm 'G1 three shots, ONE front-page check'               "0|1" "$RC|$(checks $SITE)"
arm 'G1 ...the third says it was not checked again'      yes "$(has 'not again now' "$ERR")"
arm 'G1 ...and still says no adapter confirmed the login' yes "$(has 'no adapter confirmed the noad.example.com login' "$ERR")"
arm 'G1 ...every page was read'                          3 "$(renders)"
arm 'G1 ...the memo is 0600 in the seat store'           600 "$(stat -c %a "$(MEMO $SITE)")"

# ---------------------------------------------------------------- G1 via the CLI
if (( HAVE_CLI )); then
  fresh
  for p in a b c; do shot via_cli "$CLI_STATE" -- "https://$SITE/$p"; done
  arm 'G1cli via `5dive browser`: three shots, ONE check' "0|1|3" "$RC|$(checks $SITE)|$(renders)"
  arm 'G1cli ...and the third says so'                    yes "$(has 'not again now' "$ERR")"
else
  echo 'SKIP: G1cli (no 5dive CLI on this host)'
fi

# ---------------------------------------------------------------- G2
fresh; ln -s .group-main "$SEAT/joined.example.com"; : > "$SEAT/.group-main/.5dive-page-joined.joined.example.com"
printf '%s' "$LIVE_DOM" > "$SEAT/.group-main/.fake-dom-page"
shot "$BROWSER" -- "https://joined.example.com/a"
shot "$BROWSER" -- "https://joined.example.com/b"
arm 'G2 a page-joined site: rendered, never checked'     "0|0" "$RC|$(checks joined.example.com)"
if (( HAVE_CLI )); then
  shot via_cli "$CLI_STATE" -- "https://joined.example.com/c"
  arm 'G2cli ...the same via `5dive browser`'            "0|0" "$RC|$(checks joined.example.com)"
fi

# ---------------------------------------------------------------- G3
fresh; printf '%s' "$DEAD_DOM" > "$SEAT/$SITE/.fake-dom-front"; printf '%s' "$DEAD_DOM" > "$SEAT/$SITE/.fake-dom-page"
shot "$BROWSER" -- "https://$SITE/a"; r1=$RC
shot "$BROWSER" -- "https://$SITE/b"
arm 'G3 signed out: both shots refuse'                   "75|75" "$r1|$RC"
arm 'G3 ...each one checked the front page'              2 "$(checks $SITE)"
arm 'G3 ...nothing read, nothing remembered'             "0|no" "$(renders)|$([[ -f "$(MEMO $SITE)" ]] && echo yes || echo no)"

# ---------------------------------------------------------------- G4
fresh
shot "$BROWSER" -- "https://$SITE/a"
printf '%s' "$DEAD_DOM" > "$SEAT/$SITE/.fake-dom-page"     # the session ends; the front page still looks fine
shot "$BROWSER" -- "https://$SITE/b"
arm 'G4 remembered, the page is a sign-in form: refused' 75 "$RC"
arm 'G4 ...by the page guard (no 2nd front-page check)'  1 "$(checks $SITE)"
arm 'G4 ...and the memo is dropped'                      no "$([[ -f "$(MEMO $SITE)" ]] && echo yes || echo no)"
shot "$BROWSER" -- "https://$SITE/c"
arm 'G4 ...so the next verb checks the front page again' "75|2" "$RC|$(checks $SITE)"

# ---------------------------------------------------------------- G5
fresh
for p in a b c; do FIVEDIVE_BROWSER_GENERIC_MEMO_TTL=0 shot "$BROWSER" -- "https://$SITE/$p"; done
arm 'G5 TTL=0: a check per verb, as before'              "0|3" "$RC|$(checks $SITE)"
arm 'G5 ...and no memo written'                          no "$([[ -f "$(MEMO $SITE)" ]] && echo yes || echo no)"

# ---------------------------------------------------------------- G6
fresh
shot "$BROWSER" -- "https://$SITE/a"
sed -i "s/^at=.*/at=$(( $(date +%s) - 1801 ))/" "$(MEMO $SITE)"
shot "$BROWSER" -- "https://$SITE/b"
arm 'G6 an expired memo is not used'                     "0|2" "$RC|$(checks $SITE)"

# ---------------------------------------------------------------- G7
fresh
shot "$BROWSER" -- "https://$SITE/a"
sed -i "s|^dir=.*|dir=$FIVEDIVE_BROWSER_PROFILE_ROOT/someone-else/$SITE|" "$(MEMO $SITE)"
shot "$BROWSER" -- "https://$SITE/b"
arm 'G7 a memo about another profile is not used'        "0|2" "$RC|$(checks $SITE)"

# ---------------------------------------------------------------- G8
fresh
shot "$BROWSER" -- "https://$SITE/a"
DISPLAY=:99 timeout 20 "$BROWSER" auth "$SITE" >/dev/null 2>&1
arm 'G8 auth drops the memo'                             no "$([[ -f "$(MEMO $SITE)" ]] && echo yes || echo no)"

# ---------------------------------------------------------------- G10
# shot has no page guard: the front-page check IS its guard, so it never skips it,
# even with a memo a read left.
fresh
shot "$BROWSER" -- "https://$SITE/a"
VERB=shot shot "$BROWSER" -- "https://$SITE/b"
VERB=shot shot "$BROWSER" -- "https://$SITE/c"
arm 'G10 shot (no page guard) checks every time, memo or not' "0|3" "$RC|$(checks $SITE)"

# ---------------------------------------------------------------- G9
if (( HAVE_CLI )) && git -C "$ROOT" rev-parse --verify -q origin/main >/dev/null; then
  OLD="$TMP/old"; mkdir -p "$OLD"
  git -C "$ROOT" archive origin/main browser | tar -x -C "$OLD"
  if grep -q '_generic_memo_age' "$OLD/browser/bin/browser"; then
    echo 'SKIP: G9 (origin/main already carries the memo)'
  else
    OLD_STATE="$TMP/state-old"; mkcli "$OLD_STATE" "$OLD/browser"
    fresh
    for p in a b c; do shot via_cli "$OLD_STATE" -- "https://$SITE/$p"; done
    arm 'G9 NEGATIVE CONTROL: origin/main via the CLI checks before every verb' "0|3" "$RC|$(checks $SITE)"
  fi
else
  echo 'SKIP: G9 (no CLI or no origin/main ref)'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
