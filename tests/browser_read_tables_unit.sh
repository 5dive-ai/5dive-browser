#!/usr/bin/env bash
# DIVE-6582 — `browser read` keeps a page's label/value tables.
#
# The DIVE-6491 bench lost R1 (Wikipedia facts) 3 of 3: the readability extractor dropped
# Wikipedia's infobox, so "Initial release 8 July 1996" was in no read, and the agent took
# a year from the history prose instead. The rivals kept it. lib/extract.src.mjs now reads
# every label/value table before Defuddle runs and puts its rows at the top of page.md as
# "- label: value" lines (and in --json as facts[]). Not a Wikipedia rule: the spec-sidebar
# fixture is a shop page with a plain <td>/<td> table and no "infobox" class anywhere.
#
# EXTRACTOR=<bundle> grades another build. On the 1.46.x bundle
# (git show 9dee496:browser/lib/extract.bundle.cjs) 8 of the 14 F/N/S/P arms fail:
# F1-F4, F6, F7, S1, S2 (13 of all 28 with the Q and I arms below).
#
# The Q arms are the other half of the row: a bare `status` probed each site in series
# (50 s on the bench seat's eight sites, run by the agent in 3 of 6 slow attempts). They
# grade the real bin/browser with a fake Chrome that takes 2 s per probe; on 1.46.x Q1 and Q8
# fail. The I arms: snapshot and act print a small page's text and refs instead of only its
# directory, which every bench attempt followed with a `cat`; on 1.46.x I0, I1 and I3 fail.
set -uo pipefail
cd "$(dirname "$0")/.."
EXTRACTOR="${EXTRACTOR:-$PWD/browser/lib/extract.bundle.cjs}"
FX="$PWD/tests/fixtures/dive-6582"
PASS=0; FAIL=0
t() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
x() { node "$EXTRACTOR" --url="$2" < "$FX/$1.html"; }
yn() { if grep -qF -- "$1"; then echo yes; else echo no; fi; }

W=$(x infobox https://en.wikipedia.org/wiki/PostgreSQL)
MD=$(jq -r .markdown <<<"$W")
t 'F1 the infobox row is a "label: value" line' yes "$(yn '- Initial release: 8 July 1996' <<<"$MD")"
t 'F2 the infobox licence row is there too' yes "$(yn '- License: PostgreSQL License' <<<"$MD")"
t 'F3 the facts come BEFORE the article text (a head -c read sees them)' yes \
  "$(awk '/Initial release:/{f=NR} /Ingres project/{b=NR} END{print (f && b && f<b) ? "yes" : "no"}' <<<"$MD")"
t 'F4 --json carries facts[] with the label and value' '8 July 1996' \
  "$(jq -r '.facts[0].facts[]|select(.label=="Initial release")|.value' <<<"$W" 2>/dev/null)"
t 'F5 footnote markers are not part of a value' no "$(yn 'Development Group[1]' <<<"$MD")"
t 'F6 a <br> inside a cell separates values' yes "$(yn '- Written in: C; C++ (LLVM)' <<<"$MD")"
t 'F7 the caption names the table' yes "$(sed -n '/^## Facts/,/^## Page text/p' <<<"$MD" | grep -qx 'PostgreSQL' && echo yes || echo no)"
# Negative arms: what is NOT a fact table stays where it was.
t 'N1 a data grid (3 columns, row headers) is not turned into facts' no "$(yn '- 6.0:' <<<"$MD")"
t 'N2 a navigation box is the menu, not facts' no "$(yn 'Navboxrowlabel' <<<"$MD")"
t 'N3 the article text is still all there' yes "$(yn 'version 6.0 on January 29, 1997' <<<"$MD")"

S=$(x spec-sidebar https://shop.example/kettles/k2)
SMD=$(jq -r .markdown <<<"$S")
t 'S1 a shop sidebar table with no infobox class is kept' yes "$(yn '- Release date: 2026-03-02' <<<"$SMD")"
t 'S2 a trailing colon on the label is not doubled' yes "$(yn '- Capacity: 1.7 litres' <<<"$SMD")"

P=$(x plain https://example.com/plain)
t 'P1 a page with no tables reads exactly as before (no facts heading)' no "$(jq -r .markdown <<<"$P" | yn '## Facts on the page')"
t 'P2 and its facts[] is empty' 0 "$(jq '.facts | length' <<<"$P" 2>/dev/null || echo missing)"

# ---- I: a small page's text and refs are printed, not pointed at --------------------
# The helper is read out of the SHIPPED bin/browser at run time, and the read is checked.
eval "$(awk '/^INLINE_MD_MAX=/||/^INLINE_REFS_MAX=/{print} /^_inline_page\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$PWD/browser/bin/browser")"
t 'I0 the helper was read from bin/browser' function "$(type -t _inline_page)"
D=$(mktemp -d)
printf -- '---\nurl: "https://x.test/w"\ntitle: "Workspace"\n---\n\n## Inbox\n\n**Pending report #7184** [Open report](https://x.test/r)\n' > "$D/page.md"
printf '{"url":"https://x.test/w","title":"Workspace","nodes":[{"ref":"link/Open report 7184","role":"link","name":"Open report 7184"}]}' > "$D/tree.json"
IO=$(_inline_page "$D")
t 'I1 a small page.md body is printed' yes "$(yn '**Pending report #7184**' <<<"$IO")"
t 'I2 ...without its front matter' no "$(yn 'title: "Workspace"' <<<"$IO")"
t 'I3 the refs are printed ready to quote' yes "$(yn 'ref=link/Open report 7184' <<<"$IO")"
head -c 6000 /dev/zero | tr '\0' 'x' >> "$D/page.md"
IO=$(_inline_page "$D")
t 'I4 a page over the cap is NOT dumped (only the paths, as before)' no "$(yn 'Pending report' <<<"$IO")"
jq '.nodes = [range(0;80) | {ref:"button/B\(.)"}]' "$D/tree.json" > "$D/t2" && mv "$D/t2" "$D/tree.json"
IO=$(_inline_page "$D")
t 'I5 ...nor a tree of 80 refs' no "$(yn 'ref=button/B1' <<<"$IO")"
rm -rf "$D"

# ---- Q: a bare `status` probes its sites side by side -------------------------------
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
unset BASH_ENV ENV
export FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/no-session-daemon" FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli" \
       FIVEDIVE_BROWSER_WAKE_PRIV="$TMP/no-wake" FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 \
       FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/profiles" FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/adapters" \
       FIVEDIVE_BROWSER_APPROVAL_DIR="$TMP/approvals" FIVEDIVE_BROWSER_STACK=off
mkdir -p "$TMP/bin" "$FIVEDIVE_BROWSER_ADAPTER_DIR"
cat > "$TMP/bin/google-chrome" <<'CHROME'
#!/usr/bin/env bash
# A probe that takes 2 s, then serves the DOM parked in the profile.
for a in "$@"; do case "$a" in --user-data-dir=*) d="${a#*=}" ;; esac; done
sleep 2
cat "${d:-/nonexistent}/.fake-dom" 2>/dev/null || echo "<html><body>blank</body></html>"
CHROME
chmod +x "$TMP/bin/google-chrome"
export PATH="$TMP/bin:$PATH"
SEATD="$FIVEDIVE_BROWSER_PROFILE_ROOT/$(id -un)"; mkdir -p "$SEATD"; chmod 700 "$FIVEDIVE_BROWSER_PROFILE_ROOT" "$SEATD"
for s in a.test b.test c.test d.test; do
  mkdir -p "$SEATD/$s"; chmod 700 "$SEATD/$s"
  if [[ "$s" == c.test ]]; then dom='<html><body><form action="/login"><input type=password></form></body></html>'
  else dom='<html><body><div id="feed">posts</div></body></html>'; fi
  printf '%s' "$dom" > "$SEATD/$s/.fake-dom"
  printf '{"site":"%s","probe":{"url":"https://%s/feed","logged_out_when_dom_matches":"action=\\"/login\\""}}' "$s" "$s" \
    > "$FIVEDIVE_BROWSER_ADAPTER_DIR/$s.json"
done
st() { local t0; t0=$(date +%s%N); OUT=$(bash "$PWD/browser/bin/browser" status 2>/dev/null); RC=$?; MS=$(( ($(date +%s%N) - t0) / 1000000 )); }
st
t 'Q1 four 2 s probes finish well inside the 8 s a series takes' yes "$( (( MS < 6500 )) && echo yes || echo "no (${MS} ms)")"
t 'Q2 the lines print in site order' 'a.test b.test c.test d.test' "$(awk '{print $1}' <<<"$OUT" | xargs)"
t 'Q3 each line carries its own verdict (c.test is the logged-out one)' 'session expired' \
  "$(grep '^  c.test' <<<"$OUT" | grep -o 'session expired')"
t 'Q4 ...and a.test is still read as signed in' 'authenticated' "$(grep '^  a.test' <<<"$OUT" | grep -o 'authenticated')"
t 'Q5 one cold site still makes the exit 75' 75 "$RC"
FIVEDIVE_BROWSER_STATUS_JOBS=1 st
t 'Q6 control: one at a time is the old series (the clock in Q1 can say no)' yes "$( (( MS >= 8000 )) && echo yes || echo "no (${MS} ms)")"
t 'Q7 ...with the same lines' 'a.test b.test c.test d.test' "$(awk '{print $1}' <<<"$OUT" | xargs)"
OUT=$(FIVEDIVE_BROWSER_STATUS_JOBS=x bash "$PWD/browser/bin/browser" status 2>&1); RC=$?
t 'Q8 a bad FIVEDIVE_BROWSER_STATUS_JOBS is refused' 64 "$RC"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
