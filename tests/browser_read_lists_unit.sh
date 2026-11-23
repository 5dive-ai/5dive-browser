#!/usr/bin/env bash
# DIVE-9058 — a webmail inbox is in page.md, not deleted as a dropdown (box report 1348).
#
# Defuddle deletes every form, [role=listbox] and [role=option] subtree whole. A signed-in
# webmail read had folders and attachment names but no senders, subjects or bodies.
# The fixtures are one 20-message inbox built four ways (main's repro, plus button rows):
#   inbox.html    plain divs: the control, read the same before and after
#   listbox.html  list role=listbox, rows role=option: 0 words on 1.97.1
#   form.html     the list inside a <form>: 0 words on 1.97.1
#   buttons.html  rows are <button>s, a rule the unwrap does not touch: the backstop's case
# article.html is a news page with a search form, a newsletter form with a <select> and a
# small listbox; article.before.json is the 1.97.1 bundle's output for it, kept to prove
# the small widgets are still dropped and the page reads byte for byte as before.
#
# No Chrome: the extractor runs on saved HTML and _derive_capture gets no chrome path.
# EXTRACTOR=<bundle> grades another build. On 1.97.1
# (git show a9616a1:browser/lib/extract.bundle.cjs) L2-L6, B1-B5, M1 and M2 fail.
set -uo pipefail
cd "$(dirname "$0")/.."
EXTRACTOR="${EXTRACTOR:-$PWD/browser/lib/extract.bundle.cjs}"
FX="$PWD/tests/fixtures/dive-9058"
PASS=0; FAIL=0
t() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
x() { node "$EXTRACTOR" --url="$2" < "$FX/$1.html"; }
subjects() { jq -r .markdown | grep -c 'for the spring shipment'; }

IN=$(x inbox https://mail.example.com/)
LB=$(x listbox https://mail.example.com/)
FM=$(x form https://mail.example.com/)
t 'L1 plain-div inbox: 20 of 20 subjects (the control)' 20 "$(subjects <<<"$IN")"
t 'L2 listbox inbox: 20 of 20 subjects' 20 "$(subjects <<<"$LB")"
t 'L3 inbox inside a form: 20 of 20 subjects' 20 "$(subjects <<<"$FM")"
t 'L4 the listbox read is the plain read, word for word' yes \
  "$([[ "$(jq -r .markdown <<<"$LB")" == "$(jq -r .markdown <<<"$IN")" ]] && echo yes || echo no)"
t 'L5 the form read is the plain read, word for word' yes \
  "$([[ "$(jq -r .markdown <<<"$FM")" == "$(jq -r .markdown <<<"$IN")" ]] && echo yes || echo no)"
t 'L6 attachment names are kept (20 of 20)' 20 "$(jq -r .markdown <<<"$LB" | grep -c 'pricelist\\_[0-9]*\.pdf')"
t 'L7 a list the reader kept is not flagged thin' null "$(jq -c .thin_extract <<<"$LB")"

A=$(x article https://port-weekly.example/river-barge-trade)
t 'A1 an article with a search form, a <select> and a small listbox reads byte for byte as before' yes \
  "$([[ "$A" == "$(cat "$FX/article.before.json")" ]] && echo yes || echo no)"
t 'A2 ...its small widgets are still dropped' 0 "$(jq -r .markdown <<<"$A" | grep -c -E 'Get the weekly digest|Most read|Americas')"

BT=$(x buttons https://mail.example.com/)
BMD=$(jq -r .markdown <<<"$BT")
t 'B1 a page the reader still empties is flagged thin_extract' true "$(jq -c .thin_extract <<<"$BT")"
t 'B2 ...and its visible text is in page.md under "## Visible text"' yes "$(grep -qx '## Visible text' <<<"$BMD" && echo yes || echo no)"
t 'B3 ...20 of 20 subjects, one line each' 20 "$(grep -cx 'Re: quote request number [0-9]* for the spring shipment' <<<"$BMD")"
t 'B4 ...word_count counts that text, not 0' true "$(jq '.word_count > 300' <<<"$BT")"
t 'B5 ...20 of 20 attachment names' 20 "$(grep -cx 'pricelist_[0-9]*\.pdf' <<<"$BMD")"
t 'B6 the emptied article placeholder is not printed' 0 "$(grep -c '<body>' <<<"$BMD")"
t 'B7 the nav (folders) and header are not the visible text' 0 "$(grep -c -E '^(Spam|Drafts|Webmail 360)$' <<<"$BMD")"

# ---- M: page.md front matter and page.meta.json say it (the real bin/browser) ----------
# _derive_capture is read out of the SHIPPED bin/browser at run time.
die() { echo "die: $*" >&2; return 1; }
_page_read_mark() { :; }
eval "$(awk '/^_derive_capture\(\) \{/||/^_page_fence_id\(\) /||/^_page_fence\(\) \{/{f=1} f{print} f&&/^}/{f=0}' "$PWD/browser/bin/browser")"
t 'M0 _derive_capture was read from bin/browser' function "$(type -t _derive_capture)"
READ_EXTRACTOR="$EXTRACTOR"
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/b" "$D/a"
cp "$FX/buttons.html" "$D/b/page.html"; cp "$FX/article.html" "$D/a/page.html"
_derive_capture "$D/b" https://mail.example.com/ "" snapshot '{}' 2>/dev/null
_derive_capture "$D/a" https://port-weekly.example/river-barge-trade "" snapshot '{}' 2>/dev/null
t 'M1 a thin read says thin_extract: true in page.md front matter' yes \
  "$(sed -n '2,/^---$/p' "$D/b/page.md" | grep -qx 'thin_extract: true' && echo yes || echo no)"
t 'M2 ...and in page.meta.json' true "$(jq -c .thin_extract "$D/b/page.meta.json" 2>/dev/null)"
t 'M3 an ordinary read has no thin_extract line' 0 "$(grep -c thin_extract "$D/a/page.md")"
t 'M4 the visible text sits inside the UNTRUSTED-PAGE fence' yes \
  "$(awk '/^<<<UNTRUSTED-PAGE-/{f=1} /^## Visible text$/&&f{v=1} /^<<<END UNTRUSTED-PAGE-/{f=0} END{print v?"yes":"no"}' "$D/b/page.md")"

printf 'browser_read_lists_unit: %d pass, %d fail\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
