#!/usr/bin/env bash
# DIVE-6646 — a phone at the login-link viewer gets the site's PHONE layout at
# about 1:1, not the 1280x800 desktop drawn at 0.3; and the browser is exactly
# as it was once the view ends.
#
#   U  lib/viewer-fit.cjs's rule, with no display: under 600 CSS px wide is a
#      phone and gets a fit; 600 and wider is a desktop and gets nothing
#   L  LIVE, when this machine has Xvfb and Chrome (GitHub's ubuntu runner does).
#      The product's own plain Chrome (bin/session-daemon --input, the login
#      view's launch: no CDP) on a 1280x800 Xvfb, showing a login page that
#      prints its innerWidth and its field and button heights in its title:
#        L1 before: the window is the desktop's: Chrome's own launch size on
#           this screen, and the page's innerWidth is that window's width
#        L2 a desktop viewer (1440x900): nothing printed, nothing saved, the
#           window untouched — the negative control
#        L3 a 390x700 phone: the window is 390 wide, the page switches to its
#           phone layout, and its field and button are >= 44 px tall ON THE
#           PHONE (CSS height x phone width / fitted width)
#        L4 the phone leaves (x11vnc exits): the holder gives the window back,
#           innerWidth is what it was before, the state file is gone
#        L5 the view is stopped instead (Done / revoke): `restore` gives it back;
#           two restores at once act once and neither errors
#   B  bin/browser: viewer-redeem takes --client=<W>x<H> and refuses anything
#      else before a ticket is read; the viewer's stop gives the window back
# VIEWER_FIT_ARTIFACTS=<dir>: the screen before, during and after (PNG).
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
FIT="$ROOT/browser/lib/viewer-fit.cjs"
X11LIB="$ROOT/browser/lib/x11.cjs"
DAEMON="$ROOT/browser/bin/session-daemon"
REAL_XVFB="$(command -v Xvfb || true)"
REAL_CHROME="$(command -v google-chrome || command -v chromium || command -v chromium-browser || true)"
[[ -n "${VIEWER_FIT_SKIP_LIVE:-}" ]] && REAL_CHROME=""
ART="${VIEWER_FIT_ARTIFACTS:-}"; [[ -n "$ART" ]] && mkdir -p "$ART"
TMP="$(mktemp -d /tmp/d6646.XXXXXX)"
_KILL=()
# Chrome is the daemon's child, not ours, and it is still writing its profile
# for a moment after the daemon goes: wait for every process on the profile to
# exit before the profile is removed, or rm races it ("Directory not empty").
cleanup() {
  local rc=$? p i
  for p in "${_KILL[@]}"; do kill "$p" 2>/dev/null; done
  pkill -f -- "--user-data-dir=$TMP/" 2>/dev/null
  for i in $(seq 1 50); do pgrep -f -- "--user-data-dir=$TMP/" >/dev/null || break; sleep 0.1; done
  pkill -KILL -f -- "--user-data-dir=$TMP/" 2>/dev/null
  for i in 1 2 3 4 5; do rm -rf "${TMP:-}" 2>/dev/null && break; sleep 0.2; done
  [[ -e "$TMP" ]] && rm -rf "$TMP"
  echo "HARNESS-RC=$rc"
}
trap cleanup EXIT

PASS=0; FAIL=0; SKIP=0
gha() {
  [[ "${GITHUB_ACTIONS:-}" == true ]] || return 0
  local m="$2"; m="${m//'%'/%25}"; m="${m//$'\n'/%0A}"
  printf '::error title=%s::%s\n' "${1//[:,]/ }" "$m"
}
arm() {  # arm <name> <expected> <got>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; gha "viewer fit: $1" "expected: $2 / got: $3"; fi
}

# ---------------------------------------------------------------- U: the rule
u=$(node -e '
const { phone } = require(process.argv[1]);
const r = (s) => { const p = phone(s); return p ? `${p.w}x${p.h}` : "-"; };
console.log(["390x700", "599x900", "600x900", "1440x900", "1024x768", "390", "abc", "390x10", "100x700", "390x700;x"].map(r).join(" "));
' "$FIT")
arm 'U1 under 600 px wide is a phone; 600 and up, and anything malformed, is not' \
  '390x700 599x900 - - - - - - - -' "$u"

# ------------------------------------------------------------- B: bin/browser
out=$("$BROWSER" viewer-redeem example.com --nonce=- --session=s1 --client='390x700;id' </dev/null 2>&1); rc=$?
arm 'B1 viewer-redeem refuses a --client that is not <W>x<H>, before anything else' \
  "64 expected <width>x<height>" "$rc $(grep -o 'expected <width>x<height>' <<<"$out")"
arm 'B2 the viewer stop gives the window back before it drops the pidfile' 1 \
  "$(awk '/^_viewer_stop\(\) \{/{p=1} p&&/_viewer_unfit "\$dir"/{n++} p&&/^}/{p=0} END{print n+0}' "$BROWSER")"
arm 'B3 the fit is applied only after the ticket is spent' 1 \
  "$(awk '/^cmd_viewer_redeem\(\) \{/{p=1} p&&/_viewer_revoke_file "\$dir" consumed/{c=NR} p&&/viewer_fit_lib\)" fit /{f=NR} p&&/^}/{p=0} END{print (c && f > c) ? 1 : 0}' "$BROWSER")"

# --------------------------------------------------------------- L: live
if [[ -z "$REAL_XVFB" || -z "$REAL_CHROME" ]]; then
  SKIP=$((SKIP+1)); printf 'SKIP: L live arms — this machine has no Xvfb (%s) or no Chrome (%s)\n' "${REAL_XVFB:-none}" "${REAL_CHROME:-none}"
else
  disp=""
  for n in $(seq 710 760); do [[ -e "/tmp/.X11-unix/X$n" ]] || { disp=$n; break; }; done
  "$REAL_XVFB" ":$disp" -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 & _KILL+=("$!")
  for i in $(seq 1 100); do [[ -e "/tmp/.X11-unix/X$disp" ]] && break; sleep 0.05; done
  # A login page the way most sites write one: desktop fields, and a phone
  # layout under 600 px with thumb-sized fields. It says what it is in its title.
  PAGE="$TMP/login.html"
  cat > "$PAGE" <<'HTML'
<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<title>x</title><style>
body{margin:0;font:14px sans-serif} form{width:360px;margin:80px auto}
input,button{display:block;width:100%;box-sizing:border-box;height:30px;margin:8px 0;font-size:13px}
@media (max-width:600px){ form{width:auto;margin:24px 16px} input,button{height:48px;font-size:17px} }
</style></head><body><form><input id=u placeholder=Email><input type=password placeholder=Password><button type=button id=b>Log in</button></form>
<script>
const say = () => { const h = (id) => Math.round(document.getElementById(id).getBoundingClientRect().height);
  document.title = 'w=' + innerWidth + ' in=' + h('u') + ' btn=' + h('b'); };
addEventListener('resize', say); say();
</script></body></html>
HTML
  LP="$TMP/lp"; mkdir -m 700 "$LP"
  DISPLAY=":$disp" FIVEDIVE_BROWSER_CHROME="$REAL_CHROME" FIVEDIVE_BROWSER_CHROME_ARGS="file://$PAGE" \
    "$DAEMON" serve "$LP" "$LP/s.sock" --input > "$TMP/l.ready" 2> "$TMP/l.err" &
  LD=$!; _KILL+=("$LD")
  for i in $(seq 1 600); do grep -q '^ready' "$TMP/l.ready" 2>/dev/null && break; kill -0 "$LD" 2>/dev/null || break; sleep 0.05; done
  title() { "$DAEMON" call "$LP/s.sock" <<<'{"op":"title"}' 2>/dev/null | jq -r .title; }
  # see <prefix> — poll the title until it starts with <prefix> (~10s), print it.
  see() { local t="" i; for i in $(seq 1 50); do t=$(title); [[ "$t" == "$1"* ]] && break; sleep 0.2; done; printf '%s' "$t"; }
  shot() { [[ -n "$ART" ]] || return 0; node -e '
    require(process.argv[1]).open(process.argv[2]).then(async (x) => { require("fs").writeFileSync(process.argv[3], await x.screenshotPNG()); x.close(); })' \
    "$X11LIB" ":$disp" "$ART/$1.png" 2>/dev/null; }
  num() { sed -n "s/.*$1=\([0-9]*\).*/\1/p" <<<"$2"; }
  ST="$TMP/fit.state"
  if ! grep -q '^ready' "$TMP/l.ready"; then
    arm 'L0 the live input daemon came up' ready "$(grep -v -i dbus "$TMP/l.err" | tail -2 | tr '\n' ' ')"
  else
    # Chrome is launched --window-size=1280,800 on a 1280x800 screen, and
    # Chromium never makes a window exactly a display's size (it takes 1 px off
    # each side, so a window manager does not read it as fullscreen): the
    # window is 1279x799. Measured on the runner, 2026-10-21 (run 39539598956).
    # So L1 asserts against the window this screen actually gives, read from X,
    # and L4/L5 still demand that exact state back.
    g0=$(node -e '
      require(process.argv[1]).open(process.argv[2]).then(async (x) => {
        const b = await x.browserWindow(); console.log(b ? `${b.g.w} ${b.g.h} ${x.width} ${x.height}` : "none"); x.close(); })' \
      "$X11LIB" ":$disp" 2>/dev/null)
    read -r w0 h0 sw sh <<<"$g0"
    t0=$(see "w=${w0:-x}")
    printf '   before: window %sx%s on a %sx%s screen, page %s\n' "${w0:-?}" "${h0:-?}" "${sw:-?}" "${sh:-?}" "$t0"
    whole=$( [[ "$w0" =~ ^[0-9]+$ && "$sw" =~ ^[0-9]+$ ]] && (( w0 >= sw - 1 && w0 <= sw && h0 >= sh - 1 && h0 <= sh )) && echo screen || echo "${g0:-none}")
    arm 'L1 before: the window is the desktop (the screen, less at most 1 px a side) and innerWidth is its width' \
      "screen w=$w0 in=30 btn=30" "$whole $t0"
    shot before

    out=$(node "$FIT" fit ":$disp" 1440x900 "$ST" 2>&1); sleep 0.5
    arm 'L2 a desktop viewer: nothing printed, nothing saved, the window untouched' \
      "|absent|$t0" "$out|$([[ -e "$ST" ]] && echo present || echo absent)|$(title)"

    out=$(node "$FIT" fit ":$disp" 390x700 "$ST" 2>&1)
    arm 'L3 a 390x700 phone: the window is fitted to it on the 1280x800 screen' \
      'fit=390x700 screen=1280x800' "$(tr '\n' ' ' <<<"$out" | sed 's/ $//')"
    t=$(see 'w=390')
    fw=$(sed -n 's/^fit=\([0-9]*\)x.*/\1/p' <<<"$out"); fw=${fw:-1280}
    printf '   phone view: %s, fitted width %s\n' "$t" "$fw"
    arm 'L3 ... the site sees a phone-wide window and uses its phone layout' 'w=390 in=48 btn=48' "$t"
    # On the phone the page is drawn at (phone width / fitted width) — the
    # viewer page's own scale. Before this change it was 390/1280.
    onphone=$(awk -v i="$(num in "$t")" -v b="$(num btn "$t")" -v fw="$fw" 'BEGIN{s=390/fw; printf "%d %d", i*s, b*s}')
    old=$(awk -v i="$(num in "$t0")" -v b="$(num btn "$t0")" 'BEGIN{s=390/1280; printf "%.0f %.0f", i*s, b*s}')
    printf '   on a 390-px phone: field and button %s px tall (before this change: %s px)\n' "$onphone" "$old"
    arm 'L3 ... and its field and button are at least 44 px tall on the phone' 'ok ok' \
      "$(for v in $onphone; do (( v >= 44 )) && printf 'ok ' || printf '%s ' "$v"; done | sed 's/ $//')"
    shot phone

    sleep 300 & vnc=$!                           # stands in for the viewer's x11vnc
    ( setsid node "$FIT" hold ":$disp" "$ST" "$vnc" </dev/null >/dev/null 2>&1 & )
    sleep 1
    arm 'L4 the holder keeps the fit while the person is there' 'w=390' "$(title | cut -d' ' -f1)"
    kill "$vnc"; wait "$vnc" 2>/dev/null
    t=$(see "$t0")
    arm 'L4 ... and when they leave, innerWidth is what it was before' "$t0" "$t"
    for i in $(seq 1 25); do [[ -e "$ST" ]] || break; sleep 0.2; done
    arm 'L4 ... and the state file is gone' absent "$([[ -e "$ST" ]] && echo present || echo absent)"
    shot after

    node "$FIT" fit ":$disp" 412x600 "$ST" >/dev/null 2>&1
    arm 'L5 a second phone view fits again' 'w=412' "$(see 'w=412' | cut -d' ' -f1)"
    node "$FIT" restore ":$disp" "$ST" 2>"$TMP/r1.err" & r1=$!
    node "$FIT" restore ":$disp" "$ST" 2>"$TMP/r2.err" & r2=$!
    wait "$r1"; e1=$?; wait "$r2"; e2=$?
    arm 'L5 ... the view stopped: two restores at once, neither errors' '0 0 ' "$e1 $e2 $(cat "$TMP/r1.err" "$TMP/r2.err")"
    arm 'L5 ... and the window is given back exactly' "$t0" "$(see "$t0")"
    node "$FIT" restore ":$disp" "$ST"; arm 'L5 ... a restore with nothing to restore is a no-op' 0 $?
  fi
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
