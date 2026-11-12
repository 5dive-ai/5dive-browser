#!/usr/bin/env bash
# DIVE-8287 — `act --help` lists every step op and the fields it takes.
#
# Before: the help named flags and saved logins, never the step ops. Box agents
# read it, saw no upload, and filed "act has no upload step" while upload existed
# (11-09, and 11-12 on 1.75.0, blocking a client's photo uploads).
# Now the help walks ACT_VOCAB and prints one JSON example per op.
#
#   H1 `act --help` exits 0 and prints a Steps section
#   H2 every op in ACT_VOCAB is in it, as "op":"<op>"
#   H3 every example line is JSON, its op is the one named, and it carries the
#      fields the executor reads for that op (none falls back to a bare op)
#   H4 upload names its absolute path and the cap, read from ACT_UPLOAD_MAX_BYTES
#   H5 drift: an op added to ACT_VOCAB shows up in the help with no other edit
#   H6 the row's own check: `act --help | grep -c upload` >= 1
#   N  control: the pre-fix tree's `act --help` never says upload
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"
BASE=249c7ef   # 5dive-browser main before DIVE-8287 (1.79.0)
TMP="$(mktemp -d /tmp/d8287u.XXXXXX)"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0; SKIP=0
arm() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
        else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
export FIVEDIVE_BROWSER_TMP_ROOT="$TMP/tmproot" FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/profiles"

help_of() { "$1" act --help 2>&1; }
OUT=$(help_of "$BROWSER"); RC=$?
arm 'H1 act --help exits 0 and has a Steps section' "0 yes" "$RC $([[ "$OUT" == *"Steps (--steps is a JSON array"* ]] && echo yes || echo no)"

VOCAB=$(sed -n "s/^ACT_VOCAB='\(.*\)'$/\1/p" "$BROWSER")
missing=""; for op in $VOCAB; do [[ "$OUT" == *"\"op\":\"$op\""* ]] || missing+=" $op"; done
arm "H2 all $(wc -w <<<"$VOCAB") ACT_VOCAB ops are listed" "" "$missing"

# The fields the executor reads (session-daemon / driver-playwright / lib/point.cjs).
need() { case "$1" in
  goto) echo url ;; fill|type|select) echo selector value ;; click|wait_for) echo selector ;;
  press) echo selector key ;; upload) echo selector path ;; click_at|hover_at) echo x y ;;
  type_at) echo x y value ;; eval) echo expr ;; *) echo '?' ;; esac; }
bad=""
for op in $VOCAB; do
  line=$(grep -m1 -F "{\"op\":\"$op\"" <<<"$OUT" | sed -e 's/^ *//' -e 's/   (.*)$//')
  js=$(jq -c . <<<"$line" 2>/dev/null) || { bad+=" $op:not-json"; continue; }
  [[ "$(jq -r .op <<<"$js")" == "$op" ]] || bad+=" $op:op"
  for k in $(need "$op"); do jq -e --arg k "$k" 'has($k)' <<<"$js" >/dev/null || bad+=" $op:no-$k"; done
done
arm 'H3 each example is JSON with the fields its op takes' "" "$bad"

up=$(grep -m1 -F '{"op":"upload"' <<<"$OUT")
arm 'H4a upload shows an absolute path and the 16 MB cap' "yes yes" \
  "$([[ "$up" == *'"path":"/'* ]] && echo yes || echo no) $([[ "$up" == *'16 MB'* ]] && echo yes || echo no)"
up8=$(FIVEDIVE_BROWSER_UPLOAD_MAX_BYTES=8388608 "$BROWSER" act --help 2>&1 | grep -m1 -F '{"op":"upload"')
arm 'H4b the cap is read from ACT_UPLOAD_MAX_BYTES (8 MB when set so)' "yes" "$([[ "$up8" == *'8 MB'* ]] && echo yes || echo no)"

sed "s/^ACT_VOCAB='\(.*\)'$/ACT_VOCAB='\1 zz_new'/" "$BROWSER" > "$TMP/browser"; chmod +x "$TMP/browser"
mkdir -p "$TMP/plug"; cp -r "$ROOT/browser/." "$TMP/plug"; cp "$TMP/browser" "$TMP/plug/bin/browser"
arm 'H5 an op added to ACT_VOCAB is listed with no other edit' "yes" \
  "$([[ "$(help_of "$TMP/plug/bin/browser")" == *'{"op":"zz_new"}'* ]] && echo yes || echo no)"

n=$(help_of "$BROWSER" | grep -c upload)
arm "H6 the row's check: act --help | grep -c upload >= 1 (got $n)" "yes" "$( (( n >= 1 )) && echo yes || echo no)"

if git -C "$ROOT" cat-file -e "$BASE:browser/bin/browser" 2>/dev/null; then
  mkdir -p "$TMP/old"; git -C "$ROOT" archive "$BASE" browser | tar -x -C "$TMP/old"
  arm 'N1 control: before the fix act --help never says upload' "0" "$(help_of "$TMP/old/browser/bin/browser" | grep -c upload)"
else
  echo "SKIP: N1 — base $BASE is not in this checkout"; SKIP=$((SKIP+1))
fi

printf '\n%d pass, %d fail, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
