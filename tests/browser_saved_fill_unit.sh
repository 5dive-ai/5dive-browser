#!/usr/bin/env bash
# DIVE-6844 — an agent types a login the owner saved, and never sees it.
#
# A step names the login ({"op":"fill",...,"saved":"<name>"}). The seat's act
# re-runs itself once through root, root reads the saved store and drops back
# to the seat with the values on a private fd, and every file the act leaves is
# scrubbed of them.
#
#   S  `act` through the real bin/browser and the real driver-playwright, with
#      the recording playwright stub from browser_plugin_unit.sh
#      S1 the value reaches page.fill exactly, and the act exits 0
#      S2 THE TRANSCRIPT ARM: the value is in none of act's stdout, stderr,
#         page.html, page.md, tree.json, and no page.png is kept, though the
#         page the stub returns shows it (the scrub ran: [saved] is there)
#      S3 no jq (or any process the act ran) had the value on its command line
#      S4 no fd: the act re-runs itself through the sudo rail, with names only
#      S5 a step that is not fill/type, a saved step that also has a value, a
#         bad name, --record, and a value that did not arrive: each refused,
#         nothing typed
#      S6 a seat with no sudo for it is told what to ask the owner for
#      S7 a saved value for another site is not typed on this page (the
#         executor checks the page it is on, not the act's first URL)
#   V  DIVE-6973, root's half through its unprivileged seam and a stub CLI
#      V1 a login pair fills by field (<name>.login, <name>.password) through
#         `secret _reveal`; no value on any argv or output; bound by ITEM
#      V2 an old one-value item still fills by its bare name
#      V3 <name>.2fa types the current 6-digit code, never the seed; the scrub
#         masks the code
#      V4 a CLI with no _reveal (or none at all): the plain store, read directly
#      V5 nothing saved: the refusal names the Vault and login-ask, never chat
#      V6 a bound item on another site is refused before the Vault is read
#      V7 an unknown field is refused
#   R  root's half, where this machine has passwordless sudo (CI has it)
#      R1 sudo act: root reads the store, the seat types the value
#      R2 a name with nothing saved: refused, says where the owner saves one
#      R3 the first use binds the value to the site the act starts on; an act
#         that starts on another site is refused, and nothing is typed
#   L  LIVE, where this machine has Chrome and playwright-core (CI installs it)
#      L1 a local sign-in page: act fills the username and the SAVED password,
#         submits, and the site says signed in; the site got the exact value
#      L2 the value appears 0 times in act's output and its artifacts
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"

TMP="$(mktemp -d /tmp/d6844.XXXXXX)"
_KILL=()
trap 'rc=$?; for p in "${_KILL[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0; SKIP=0
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
ex() { [[ -e "$1" ]] && echo yes || echo no; }
run() { local o="$TMP/.o" e="$TMP/.e"; "$@" >"$o" 2>"$e"; RC=$?; OUT=$(cat "$o"); ERR=$(cat "$e"); return 0; }
# leaks <value> <text|dir>... — how many places hold the value, raw or escaped.
leaks() {
  local v="$1" n=0 f x; shift
  local -a forms=("$v" "$(jq -Rr '@json' <<<"$v" | sed 's/^"//; s/"$//')" "$(printf '%s' "$v" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')")
  for x in "$@"; do
    if [[ -d "$x" ]]; then
      while IFS= read -r -d '' f; do for v in "${forms[@]}"; do grep -qF -- "$v" "$f" && n=$((n+1)); done; done < <(find "$x" -type f -print0)
    else
      for v in "${forms[@]}"; do [[ "$x" == *"$v"* ]] && n=$((n+1)); done
    fi
  done
  echo "$n"
}

SECRET='Pa55-<&"word> one'          # a test value: quote, angle brackets, ampersand, space
SECRET_JSON='{"linkedin-password":{"value":"Pa55-<&\"word> one","host":"login.test"}}'
OTHER_JSON='{"linkedin-password":{"value":"Pa55-<&\"word> one","host":"other.test"}}'

# ================================================================ S  act, cold
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
export FIVEDIVE_BROWSER_EXPECT_WAIT_MS=0
mkdir -p "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT"
chmod 711 "$FIVEDIVE_BROWSER_PROFILE_ROOT"; chmod 700 "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT"

FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == --version ]] && { echo "Google Chrome 153"; exit 0; }\necho "<html><body>public</body></html>"\n' > "$FAKEBIN/google-chrome"
chmod +x "$FAKEBIN/google-chrome"
# Every jq the act runs logs its command line first, for S3.
REALJQ="$(command -v jq)"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$TMP/jq-argv.log" "$REALJQ" > "$FAKEBIN/jq"
chmod +x "$FAKEBIN/jq"
REALPATH="$PATH"
export PATH="$FAKEBIN:$PATH"

# THE STUB, from the main suite, so the two cannot grade two different stubs.
PWROOT="$TMP/pw"; mkdir -p "$PWROOT/node_modules/playwright-core"
printf '{ "name": "playwright-core", "version": "0.0.0-stub", "main": "index.js" }\n' > "$PWROOT/node_modules/playwright-core/package.json"
sed -n "/^cat > \"\$PWROOT\/node_modules\/playwright-core\/index.js\" <<'PWJS'$/,/^PWJS$/p" tests/browser_plugin_unit.sh \
  | sed '1d;$d' > "$PWROOT/node_modules/playwright-core/index.js"
arm 'S0 (anchor) the stub was extracted, recording fill values' yes \
  "$(grep -q "rec({ call: 'fill', sel, val })" "$PWROOT/node_modules/playwright-core/index.js" && echo yes || echo no)"
export NODE_PATH="$PWROOT/node_modules"
export PWREC="$TMP/pw.jsonl"; : > "$PWREC"
# The page the steps leave SHOWS the value (a login typed in a plain field), in
# its HTML, its text and its tree, so a scrub that did not run would leak it.
export PWHTML="<html><body><form><input id=\"pw\" value=\"$(printf '%s' "$SECRET" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')\"><p>typed: $SECRET</p></form></body></html>"
export PWTEXT="typed: $SECRET"
jq -nc --arg v "$SECRET" '{nodes:[{ref:"textbox/Password",role:"textbox",name:"Password",value:$v}],marker:"m-1"}' > "$TMP/walk.json"
export PWWALK="$TMP/walk.json"

URL="https://login.test/signin"
STEPS='[{"op":"fill","selector":"#user","value":"sam"},{"op":"fill","selector":"#pw","saved":"linkedin-password"},{"op":"click","selector":"#go"}]'

: > "$TMP/jq-argv.log"
run env FIVEDIVE_BROWSER_SAVED_FD=3 "$BROWSER" act "$URL" --steps="$STEPS" --out="$TMP/s1" 3< <(printf '%s' "$SECRET_JSON")
arm 'S1a act exits 0' 0 "$RC"
[[ "$RC" == 0 ]] || gha 'S1 act output' "$OUT $ERR"
arm 'S1b the saved value reached page.fill on #pw, exactly' "$SECRET" \
  "$(jq -r 'select(.call == "fill" and .sel == "#pw") | .val' "$PWREC" 2>/dev/null | head -1)"
arm 'S1c the plain value still went in as given' sam "$(jq -r 'select(.call == "fill" and .sel == "#user") | .val' "$PWREC" 2>/dev/null | head -1)"
arm 'S2a the value is in none of stdout, stderr or the artifacts' 0 "$(leaks "$SECRET" "$OUT" "$ERR" "$TMP/s1")"
arm 'S2b the scrub ran on a page that showed it (the mask is in page.html)' yes "$(grep -qF '[saved]' "$TMP/s1/page.html" 2>/dev/null && echo yes || echo no)"
arm 'S2c no picture is kept' no "$(ex "$TMP/s1/page.png")"
arm 'S2d the name is all the act says about it' 0 "$(leaks "$SECRET" "$(cat "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT"/*/.5dive-audit.jsonl 2>/dev/null)")"
arm 'S3 no jq the act ran had the value on its command line' 0 "$(leaks "$SECRET" "$(cat "$TMP/jq-argv.log")")"
arm 'S3b ...and the log did record the act'"'"'s jq calls (the shim was live)' yes "$([[ -s "$TMP/jq-argv.log" ]] && echo yes || echo no)"

# S4: no fd -> the act goes through the sudo rail once, carrying names only.
cat > "$TMP/sudo-rail" <<RAIL
#!/usr/bin/env bash
# What root's half does, minus root: hand the values back on fd 3.
printf '%s\n' "\$*" > "$TMP/rail-args"
FIVEDIVE_BROWSER_SAVED_FD=3 exec "$BROWSER" "\$@" 3< <(printf '%s' '$SECRET_JSON')
RAIL
chmod +x "$TMP/sudo-rail"
: > "$PWREC"
run env FIVEDIVE_BROWSER_SAVED_SUDO="$TMP/sudo-rail" "$BROWSER" act "$URL" --steps="$STEPS" --out="$TMP/s4"
arm 'S4a with no fd, act re-runs through the rail and exits 0' 0 "$RC"
arm 'S4b the rail got "act" and the same arguments, which hold the name and not the value' "yes 0" \
  "$(has 'https://login.test/signin --steps=' "$(sed -n 1p "$TMP/rail-args" 2>/dev/null | grep '^act ')") $(leaks "$SECRET" "$(cat "$TMP/rail-args" 2>/dev/null)")"
arm 'S4c ...and the value was typed' "$SECRET" "$(jq -r 'select(.call == "fill" and .sel == "#pw") | .val' "$PWREC" 2>/dev/null | head -1)"

# S5: what is refused, each before anything is typed.
s5() {  # s5 <steps> [extra act args...]
  : > "$PWREC"; local st="$1"; shift
  run env FIVEDIVE_BROWSER_SAVED_FD=3 "$BROWSER" act "$URL" --steps="$st" --out="$TMP/s5" "$@" 3< <(printf '%s' "$SECRET_JSON")
  printf '%s %s' "$([[ "$RC" != 0 ]] && echo refused || echo ran)" "$([[ -s "$PWREC" ]] && grep -q '"call":"fill"' "$PWREC" && echo typed || echo untyped)"
}
arm 'S5a a saved click is refused' 'refused untyped' "$(s5 '[{"op":"click","selector":"#go","saved":"linkedin-password"}]')"
arm 'S5b a saved step with a value of its own is refused' 'refused untyped' "$(s5 '[{"op":"fill","selector":"#pw","saved":"linkedin-password","value":"x"}]')"
arm 'S5c a bad name is refused' 'refused untyped' "$(s5 '[{"op":"fill","selector":"#pw","saved":"../etc"}]')"
arm 'S5d --record with a saved step is refused' 'refused untyped' "$(s5 "$STEPS" --record=signin)"
arm 'S5e a name root did not hand over: nothing typed' 'refused untyped' "$(s5 '[{"op":"fill","selector":"#pw","saved":"github-token"}]')"
arm 'S5f ...and the refusal names no value' 0 "$(leaks "$SECRET" "$OUT" "$ERR")"

# S6: the real rail, on a seat sudo refuses: the probe says no, nothing runs.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 1\n' "$TMP/sudo-log" > "$FAKEBIN/sudo"; chmod +x "$FAKEBIN/sudo"
: > "$PWREC"
run "$BROWSER" act "$URL" --steps="$STEPS" --out="$TMP/s6"
arm 'S6a no grant: refused, tells the agent to ask the owner, types nothing' 'yes yes no' \
  "$([[ "$RC" != 0 ]] && echo yes || echo no) $(has 'Ask the owner to make it an admin agent' "$ERR") $(grep -q '"call":"fill"' "$PWREC" && echo yes || echo no)"
arm 'S6b it only asked sudo -l (a refused sudo mails root)' '-n -l /usr/local/bin/5dive browser act' "$(head -1 "$TMP/sudo-log" 2>/dev/null)"
rm -f "$FAKEBIN/sudo"

# S7: the value is for other.test; the page is on login.test.
: > "$PWREC"
run env FIVEDIVE_BROWSER_SAVED_FD=3 "$BROWSER" act "$URL" --steps="$STEPS" --out="$TMP/s7" 3< <(printf '%s' "$OTHER_JSON")
arm 'S7a a value for another site: the step fails, saying which site it is for' 'yes yes' \
  "$([[ "$RC" != 0 ]] && echo yes || echo no) $(has 'this saved login is for other.test' "$ERR")"
arm 'S7b ...and it was never typed' no "$(grep -q '"sel":"#pw"' "$PWREC" && echo yes || echo no)"
arm 'S7c ...and the refusal names no value' 0 "$(leaks "$SECRET" "$OUT" "$ERR" "$TMP/s7")"

# ================================================================ V  Vault v2 (DIVE-6973)
# Root's half, run unprivileged through its test seam (it reads only what this
# user can), against a stub CLI that answers `secret _reveal` as the contract
# says: {"<ref>":"<plaintext>"}, the .2fa ref as the base32 seed.
VCON="$TMP/vcon"; mkdir -p "$VCON"; chmod 700 "$VCON"
VPASS='Gh-<&"pass> 9'
VLOGIN='sam@example.com'
VSEED='JBSWY3DPEHPK3PXP'
jq -nc --arg l "$VLOGIN" --arg p "$VPASS" --arg s "$VSEED" --arg v "$SECRET" \
  '{"github.login":$l, "github.password":$p, "github.2fa":$s, "linkedin-password":$v}' > "$TMP/vault.json"
cat > "$TMP/fake-5dive" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE5_LOG"
[[ "${1:-}" == secret && "${2:-}" == _reveal ]] || { echo "error: unknown command" >&2; exit 2; }
[[ -f "$FAKE5_CTL.old" ]] && { echo "error: unknown secret command: _reveal (write|link|saved|serve)" >&2; exit 2; }
shift 2; agent="" host="" refs=()
for a in "$@"; do case "$a" in --agent=*) agent="${a#*=}" ;; --host=*) host="${a#*=}" ;; *) refs+=("$a") ;; esac; done
miss=""; for r in "${refs[@]}"; do jq -e --arg r "$r" 'has($r)' "$FAKE5_VAULT" >/dev/null || miss+="${miss:+, }$r"; done
[[ -z "$miss" ]] || { echo "error: nothing is saved as $miss" >&2; exit 4; }
printf '%s %s %s\n' "$(printf '%s\n' "${refs[@]}" | sed 's/\..*//' | sort -u | tr '\n' ',')" "$host" "$agent" >> "$FAKE5_USAGE"
printf '%s\n' "${refs[@]}" | jq -R . | jq -sc --slurpfile v "$FAKE5_VAULT" 'map({(.): $v[0][.]}) | add'
SH
chmod +x "$TMP/fake-5dive"
cat > "$TMP/seam-rail" <<RAIL
#!/usr/bin/env bash
# What sudo does, minus root: root's half through its unprivileged test seam.
# Once: a bin with no seam would come straight back here, forever.
[[ -z "\${SEAM_RAIL_ONCE:-}" ]] || { echo "the rail was re-entered: root's half did not run" >&2; exit 70; }
printf '%s\n' "\$*" > "$TMP/seam-rail-args"
SEAM_RAIL_ONCE=1 FIVEDIVE_BROWSER_SAVED_ROOT_SEAM=1 exec "$BROWSER" "\$@"
RAIL
chmod +x "$TMP/seam-rail"
export FAKE5_LOG="$TMP/fake5.log" FAKE5_CTL="$TMP/fake5" FAKE5_VAULT="$TMP/vault.json" FAKE5_USAGE="$TMP/fake5.usage"
vact() {  # vact <url> <steps> <out>
  : > "$PWREC"; : > "$FAKE5_LOG"; : > "$TMP/jq-argv.log"
  run env FIVEDIVE_BROWSER_SAVED_SUDO="$TMP/seam-rail" FIVEDIVE_BROWSER_SAVED_CLI="${VCLI:-$TMP/fake-5dive}" \
    FIVEDIVE_BROWSER_CONNECTORS_DIR="$VCON" FIVEDIVE_BROWSER_TOTP_MIN_LEFT_S=0 "$BROWSER" act "$1" --steps="$2" --out="$3"
}
filled() { jq -r --arg s "$1" 'select(.call == "fill" and .sel == $s) | .val' "$PWREC" 2>/dev/null | head -1; }
htmlesc() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }

# V1: a login pair, by field. The page shows both values back.
export PWHTML="<html><body><input id=\"user\" value=\"$(htmlesc "$VLOGIN")\"><input id=\"pw\" value=\"$(htmlesc "$VPASS")\"><p>typed: $VPASS</p></body></html>"
export PWTEXT="typed: $VPASS"
VSTEPS='[{"op":"fill","selector":"#user","saved":"github.login"},{"op":"fill","selector":"#pw","saved":"github.password"},{"op":"click","selector":"#go"}]'
vact "$URL" "$VSTEPS" "$TMP/v1"
arm 'V1a a pair item fills by field: rc 0' 0 "$RC"
[[ "$RC" == 0 ]] || gha 'V1 act output' "$OUT $ERR"
arm 'V1b <name>.login reached #user, <name>.password reached #pw' "$VLOGIN|$VPASS" "$(filled '#user')|$(filled '#pw')"
arm 'V1c root asked _reveal for the refs, as the seat, for the start host' "yes yes" \
  "$(has "secret _reveal --agent=$SEAT --host=login.test github.login github.password" "$(cat "$FAKE5_LOG")") $(has "github, login.test $SEAT" "$(tr -d '\n' < "$FAKE5_USAGE" 2>/dev/null | sed 's/,,/, /')")"
arm 'V1d the password is in none of stdout, stderr, the artifacts, any jq argv or the CLI argv' 0 \
  "$(leaks "$VPASS" "$OUT" "$ERR" "$TMP/v1" "$(cat "$TMP/jq-argv.log")" "$(cat "$FAKE5_LOG")" "$(cat "$TMP/seam-rail-args")")"
arm 'V1e the scrub ran on the page that showed them' yes "$(grep -qF '[saved]' "$TMP/v1/page.html" 2>/dev/null && echo yes || echo no)"
arm 'V1f the binding is by ITEM, not by field' 'GITHUB=login.test' "$(cat "$VCON/saved.hosts" 2>/dev/null)"

# V2: an old one-value item still fills by its bare name, through the same hop.
export PWHTML="<html><body><input id=\"pw\" value=\"$(htmlesc "$SECRET")\"></body></html>" PWTEXT="x"
vact "$URL" '[{"op":"fill","selector":"#pw","saved":"linkedin-password"}]' "$TMP/v2"
arm 'V2 a bare name (one-value item) still fills: rc, value' "0|$SECRET" "$RC|$(filled '#pw')"

# V3: .2fa types the current 6-digit code, never the seed. The page shows this
# window's and the next window's code, so whichever root computed is on it.
codes() { node -e 'const t=require(process.argv[1]); const s=t.base32Decode(process.argv[2]); const n=Date.now();
  console.log([-30000,0,30000].map(d=>t.codeAt(s,n+d)).join(" "))' "$ROOT/browser/lib/totp.cjs" "$VSEED"; }
read -r _ C0 C1 <<<"$(codes)"
export PWHTML="<html><body><input id=\"otp\" value=\"$C0\"><p>code $C0 $C1</p></body></html>" PWTEXT="code $C0 $C1"
vact "$URL" '[{"op":"fill","selector":"#otp","saved":"github.2fa"}]' "$TMP/v3"
TYPED="$(filled '#otp')"; read -r CP CN CX <<<"$(codes)"
arm 'V3a .2fa: rc 0 and a 6-digit code was typed' "0 yes" "$RC $([[ "$TYPED" =~ ^[0-9]{6}$ ]] && echo yes || echo no)"
arm 'V3b ...the code is the seed'"'"'s current one (this window or the last)' yes \
  "$([[ -n "$TYPED" && " $CP $CN $CX " == *" $TYPED "* ]] && echo yes || echo no)"
arm 'V3c the seed was never typed and is in no output, artifact, jq argv or rail argv' "no 0" \
  "$(grep -qF "$VSEED" "$PWREC" && echo yes || echo no) $(leaks "$VSEED" "$OUT" "$ERR" "$TMP/v3" "$(cat "$TMP/jq-argv.log")" "$(cat "$TMP/seam-rail-args")")"
arm 'V3d the scrub masks the typed code (0 left in output and artifacts, [saved] in page.html)' "0 yes" \
  "$(leaks "${TYPED:-none}" "$OUT" "$ERR" "$TMP/v3") $(grep -qF '[saved]' "$TMP/v3/page.html" 2>/dev/null && echo yes || echo no)"
arm 'V3e ...and the code was on no jq command line' 0 "$(leaks "${TYPED:-none}" "$(cat "$TMP/jq-argv.log")")"

# V4: a CLI that predates _reveal -> the plain store, read directly; no CLI at all too.
printf 'LINKEDIN_PASSWORD=%s\nGITHUB__LOGIN=%s\nGITHUB__PASSWORD=%s\n' "$SECRET" "$VLOGIN" "$VPASS" > "$VCON/saved.env"; chmod 600 "$VCON/saved.env"
: > "$FAKE5_CTL.old"
vact "$URL" "$VSTEPS" "$TMP/v4"
arm 'V4a old CLI (no _reveal): falls back to the plain store, fills the pair' "0|$VLOGIN|$VPASS" "$RC|$(filled '#user')|$(filled '#pw')"
arm 'V4b ...it did ask _reveal first' yes "$(has 'secret _reveal' "$(cat "$FAKE5_LOG")")"
VCLI="$TMP/no-such-5dive" vact "$URL" '[{"op":"fill","selector":"#pw","saved":"linkedin-password"}]' "$TMP/v4b"
arm 'V4c no CLI at all: the plain store, bare name' "0|$SECRET" "$RC|$(filled '#pw')"
printf 'LINKEDIN_PASSWORD=v1:U2FsdGVkX1+abc\n' > "$VCON/saved.env"
VCLI="$TMP/no-such-5dive" vact "$URL" '[{"op":"fill","selector":"#pw","saved":"linkedin-password"}]' "$TMP/v4c"
arm 'V4d an encrypted value with no CLI to open it: refused, nothing typed, ciphertext not typed' "yes no" \
  "$([[ "$RC" != 0 ]] && echo yes || echo no) $(grep -q '"call":"fill"' "$PWREC" && echo yes || echo no)"
rm -f "$FAKE5_CTL.old" "$VCON/saved.env"

# V5: nothing saved: refused, pointing at the Vault and login-ask, never at chat.
: > "$FAKE5_USAGE"
vact "https://other.test/signin" '[{"op":"fill","selector":"#pw","saved":"gitlab.password"}]' "$TMP/v5"
arm 'V5a nothing saved: refused, names the Vault and login-ask, types nothing, no usage line' "yes yes yes no 0" \
  "$([[ "$RC" != 0 ]] && echo yes || echo no) $(has 'Vault' "$ERR") $(has '5dive browser login-ask other.test' "$ERR") $(grep -q '"call":"fill"' "$PWREC" && echo yes || echo no) $(wc -l < "$FAKE5_USAGE")"
arm 'V5b ...and it never tells the agent to ask for the password in chat' "no no" \
  "$(has 'send me the password' "${ERR,,}") $(has 'пришли пароль' "$ERR")"

# V6: the item is bound to login.test; a pair field on another site is refused
# before anything is read, so no usage line is written.
vact "https://evil.test/form" '[{"op":"fill","selector":"#pw","saved":"github.password"}]' "$TMP/v6"
arm 'V6 a bound item on another site: refused, no _reveal, nothing typed' "yes yes no no" \
  "$([[ "$RC" != 0 ]] && echo yes || echo no) $(has 'login for login.test' "$ERR") $(has '_reveal' "$(cat "$FAKE5_LOG")") $(grep -q '"call":"fill"' "$PWREC" && echo yes || echo no)"

# V7: a field that is not one of the three, or a dangling dot: refused up front.
arm 'V7a "github.token" is refused' 'refused untyped' "$(s5 '[{"op":"fill","selector":"#pw","saved":"github.token"}]')"
arm 'V7b "github." is refused' 'refused untyped' "$(s5 '[{"op":"fill","selector":"#pw","saved":"github."}]')"
unset PWHTML PWTEXT

# ================================================================ R  root's half
if [[ $EUID -ne 0 ]] && sudo -n true 2>/dev/null; then
  CON="$TMP/connectors"; sudo mkdir -p "$CON"
  printf 'OTHER=keep\nLINKEDIN_PASSWORD=%s\n' "$SECRET" | sudo tee "$CON/saved.env" >/dev/null
  sudo chmod 600 "$CON/saved.env"
  rootact() {
    : > "$PWREC"
    run sudo env SUDO_USER="$SEAT" FIVEDIVE_BROWSER_CONNECTORS_DIR="$CON" PATH="$PATH" NODE_PATH="$NODE_PATH" PWREC="$PWREC" \
      PWHTML="$PWHTML" PWTEXT="$PWTEXT" PWWALK="$PWWALK" \
      $(env | grep -oE '^FIVEDIVE_BROWSER_[A-Z_]+=' | sed 's/=$//' | while read -r k; do printf '%s=%s ' "$k" "${!k}"; done) \
      "$BROWSER" act "$URL" --steps="$1" --out="$TMP/r1"
  }
  rootact "$STEPS"
  arm 'R1a sudo act: root reads the store, the seat types it (rc 0)' 0 "$RC"
  [[ "$RC" == 0 ]] || gha 'R1 output' "$OUT $ERR"
  arm 'R1b the value typed is the one saved' "$SECRET" "$(jq -r 'select(.call == "fill" and .sel == "#pw") | .val' "$PWREC" 2>/dev/null | head -1)"
  arm 'R1c the artifacts are the seat'"'"'s, and hold no value' "$SEAT 0" "$(stat -c %U "$TMP/r1/page.html" 2>/dev/null) $(leaks "$SECRET" "$OUT" "$ERR" "$TMP/r1")"
  rootact '[{"op":"fill","selector":"#pw","saved":"github-token"}]'
  arm 'R2 nothing saved under the name: refused, names the app, types nothing' 'yes yes no' \
    "$([[ "$RC" != 0 ]] && echo yes || echo no) $(has 'Vault' "$ERR") $(grep -q '"call":"fill"' "$PWREC" && echo yes || echo no)"
  arm 'R3a the first use bound the value to the site it started on' 'LINKEDIN_PASSWORD=login.test' "$(sudo cat "$CON/saved.hosts" 2>/dev/null)"
  : > "$PWREC"
  run sudo env SUDO_USER="$SEAT" FIVEDIVE_BROWSER_CONNECTORS_DIR="$CON" PATH="$PATH" NODE_PATH="$NODE_PATH" PWREC="$PWREC" \
    $(env | grep -oE '^FIVEDIVE_BROWSER_[A-Z_]+=' | sed 's/=$//' | while read -r k; do printf '%s=%s ' "$k" "${!k}"; done) \
    "$BROWSER" act "https://evil.test/form" --steps='[{"op":"fill","selector":"#pw","saved":"linkedin-password"}]' --out="$TMP/r3"
  arm 'R3b an act starting on another site is refused, names the right one, types nothing' 'yes yes no' \
    "$([[ "$RC" != 0 ]] && echo yes || echo no) $(has 'login for login.test' "$ERR") $(grep -q '"call":"fill"' "$PWREC" && echo yes || echo no)"
  sudo rm -rf "$CON"
else
  SKIP=$((SKIP+1)); echo 'SKIP: R root half — no passwordless sudo here (CI has it)'
fi

# ================================================================ L  LIVE
REAL_CHROME="$(PATH="$REALPATH" command -v google-chrome || PATH="$REALPATH" command -v chromium || true)"
PW_OK=no; [[ -d "$ROOT/browser/node_modules/playwright-core" ]] && PW_OK=yes
if [[ -z "$REAL_CHROME" || "$PW_OK" != yes ]]; then
  SKIP=$((SKIP+1)); printf 'SKIP: L live arm — chrome: %s, playwright-core next to the plugin: %s\n' "${REAL_CHROME:-none}" "$PW_OK"
else
  # A sign-in page: a username field, a password field, a button. It records the
  # password it was sent, and answers "Signed in as <user>" only to the right one.
  cat > "$TMP/site.cjs" <<'JS'
const http = require('http'), fs = require('fs');
const [want, logf] = process.argv.slice(2);
http.createServer((req, res) => {
  res.setHeader('content-type', 'text/html');
  if (req.method === 'POST' && req.url === '/signin') {
    let b = ''; req.on('data', (d) => b += d); req.on('end', () => {
      const f = new URLSearchParams(b); fs.writeFileSync(logf, f.get('password') || '');
      res.end(f.get('password') === want ? `<html><body><h1>Signed in as ${f.get('user')}</h1></body></html>`
                                           : '<html><body><h1>Wrong password</h1></body></html>'); });
    return;
  }
  res.end('<html><head><title>Sign in</title></head><body><form method="post" action="/signin">' +
    '<input id="user" name="user"><input id="pw" name="password" type="password"><button id="go">Sign in</button></form></body></html>');
}).listen(0, '127.0.0.1', function () { console.log(this.address().port); });
JS
  node "$TMP/site.cjs" "$SECRET" "$TMP/got" > "$TMP/port" & _KILL+=($!)
  for _ in $(seq 50); do [[ -s "$TMP/port" ]] && break; sleep 0.1; done
  PORT="$(cat "$TMP/port")"
  LSTEPS='[{"op":"fill","selector":"#user","value":"sam"},{"op":"fill","selector":"#pw","saved":"linkedin-password"},{"op":"click","selector":"#go"}]'
  run env -u NODE_PATH -u PWWALK -u PWHTML -u PWTEXT -u FIVEDIVE_BROWSER_DRIVER PATH="$REALPATH" FIVEDIVE_BROWSER_RUN_SETTLE_MS=500 \
    FIVEDIVE_BROWSER_SAVED_FD=3 "$BROWSER" act "http://localhost:$PORT/" --steps="$LSTEPS" --expect='Signed in as sam' --out="$TMP/live" \
    3< <(printf '%s' "${SECRET_JSON//login.test/localhost}")
  arm 'L1a a real sign-in page in real Chrome: signed in with the saved password (rc 0, verified)' 0 "$RC"
  [[ "$RC" == 0 ]] || gha 'L1 act output' "$OUT $ERR"
  arm 'L1b the site got exactly the saved value' "$SECRET" "$(cat "$TMP/got" 2>/dev/null)"
  arm 'L2 the value: 0 times in act'"'"'s output and artifacts' 0 "$(leaks "$SECRET" "$OUT" "$ERR" "$TMP/live")"
fi

printf '\n%d pass, %d fail, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
