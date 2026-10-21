#!/usr/bin/env bash
# DIVE-6651 — `act --expect` grades what a person can read, never hidden markup.
#
# Measured 2026-10-19 by the exact-swallow canary: `act --expect='Indexing
# requested'` on a Search Console page printed `verified` while the screen said
# "Oops! Something went wrong". The match was `<span>Indexing requested</span>`,
# a hidden template in page.html; after.json's text had 0 hits. The seat recorded
# indexing requests that never happened.
#
# Driven through the REAL bin/browser and the REAL driver-playwright, with the
# recording playwright-core stub extracted from browser_plugin_unit.sh at run time
# (so the suites cannot grade two different stubs) and a fake google-chrome. No
# Chrome, no network. The stub's clock counts only the waits the product asks
# for, so a 5 s window costs no wall time.
#
#   V1  NEGATIVE CONTROL: a hidden "Indexing requested" span and a visible
#       "Something went wrong" — `--expect='Indexing requested'` is NOT VERIFIED,
#       rc 1. RED on the pre-fix grade (the page.html grep, restored in a mutant).
#   V2  the --expect-wait poll does not stop on the hidden match: it reads for the
#       whole window. RED on the pre-fix poll (it stopped at 0 ms).
#   V3  DIVE-4983 still holds: a role=status toast that shows and is then removed
#       reads verified when the poll caught it, and the capture is that moment.
#   V4  CONTROLS: the same words visible on screen verify; so does the title, and
#       the url.
#   V5  lib/aria.cjs pageAfter, direct: the act poll ignores the document;
#       `expectDoc` (run's in-session verify, whose grader still reads the
#       document) keeps the old early exit.
#   V6  documented: AGENTS.md no longer says --expect matches the document.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2

TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }
tn() { if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected NOT to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }
run() { local o="$TMP/.o" e="$TMP/.e"; "$@" >"$o" 2>"$e"; RC=$?; OUT=$(cat "$o"); ERR=$(cat "$e"); return 0; }
# A mutant is a whole copy of the plugin: bin/browser finds its driver and lib/
# beside itself, so a lone copied file grades a missing executor, not the mutation.
mutant() {  # mutant <name> <file under browser/> <perl-expr> -> path of the mutant bin/browser
  rm -rf "$TMP/mut-$1"; cp -r "$ROOT/browser" "$TMP/mut-$1"
  perl -0pi -e "$3" "$TMP/mut-$1/$2"
  printf '%s\n' "$TMP/mut-$1/bin/browser"
}

SEAT="$(id -un)"
export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/profiles"
export FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/adapters"; mkdir -p "$FIVEDIVE_BROWSER_ADAPTER_DIR"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/sessions"
export FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/no-session-daemon"
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli"
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
export FIVEDIVE_BROWSER_APPROVAL_DIR="$TMP/approvals" FIVEDIVE_BROWSER_APPROVAL_POLICY="$TMP/policy.json"
export FIVEDIVE_BROWSER_GRANT_UID="$(id -u)" FIVEDIVE_BROWSER_RUN_SETTLE_MS=0 FIVEDIVE_BROWSER_TREE_SETTLE_MS=0
mkdir -p "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT"
chmod 711 "$FIVEDIVE_BROWSER_PROFILE_ROOT"; chmod 700 "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT"

FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == --version ]] && { echo "Google Chrome 153"; exit 0; }\necho "<html><body>public</body></html>"\n' > "$FAKEBIN/google-chrome"
chmod +x "$FAKEBIN/google-chrome"
export PATH="$FAKEBIN:$PATH"

# --- THE STUB, from the main suite -------------------------------------------
PWROOT="$TMP/pw"; mkdir -p "$PWROOT/node_modules/playwright-core"
printf '{ "name": "playwright-core", "version": "0.0.0-stub", "main": "index.js" }\n' > "$PWROOT/node_modules/playwright-core/package.json"
sed -n "/^cat > \"\$PWROOT\/node_modules\/playwright-core\/index.js\" <<'PWJS'$/,/^PWJS$/p" tests/browser_plugin_unit.sh \
  | sed '1d;$d' > "$PWROOT/node_modules/playwright-core/index.js"
t  'S0 (anchor) the stub was extracted from the main suite' yes \
   "$(grep -q 'launchPersistentContext' "$PWROOT/node_modules/playwright-core/index.js" && echo yes || echo no)"
t  'S0 (anchor) ...with the toast that goes away (PWGONE_MS)' yes \
   "$(grep -q 'PWGONE_MS' "$PWROOT/node_modules/playwright-core/index.js" && echo yes || echo no)"
export NODE_PATH="$PWROOT/node_modules"
export PWREC="$TMP/pw.jsonl"; : > "$PWREC"

URL="https://search.google.test/search-console/inspect"
STEPS='[{"op":"click","selector":"#request-indexing"}]'
# The canary's page, cut down: the success words are a hidden template in the
# document; what is on screen is the error dialog.
SC_HTML='<html><body><main><span class="xxvyLd" hidden>Indexing requested</span><div aria-hidden="true" style="display:none">Indexing requested</div><div role="alertdialog"><h2>Oops! Something went wrong</h2><p>We had a problem submitting your indexing request. Please try again later.</p></div></main></body></html>'
SC_TEXT='URL Inspection
Oops! Something went wrong
We had a problem submitting your indexing request. Please try again later.'
sc() {  # sc <bin/browser> <out> [act flags...] — act on the canary's page
  local bin="$1" out="$2"; shift 2
  run env PWHTML="$SC_HTML" PWTEXT="$SC_TEXT" PWTITLE='URL Inspection' \
      "$bin" act "$URL" --steps="$STEPS" --out="$TMP/$out" "$@"
}

# The pre-fix grade and poll, restored. Each mutant is anchored: it landed in the
# copy, and the shipped file is untouched.
MUTGRADE="$(mutant grade bin/browser 's/<<<"\$\(jq -r \x27\[\.text, \.title, \.url\]/<<<"\$(cat "\$out\/page.html"; jq -r \x27[.text, .title, .url]/')"
t  'M0 (anchor) the pre-fix grade (page.html greped too) landed in the copy' yes \
   "$(grep -q '<<<"$(cat "$out/page.html"; jq -r' "$MUTGRADE" && echo yes || echo no)"
MUTPOLL="$(mutant poll lib/aria.cjs 's/\|\| \(expectDoc && re\.test\(o\.html\)\)/|| re.test(o.html)/')"
t  'M0 (anchor) the pre-fix poll (the document ends the wait) landed in the copy' yes \
   "$(grep -qF '|| re.test(o.html);' "$TMP/mut-poll/lib/aria.cjs" && echo yes || echo no)"
t  'M0 (anchor) ...and the shipped files are untouched' 'yes yes' \
   "$(grep -q '<<<"$(cat "$out/page.html"' "$BROWSER" && echo no || echo yes) $(grep -qF '|| re.test(o.html);' "$ROOT/browser/lib/aria.cjs" && echo no || echo yes)"

# ============================================================= V1 negative control
sc "$BROWSER" v1 --expect='Indexing requested' --expect-wait=0
t  'V1 hidden "Indexing requested", visible error: act is NOT VERIFIED (1)' 1 "$RC"
tn 'V1 ...and stdout never says verified' 'verified' "$OUT"
tc 'V1 ...stderr says NOT VERIFIED and points at page.png' 'NOT VERIFIED' "$ERR"
t  'V1 (anchor) the document DOES carry the words — hidden' 2 "$(grep -o 'Indexing requested' "$TMP/v1/page.html" | wc -l)"
t  'V1 (anchor) ...and the text a person reads does not' 0 "$(jq -r .text "$TMP/v1/after.json" | grep -c 'Indexing requested')"
sc "$BROWSER" v1j --expect='Indexing requested' --expect-wait=0 --json
t  'V1 --json: not_verified' not_verified "$(jq -r .verdict <<<"$OUT")"
sc "$MUTGRADE" v1m --expect='Indexing requested' --expect-wait=0
t  'V1 RED ARM: on the pre-fix grade the same act reads verified (0)' '0 verified: the page after the steps matches --expect' \
   "$RC $(grep '^verified' <<<"$OUT")"
# The canary's own pattern: the alternative that could be on screen is not either.
sc "$BROWSER" v1q --expect='Indexing requested|Quota exceeded' --expect-wait=0
t  'V1 the canary'"'"'s exact --expect is NOT VERIFIED too' 1 "$RC"

# ============================================================= V2 the poll
sc "$BROWSER" v2 --expect='Indexing requested' --expect-wait=2000
t  'V2 with a 2 s window, still NOT VERIFIED' 1 "$RC"
t  'V2 ...the poll read for the whole window: the hidden match did not end it' 2000 \
   "$(jq -r .expect_polled_ms "$TMP/v2/after.json")"
sc "$MUTPOLL" v2m --expect='Indexing requested' --expect-wait=2000
t  'V2 RED ARM: the pre-fix poll stopped at once on the hidden match' 0 \
   "$(jq -r .expect_polled_ms "$TMP/v2m/after.json")"

# ============================================================= V3 DIVE-4983 holds
# A toast from 500 ms, removed at 1000 ms: only a read inside that window sees it.
TOAST_HTML='<html><body><div id="compose">Subject: hello</div><div role="status" aria-live="polite">Message sent</div></body></html>'
toast() { run env PWHTML='<html><body><div id="compose">Subject: hello</div></body></html>' PWTEXT='Subject: hello' \
            PWHTML_LATE="$TOAST_HTML" PWTEXT_LATE=$'Subject: hello\nMessage sent' PWLATE_MS=500 PWGONE_MS=1000 \
            "$BROWSER" act "https://mail.test/compose" --steps='[{"op":"click","selector":"#send"}]' "$@"; }
toast --expect='Message sent' --expect-wait=5000 --out="$TMP/v3"
t  'V3 a role=status toast shown 500–1000 ms after the click verifies (0)' '0 verified: the page after the steps matches --expect' \
   "$RC $(grep '^verified' <<<"$OUT")"
t  'V3 ...the poll caught it at 500 ms, and stopped there' 500 "$(jq -r .expect_polled_ms "$TMP/v3/after.json")"
tc 'V3 ...the capture that shipped is that moment: the toast is in its text' 'Message sent' "$(jq -r .text "$TMP/v3/after.json")"
tc 'V3 ...and in its page.html' 'role="status"' "$(cat "$TMP/v3/page.html")"
toast --expect='Message sent' --expect-wait=250 --out="$TMP/v3c"
t  'V3 (anchor) a window that ends before the toast: NOT VERIFIED — the poll is what caught it' 1 "$RC"
FIVEDIVE_BROWSER_RUN_SETTLE_MS=1000 toast --out="$TMP/v3g"
t  'V3 (anchor) the toast really goes: a read taken at 1000 ms (the settle, no --expect) has none' 'Subject: hello' \
   "$(jq -r .text "$TMP/v3g/after.json" 2>/dev/null || echo missing)"

# ============================================================= V4 controls
run env PWHTML='<html><body><p>Indexing requested</p></body></html>' PWTEXT=$'URL Inspection\nIndexing requested' \
    "$BROWSER" act "$URL" --steps="$STEPS" --expect='Indexing requested' --expect-wait=0 --out="$TMP/v4a"
t  'V4 CONTROL: the same words on screen verify (0)' 0 "$RC"
sc "$BROWSER" v4b --expect='URL Inspection' --expect-wait=0
t  'V4 CONTROL: a match in the title verifies (0)' 0 "$RC"
sc "$BROWSER" v4c --expect='search-console/inspect' --expect-wait=0
t  'V4 CONTROL: a match in the url verifies (0)' 0 "$RC"

# ============================================================= V5 pageAfter, direct
cat > "$TMP/v5.js" <<'JS'
const { pageAfter } = require(process.env.ARIA);
const page = () => ({
  url: () => 'https://search.google.test/inspect', title: async () => 'URL Inspection',
  content: async () => '<html><body><span hidden>Indexing requested</span></body></html>',
  evaluate: async () => 'Oops! Something went wrong',
  waitForTimeout: async () => {},
});
(async () => {
  const act = await pageAfter(page(), { expect: 'Indexing requested', expectWaitMs: 1000, pollMs: 250 });
  const doc = await pageAfter(page(), { expect: 'Indexing requested', expectWaitMs: 1000, pollMs: 250, expectDoc: true });
  const title = await pageAfter(page(), { expect: 'url inspection', expectWaitMs: 1000, pollMs: 250 });
  console.log([act.expect_polled_ms, doc.expect_polled_ms, title.expect_polled_ms].join(' '));
})().catch((e) => console.log('ERR ' + e.message));
JS
t  'V5 pageAfter: act polls the full window past a hidden match; expectDoc stops at 0; a title match stops at 0' \
   '1000 0 0' "$(ARIA="$ROOT/browser/lib/aria.cjs" node "$TMP/v5.js" 2>&1)"
t  'V5 run'"'"'s in-session verify asks for the document poll (expect_doc)' 1 \
   "$(grep -c 'expect_doc:true' "$BROWSER")"
t  'V5 ...and both executors pass it to pageAfter' '1 1' \
   "$(grep -c 'expectDoc: !!report.expect_doc' "$ROOT/browser/bin/driver-playwright") $(grep -c 'expectDoc: !!r.expect_doc' "$ROOT/browser/bin/session-daemon")"

# ============================================================= V6 the words
tn 'V6 AGENTS.md no longer says --expect matches the document' 'as well as the document' \
   "$(tr -s ' \n' '  ' < "$ROOT/browser/AGENTS.md")"
tc 'V6 AGENTS.md says hidden markup never matches' 'never hidden markup' "$(tr -s ' \n' '  ' < "$ROOT/browser/AGENTS.md")"
tc 'V6 CHANGES.md names the row' 'DIVE-6651' "$(cat "$ROOT/CHANGES.md")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
