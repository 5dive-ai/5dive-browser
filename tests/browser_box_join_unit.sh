#!/usr/bin/env bash
# DIVE-7168 — a seat's new site uses the OWNER's Google sign-in on the box, and the
# owner gets one line for each sign-in.
#
# Rerun box (10-28, browser 1.59.0): the owner's Google sign-in sat in the box
# seat's store (the Main group that `asks open shopify.com` served), Clicker's own
# Main was empty, so cjdropshipping.com opened in Clicker's PUBLIC profile and its
# "Continue with Google" asked for an email. The owner was sent a login link only
# to tap "Continue as Alex".
#
# Driven through the real bin/browser. One uid plays both seats: the box seat is
# this user, the agent is FIVEDIVE_BROWSER_SEAT=agent-borrower, and the root hop
# (`sudo -n … _join-offered`) is the FIVEDIVE_BROWSER_JOIN_PRIV seam.
#
#   B1  box Main holds an OFFERED shopify.com + google.com, the agent's own store
#       has nothing to share: `shot <new site url>` joins the site to the BOX's
#       Main, the box offers it (joined=page), the audit row names the agent, the
#       agent's own store gets no profile, and one line says so
#   B1b a second call resolves to the box login and is not joined again
#   B2  box Main holds sites but OFFERS none (no reach to share): no join, public
#   B3  the agent keeps its own profile of the site: no join
#   B4  the agent's `group default --none`: no join
#   B5  the agent's own Main holds a sign-in: DIVE-7076's own join wins, box untouched
#   B6  the named form (`shot <site> <url>`) joins the same way
#   B7  an IP host never joins
#   B8  `_join-offered` refuses the box seat itself, two sites, an IP, a known box login
#   B9  `_join-box` refuses a caller that is not the box seat, and a direct call
#   R1  an act whose step loop used Google's chooser: one line to the owner, which
#       site and which account; the seat's signins.jsonl has it
#   R2  the same sign-in again inside 15 minutes is not told twice
#   R3  no owner route: the agent is told to put the line in its report
#   R4  an act with no Google sign-in tells the owner nothing
#   G1  lib/google-signin.cjs stepGrant: allow pages give the account, stop and ask
#       pages and non-click steps give nothing
#   N1  NEGATIVE CONTROL: origin/main's bin/browser renders B1 in the public profile
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="${BOX_JOIN_BIN:-$ROOT/browser/bin/browser}"

TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0
arm() {  # arm <name> <expected> <got>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi
}
has() { if grep -qF -- "$1" <<<"$2"; then echo yes; else echo no; fi; }
yn() { if "$@"; then echo yes; else echo no; fi; }

export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/profiles"
export FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/adapters"; mkdir -p "$FIVEDIVE_BROWSER_ADAPTER_DIR"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/rv"
export FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/no-session-daemon"
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli"
export FIVEDIVE_BROWSER_TMP_ROOT="$TMP/tmproot"
export FIVEDIVE_BROWSER_NO_WAKE=1
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
ME="$(id -un)"
AG=agent-borrower
export FIVEDIVE_BROWSER_BOX_SEAT="$ME"
BOX="$FIVEDIVE_BROWSER_PROFILE_ROOT/$ME"
AGD="$FIVEDIVE_BROWSER_PROFILE_ROOT/$AG"
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
# The root hop: unprivileged, `_join-offered` takes the caller from FIVEDIVE_BROWSER_SEAT.
cat > "$FAKEBIN/join-priv" <<EOF2
#!/usr/bin/env bash
exec env FIVEDIVE_BROWSER_SEAT=$AG "$BROWSER" "\$@"
EOF2
chmod +x "$FAKEBIN/join-priv"
export FIVEDIVE_BROWSER_JOIN_PRIV="$FAKEBIN/join-priv"

# fresh [--unoffered] — the rerun box: the box seat's Main holds shopify.com
# (offered, the owner's `asks open`) and google.com; the agent's store is empty.
fresh() {
  rm -rf "$FIVEDIVE_BROWSER_PROFILE_ROOT" "$FIVEDIVE_BROWSER_SESSION_ROOT" "$SEEN"
  mkdir -p "$BOX" "$AGD" "$FIVEDIVE_BROWSER_SESSION_ROOT/$ME"
  chmod 711 "$FIVEDIVE_BROWSER_PROFILE_ROOT"; chmod 700 "$BOX" "$AGD"; chmod 710 "$FIVEDIVE_BROWSER_SESSION_ROOT/$ME"
  mkdir -m 700 "$BOX/.group-main"; printf 'Main\n' > "$BOX/.group-main/.5dive-group-name"
  ln -s .group-main "$BOX/google.com"; ln -s .group-main "$BOX/shopify.com"
  [[ "${1:-}" == --unoffered ]] || printf 'site=shopify.com\nowner=%s\n' "$ME" > "$FIVEDIVE_BROWSER_SESSION_ROOT/$ME/shopify.com.offered"
}
offer() { printf '%s/%s/%s.offered' "$FIVEDIVE_BROWSER_SESSION_ROOT" "$ME" "$1"; }
shot() {  # shot <args...> as the agent; RC, ERR, DIR
  rm -f "$SEEN" "$TMP/s.png"
  FIVEDIVE_BROWSER_SEAT=$AG "$BROWSER" shot "$@" --out="$TMP/s.png" >/dev/null 2>"$TMP/err"; RC=$?
  ERR=$(cat "$TMP/err"); DIR=$(readlink -f "$(cat "$SEEN" 2>/dev/null)" 2>/dev/null || true)
}
PUB() { readlink -f "$AGD/_public" 2>/dev/null || echo "$AGD/_public"; }
linked() { readlink "$1" 2>/dev/null || echo none; }

# ---------------------------------------------------------------- B1
b1_arms() {  # <label>
  arm "$1 the site is now a link into the BOX's Main"   .group-main "$(linked "$BOX/cjdropshipping.com")"
  arm "$1 ...the box offers it, marked joined by a page" "site=cjdropshipping.com|joined=page" "$(sed -n 's/^site=//p' "$(offer cjdropshipping.com)" 2>/dev/null | sed 's/^/site=/')|$(grep -x 'joined=page' "$(offer cjdropshipping.com)" 2>/dev/null)"
  arm "$1 ...the agent's own store got no profile"     no "$(yn test -e "$AGD/cjdropshipping.com" -o -L "$AGD/cjdropshipping.com")"
  arm "$1 ...it did not render in the public profile"  no "$(yn test "$DIR" == "$(PUB)")"
  arm "$1 ...one line says it joined the owner's browser" yes "$(has 'cjdropshipping.com joined the box'"'"'s Main (the owner'"'"'s browser)' "$ERR")"
}
fresh; shot https://cjdropshipping.com/register
b1_arms B1
arm 'B1 ...the line names the owner'"'"'s sign-ins and the record' 'yes|yes' "$(has 'sign-ins (google.com, shopify.com) count here' "$ERR")|$(has 'the owner gets one line for it' "$ERR")" 
arm 'B1 ...the audit row names the agent'             yes "$(has "page verb of $AG joined cjdropshipping.com to main" "$(cat "$BOX/.5dive-audit.jsonl" 2>/dev/null)")"
arm 'B1 ...the box group keeps the joined-by-a-page note' yes "$(yn test -f "$BOX/.group-main/.5dive-page-joined.cjdropshipping.com")"
B1ERR="$ERR"
shot https://cjdropshipping.com/register
arm 'B1b a second call: no second join line'          no "$(has 'joined the box' "$ERR")"
arm 'B1b ...and it is the box login now (brokered, not public)' "no|yes" "$(yn test "$DIR" == "$(PUB)")|$(has 'box' "$ERR")"

# ---------------------------------------------------------------- B2
fresh --unoffered; shot https://cjdropshipping.com/register
arm 'B2 nothing offered in the box Main: no join'     none "$(linked "$BOX/cjdropshipping.com")"
arm 'B2 ...rendered in the agent'"'"'s public profile' "0|$(PUB)" "$RC|$DIR"

# ---------------------------------------------------------------- B3
fresh; mkdir -m 700 "$AGD/cjdropshipping.com"; shot https://cjdropshipping.com/register
arm 'B3 the agent'"'"'s own profile: the box is not joined' "none|no" "$(linked "$BOX/cjdropshipping.com")|$(yn test -f "$(offer cjdropshipping.com)")"

# ---------------------------------------------------------------- B4
fresh; FIVEDIVE_BROWSER_SEAT=$AG "$BROWSER" group default --none >/dev/null 2>&1
shot https://cjdropshipping.com/register
arm 'B4 the agent'"'"'s group default --none: no join, public' "none|$(PUB)" "$(linked "$BOX/cjdropshipping.com")|$DIR"

# ---------------------------------------------------------------- B5
fresh; mkdir -m 700 "$AGD/.group-main"; printf 'Main\n' > "$AGD/.group-main/.5dive-group-name"; ln -s .group-main "$AGD/google.com"
shot https://cjdropshipping.com/register
arm 'B5 the agent'"'"'s own Main has a sign-in: its own join wins' ".group-main|none" "$(linked "$AGD/cjdropshipping.com")|$(linked "$BOX/cjdropshipping.com")"

# ---------------------------------------------------------------- B6
fresh; shot cjdropshipping.com https://cjdropshipping.com/register
b1_arms B6

# ---------------------------------------------------------------- B7
fresh; shot http://127.0.0.1:8080/
arm 'B7 an IP host never joins'                       no "$(yn test -f "$(offer 127.0.0.1)")"

# ---------------------------------------------------------------- B8
jo() { printf "$2" | FIVEDIVE_BROWSER_SEAT="$1" "$BROWSER" _join-offered >/dev/null 2>"$TMP/jerr"; echo $?; }
fresh
arm 'B8 _join-offered refuses the box seat itself (77)' 77 "$(jo "$ME" 'etsy.com\0')"
arm 'B8 ...two sites (64)'                             64 "$(jo $AG 'etsy.com\0ebay.com\0')"
arm 'B8 ...an IP (64)'                                 64 "$(jo $AG '10.0.0.1\0')"
arm 'B8 ...a site already a box login (77)'            77 "$(jo $AG 'shopify.com\0')"
arm 'B8 ...a seat with no store (77)'                  77 "$(jo agent-nostore 'etsy.com\0')"
arm 'B8 ...and none of these joined anything'          "none|none" "$(linked "$BOX/etsy.com")|$(linked "$BOX/ebay.com")"
arm 'B8 a good call joins (rc 0)'                      0 "$(jo $AG 'etsy.com\0')"

# ---------------------------------------------------------------- B9
fresh
FIVEDIVE_BROWSER_SEAT=$AG FIVEDIVE_BROWSER_ON_BEHALF_OF=$AG "$BROWSER" _join-box etsy.com >/dev/null 2>&1; rc=$?
arm 'B9 _join-box as an agent seat is refused (77)'    "77|none" "$rc|$(linked "$BOX/etsy.com")"
env -u FIVEDIVE_BROWSER_ON_BEHALF_OF FIVEDIVE_BROWSER_SEAT="$ME" "$BROWSER" _join-box etsy.com >/dev/null 2>&1; rc=$?
arm 'B9 ...and with no caller named (64)'              "64|none" "$rc|$(linked "$BOX/etsy.com")"

# ---------------------------------------------------------------- R1-R4
# A fake executor: it writes the act's after-page and, when SIGNIN is set, the
# line the real step loops print after a click on Google's chooser.
cat > "$FAKEBIN/driver" <<'DRV'
#!/usr/bin/env bash
plan=$(cat)
m=$(jq -r '.report.meta' <<<"$plan"); h=$(jq -r '.report.html' <<<"$plan")
printf '{"url":"https://example.com/done","title":"Done"}' > "$m"; printf '<html><body>ok</body></html>' > "$h"
[[ -n "${SIGNIN:-}" ]] && printf '%s\n' "5dive-google-signin: $SIGNIN" >&2
exit 0
DRV
chmod +x "$FAKEBIN/driver"
cat > "$FAKEBIN/cli" <<'CLI'
#!/usr/bin/env bash
[[ -n "${CLI_FAIL:-}" ]] && exit 1
printf '%s|' "$*" >> "$CLI_LOG"; cat >> "$CLI_LOG"; printf '\n' >> "$CLI_LOG"
CLI
chmod +x "$FAKEBIN/cli"
export CLI_LOG="$TMP/cli.log" FIVEDIVE_BROWSER_SAVED_CLI="$FAKEBIN/cli" FIVEDIVE_BROWSER_DRIVER="$FAKEBIN/driver"
export FIVEDIVE_BROWSER_APPROVAL_DIR="$TMP/approvals" FIVEDIVE_BROWSER_PUBLIC_KEEP=0 FIVEDIVE_BROWSER_ACT_KEEP=0
act() { FIVEDIVE_BROWSER_SEAT=$AG "$BROWSER" act https://example.com/ --steps='[{"op":"click","selector":"#x"}]' >/dev/null 2>"$TMP/aerr"; RC=$?; ERR=$(cat "$TMP/aerr"); }
fresh --unoffered; rm -f "$CLI_LOG"; rm -rf "$TMP/approvals"   # the public profile, so the act runs cold
SIGNIN='{"kind":"chooser","accounts":["alex@example.com"]}' act
arm "R1 act exits 0 ($(tail -2 <<<"$ERR" | tr "\n" " "))" 0 "$RC"
arm 'R1 ...the owner got one line: site and account'   "agent send owner --message-file=-|borrower signed in to example.com with your Google account alex@example.com (name and email only)." "$(cat "$CLI_LOG" 2>/dev/null)"
arm 'R1 ...and the agent is told it was sent'          yes "$(has 'the owner was told:' "$ERR")"
arm 'R1 ...signins.jsonl holds it'                     "example.com|alex@example.com|chooser" "$(jq -r '"\(.site)|\(.account)|\(.kind)"' "$TMP/approvals/signins.jsonl" 2>/dev/null)"
SIGNIN='{"kind":"basic-consent","accounts":["alex@example.com"]}' act
arm 'R2 the next step of the same sign-in is not told again' 1 "$(wc -l < "$CLI_LOG" | tr -d ' ')"
rm -rf "$TMP/approvals"; rm -f "$CLI_LOG"
CLI_FAIL=1 SIGNIN='{"kind":"continue","accounts":["alex@example.com"]}' act
arm 'R3 no owner route: the agent puts the line in its report' yes "$(has 'tell them in your report: borrower signed in to example.com' "$ERR")"
rm -rf "$TMP/approvals"; rm -f "$CLI_LOG"
SIGNIN='' act
arm 'R4 no Google sign-in in the act: nothing to the owner' "0|no" "$RC|$(yn test -s "$CLI_LOG")"

# ---------------------------------------------------------------- G1
g=$(node -e '
const g = require(process.argv[1]);
const pg = (url, html) => ({ url: () => url, content: async () => html });
const chooser = `<div data-identifier="alex@example.com">Alex</div><div data-identifier="bo@example.com">Bo</div>choose an account`;
(async () => {
  const out = [];
  let r = await g.stepGrant(pg("https://accounts.google.com/o/oauth2/auth/oauthchooseaccount?x=1", chooser), { op: "click", text: "alex@example.com" });
  out.push(r && r.kind + ":" + r.accounts.join(","));
  r = await g.stepGrant(pg("https://accounts.google.com/o/oauth2/auth/oauthchooseaccount?x=1", chooser), { op: "click", ref: "e3" });
  out.push(r && r.accounts.join(","));
  r = await g.stepGrant(pg("https://accounts.google.com/v3/signin/challenge/pwd", "<input type=password>"), { op: "click" });
  out.push(String(r));
  r = await g.stepGrant(pg("https://accounts.google.com/o/oauth2/auth/oauthchooseaccount?x=1", chooser), { op: "wait_for" });
  out.push(String(r));
  r = await g.stepGrant(pg("https://cjdropshipping.com/register", chooser), { op: "click" });
  out.push(String(r));
  console.log(out.join("|"));
})();' "$ROOT/browser/lib/google-signin.cjs" 2>&1)
arm 'G1 stepGrant: chooser click names the account it picked, else all; stops, waits and other sites give nothing' \
  "chooser:alex@example.com|alex@example.com,bo@example.com|null|null|null" "$g"

# ---------------------------------------------------------------- N1
if [[ -z "${BOX_JOIN_BIN:-}" ]]; then
  base="$TMP/base"; git -C "$ROOT" worktree add -q --detach "$base" "${BOX_JOIN_BASE:-origin/main}" 2>/dev/null \
    || git -C "$ROOT" archive "${BOX_JOIN_BASE:-origin/main}" browser | tar -x -C "$(mkdir -p "$base" && echo "$base")"
  if [[ -x "$base/browser/bin/browser" ]]; then
    BROWSER="$base/browser/bin/browser"
    fresh; shot https://cjdropshipping.com/register
    arm 'N1 NEGATIVE CONTROL: origin/main renders B1 in the public profile, nothing joined' "$(PUB)|none" "$DIR|$(linked "$BOX/cjdropshipping.com")"
    BROWSER="$ROOT/browser/bin/browser"
  else
    arm 'N1 NEGATIVE CONTROL: a base tree to run' yes no
  fi
  git -C "$ROOT" worktree remove --force "$base" >/dev/null 2>&1 || true
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
