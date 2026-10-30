#!/usr/bin/env bash
# DIVE-7303 — `session-daemon call` reads a big reply in time linear in its size.
#
# The client appended every chunk to one string and searched it from the start
# for the line's end, so a multi-megabyte reply (a results page with 1,211 refs)
# held the client at 90% CPU for 150-220 s on the bench while the browser had
# answered in seconds. A fake daemon here sends one big `out` line in small
# chunks; the client must pass it through byte for byte, quickly, and must not
# cut a character that spans two chunks.
set -uo pipefail
cd "$(dirname "$0")/.."
DAEMON="$PWD/browser/bin/session-daemon"
PASS=0; FAIL=0
t() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
TMP=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$TMP"' EXIT

# fake <sock> <MB> <chunk bytes> [<ms between chunks>]: answers any request with
# one `out` line of that many MB (ASCII with a euro sign every 1000 bytes). exec,
# so the background job IS node and the EXIT trap's kill stops it (a plain call left
# the servers running, holding the caller's pipe open).
fake() { exec node -e '
  const net = require("net"); const [sock, mb, chunk, gap] = process.argv.slice(1);
  const unit = "x".repeat(997) + "€";             // 1000 bytes, the euro is 3 of them
  const body = unit.repeat(Math.round(Number(mb) * 1000));
  const line = Buffer.from(JSON.stringify({ t: "out", data: body }) + "\n" + JSON.stringify({ t: "end", rc: 0 }) + "\n");
  net.createServer((c) => {
    c.once("data", async () => {
      for (let i = 0; i < line.length; i += Number(chunk)) {
        if (!c.write(line.subarray(i, i + Number(chunk)))) await new Promise((r) => c.once("drain", r));
        if (gap) await new Promise((r) => setTimeout(r, Number(gap)));
      }
      c.end();
    });
  }).listen(sock, () => console.log("ready"));
' "$@"; }
up() { for _ in $(seq 100); do grep -q ready "$1" 2>/dev/null && break; sleep 0.1; done; }

# {"t":"out","data":" is 19 bytes, so byte 1017 of the line is inside the first euro.
fake "$TMP/a.sock" 0.002 1017 200 > "$TMP/a.ready" & up "$TMP/a.ready"
OUT=$(echo '{"op":"x"}' | node "$DAEMON" call "$TMP/a.sock"); RC=$?
t 'C1 a euro sign split across two chunks arrives whole' "0 2 1994" \
  "$RC $(grep -o '€' <<<"$OUT" | wc -l | tr -d ' ') $(tr -d '€' <<<"$OUT" | tr -d '\n' | wc -c | tr -d ' ')"

fake "$TMP/b.sock" 24 16384 > "$TMP/b.ready" & up "$TMP/b.ready"
S=$(date +%s%N)
echo '{"op":"x"}' | node "$DAEMON" call "$TMP/b.sock" > "$TMP/b.out"; RC=$?; N=$(wc -c < "$TMP/b.out" | tr -d ' ')
MS=$(( ($(date +%s%N) - S) / 1000000 ))
t 'C2 a 24 MB reply in 16 KB chunks passes through byte for byte' "0 24000000" "$RC $N"
# Linear: ~0.4 s here. The old client: 6.5 s on the same machine, and minutes on the bench's bigger reply.
t "C3 ...in under 3 s (took ${MS} ms)" yes "$( (( MS < 3000 )) && echo yes || echo no)"

printf 'call stream: %d pass, %d fail\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
