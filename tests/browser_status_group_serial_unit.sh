#!/usr/bin/env bash
# DIVE-7079 — `status` probes the sites of one sign-in group one after another,
# and a signed-in Shopify admin reads signed in.
#
# Dropshipping trial (DIVE-6902, 2026-10-26): google.com and shopify.com sat in
# the group Main, i.e. two links to ONE Chrome profile directory (DIVE-6013).
# `status` ran its probes side by side (DIVE-6582), so both Chromes opened that
# directory at once and the second died on SingletonLock ("File exists"). And
# shopify.com had no adapter, so the generic header check read the "Log in"
# link of shopify.com's public page while admin.shopify.com was signed in.
#
# Driven through the real bin/browser with a FAKE google-chrome first on PATH.
# The fake does what Chrome does with a profile: it takes <dir>/SingletonLock
# (a symlink, so `ln -s` fails with "File exists" when another instance holds
# it), holds it for 2 s, then prints the DOM for the URL it was given.
#
#   S1  ACCEPT: two sites in one group are never probed at once (no lock clash)
#   S2  ...and each prints its own verdict, in site order
#   S3  profiles that are NOT shared still run side by side (the DIVE-6582 win)
#   S4  NEGATIVE CONTROL: STATUS_BASELINE_BIN=<pre-fix bin/browser> must clash
#   A1  the shipped shopify.com adapter probes the admin, not the public site
#   A2  the logged-out render measured from a throwaway profile reads expired
#   A3  a signed-in admin render reads authenticated
#   A4  a Cloudflare check on admin.shopify.com itself reads UNKNOWN, not signed in
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
FX="$ROOT/tests/fixtures/dive-7079"

TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
unset BASH_ENV ENV

PASS=0; FAIL=0; SKIP=0
arm() {  # arm <name> <expected> <got>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi
}

export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/profiles"
export FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/adapters"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/no-rendezvous" FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/no-session-daemon"
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli" FIVEDIVE_BROWSER_WAKE_PRIV="$TMP/no-wake"
export FIVEDIVE_BROWSER_TMP_ROOT="$TMP/tmproot" FIVEDIVE_BROWSER_APPROVAL_DIR="$TMP/approvals"
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
export FIVEDIVE_BROWSER_STACK=off FIVEDIVE_BROWSER_STATUS_JOBS=3
export CLASH="$TMP/clashes" DOMS="$TMP/doms"
mkdir -p "$FIVEDIVE_BROWSER_ADAPTER_DIR" "$DOMS"; : > "$CLASH"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/google-chrome" <<'CHROME'
#!/usr/bin/env bash
[[ "${1:-}" == --version ]] && { echo 'Google Chrome 153.0.8010.36'; exit 0; }
d="" url=""
for a in "$@"; do case "$a" in --user-data-dir=*) d="${a#*=}" ;; http*) url="$a" ;; esac; done
d="${d%/}"
if [[ -n "$d" ]]; then
  mkdir -p "$d"
  if ! ln -s "fakehost-$$" "$d/SingletonLock" 2>/dev/null; then
    printf '%s\n' "$d" >> "$CLASH"
    echo "Failed to create $d/SingletonLock: File exists (17)" >&2
    exit 21
  fi
  trap 'rm -f "$d/SingletonLock"' EXIT
fi
[[ "$url" == about:blank || -z "$url" ]] && { echo '<html><body></body></html>'; exit 0; }
sleep 2
host="${url#*://}"; host="${host%%/*}"
cat "$DOMS/$host.html" 2>/dev/null || echo '<html><body>blank</body></html>'
CHROME
chmod +x "$TMP/bin/google-chrome"
export PATH="$TMP/bin:$PATH"

ME="$(id -un)"
SEAT="$FIVEDIVE_BROWSER_PROFILE_ROOT/$ME"
mkdir -p "$SEAT"; chmod 711 "$FIVEDIVE_BROWSER_PROFILE_ROOT"; chmod 700 "$SEAT"
mkdir -m 700 "$SEAT/.group-main"
ln -s .group-main "$SEAT/google.com"; ln -s .group-main "$SEAT/shopify.com"
mkdir -m 700 "$SEAT/x1.test" "$SEAT/x2.test"

# Every site gets a probe whose page answers signed in.
IN='<html><body><nav id="signed-in">home</nav></body></html>'
for s in google.com x1.test x2.test; do
  printf '{"site":"%s","probe":{"url":"https://%s/home","logged_out_when_dom_matches":"action=\\"/login\\"","logged_in_when_dom_matches":"id=\\"signed-in\\""}}' "$s" "$s" \
    > "$FIVEDIVE_BROWSER_ADAPTER_DIR/$s.json"
  printf '%s' "$IN" > "$DOMS/$s.html"
done
cp "$ROOT/browser/adapters/shopify.com.json" "$FIVEDIVE_BROWSER_ADAPTER_DIR/"
cp "$FX/shopify-signed-in.html" "$DOMS/admin.shopify.com.html"

st() {  # st <bin> [site] — sets OUT, RC, MS, CLASHES
  local t0; : > "$CLASH"; t0=$(date +%s%N)
  OUT=$(bash "$1" status ${2:+"$2"} 2>&1); RC=$?
  MS=$(( ($(date +%s%N) - t0) / 1000000 )); CLASHES=$(wc -l < "$CLASH" | tr -d ' ')
}
line() { grep -E "^  $1 " <<<"$OUT" | sed -E 's/^  [^ ]+ +//'; }
verdict() { line "$1" | grep -oE '^(authenticated|session expired|UNKNOWN|CHALLENGE|unconfirmed|BROKEN)' | head -1; }

# ================================================================ S1-S3
st "$BROWSER"
arm 'S1 ACCEPT: google.com and shopify.com (one group) were never probed at once' 0 "$CLASHES"
arm 'S1b ...and no line says SingletonLock' no "$(grep -q SingletonLock <<<"$OUT" && echo yes || echo no)"
arm 'S2 every site prints one line, in site order' 'google.com shopify.com x1.test x2.test' "$(grep -E '^  [a-z]' <<<"$OUT" | awk '{print $1}' | xargs)"
arm 'S2b google.com reads its own verdict' authenticated "$(verdict google.com)"
arm 'S2c shopify.com reads its own verdict' authenticated "$(verdict shopify.com)"
arm 'S2d all signed in, so status exits 0' 0 "$RC"
# Four 2 s probes: a series is 8 s; the group's two in series beside x1.test and
# x2.test is ~4 s. The group sorts FIRST, so the old loop starts both of its sites
# in its first batch of three, as on the trial box.
arm 'S3 the other profiles still run beside the group (well under the 8 s series)' yes \
  "$( (( MS < 6500 )) && echo yes || echo "no (${MS} ms)")"

# ================================================================ S4 (negative control)
if [[ -n "${STATUS_BASELINE_BIN:-}" && -f "${STATUS_BASELINE_BIN}" ]]; then
  st "$STATUS_BASELINE_BIN"
  arm 'S4 NEGATIVE (baseline build): its parallel loop opens the group twice at once' yes \
    "$( (( CLASHES > 0 )) && echo yes || echo "no ($CLASHES)")"
else
  SKIP=$((SKIP+1)); echo 'SKIP: S4 baseline build — set STATUS_BASELINE_BIN=<pre-7079 bin/browser>'
fi

# ================================================================ A (the Shopify adapter)
arm 'A1 the shopify.com adapter probes the admin, not the public site' 'https://admin.shopify.com/' \
  "$(jq -r .probe.url "$ROOT/browser/adapters/shopify.com.json")"
cp "$FX/shopify-signed-out-cloudflare.html" "$DOMS/admin.shopify.com.html"
st "$BROWSER" shopify.com
arm 'A2 the measured signed-out render (admin -> accounts login) reads expired' 'session expired' "$(verdict shopify.com)"
cp "$FX/shopify-signed-in.html" "$DOMS/admin.shopify.com.html"
st "$BROWSER" shopify.com
arm 'A3 a signed-in admin render reads authenticated' authenticated "$(verdict shopify.com)"
cp "$FX/shopify-admin-cloudflare.html" "$DOMS/admin.shopify.com.html"
FIVEDIVE_BROWSER_PROBE_WAIT_MS=800 st "$BROWSER" shopify.com
arm 'A4 a Cloudflare check on the admin itself reads UNKNOWN, not signed in' UNKNOWN "$(verdict shopify.com)"

printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
