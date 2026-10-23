#!/usr/bin/env bash
# DIVE-6778 — lib/aria.cjs settleQuiet, requestWatch and the covered click.
#
# Every act and every act goto waited a fixed 1.2 s; a page done in 0.2 s paid it
# too. The settle now ends once no document/XHR/fetch request is in flight and the
# DOM has been still for 0.25 s, and never later than the old bound. A click whose
# element's centre is under something else (a cookie banner) gets 1.5 s, not 5 s.
# Fake pages, pure node, real timers (the bound is wall time).
set -uo pipefail
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
t() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
# s <bound ms> <watch: none|idle|busy:<ms>> <dom: still|busy> -> elapsed ms, rounded to 100
s() { node -e '
  const aria = require("./browser/lib/aria.cjs");
  const [ms, w, dom] = process.argv.slice(1);
  const sleep = (n) => new Promise((r) => setTimeout(r, n));
  const t0 = Date.now();
  const page = {
    waitForTimeout: sleep,
    evaluate: async (fn, q) => { await sleep(q); return dom === "still"; },
  };
  const busyMs = w.startsWith("busy:") ? Number(w.slice(5)) : 0;
  const watch = w === "none" ? null : { inflight: () => (Date.now() - t0 < busyMs ? 1 : 0), stop: () => {} };
  aria.settleQuiet(page, Number(ms), watch).then(() => console.log(Math.round((Date.now() - t0) / 100) * 100));
' "$@"; }

t 'S1 no watch (the one-shot driver, a stub page): the fixed wait, as before' 1200 "$(s 1200 none still)"
t 'S2 nothing in flight and a still DOM: done at the 0.25 s floor plus one quiet look' 500 "$(s 1200 idle still)"
t 'S3 a request in flight for 0.7 s: waited out, then the quiet look' 1000 "$(s 1200 busy:700 still)"
t 'S4 a DOM that never stops changing: the full bound, never more' 1200 "$(s 1200 idle busy)"
t 'S5 a request that never finishes (a long poll): the full bound, never more' 1200 "$(s 1200 busy:99999 still)"
t 'S6 a zero settle waits nothing' 0 "$(s 0 idle still)"

# requestWatch counts document, XHR and fetch requests until they finish or fail.
t 'S7 requestWatch: in flight counts document/xhr/fetch only, and stop() detaches' '2 1 0 0' "$(node -e '
  const aria = require("./browser/lib/aria.cjs");
  const L = {}; const ctx = { on: (e, f) => { (L[e] = L[e] || []).push(f); }, off: (e, f) => { L[e] = (L[e] || []).filter((g) => g !== f); } };
  const fire = (e, r) => (L[e] || []).forEach((f) => f(r));
  const req = (type) => ({ resourceType: () => type });
  const w = aria.requestWatch(ctx);
  const a = req("xhr"), b = req("document"), c = req("image");
  fire("request", a); fire("request", b); fire("request", c); const n1 = w.inflight();
  fire("requestfinished", a); const n2 = w.inflight();
  fire("requestfailed", b); const n3 = w.inflight();
  w.stop(); fire("request", req("fetch"));
  console.log(n1, n2, n3, w.inflight());
')"
t 'S8 requestWatch on something with no events (a stub) is no watch at all' null "$(node -e '
  console.log(JSON.stringify(require("./browser/lib/aria.cjs").requestWatch({})));')"

# clickStep: the bound a ref click gets, with and without something on its centre.
# c <selector> <what sits on it: none|<description>|THROW> -> the timeout page.click got, and the log
c() { node -e '
  const aria = require("./browser/lib/aria.cjs");
  const [sel, cover] = process.argv.slice(1);
  const logs = [];
  const page = {
    locator: () => ({ isVisible: async () => true,
      evaluate: async () => { if (cover === "THROW") throw new Error("detached"); return cover === "none" ? null : cover; } }),
    click: async (x, o) => o.timeout,
  };
  aria.clickStep(page, { selector: sel }, "[data-5dive-ref=r1]", 5000, { log: (l) => logs.push(l) })
    .then((ms) => console.log(ms + (logs.length ? " | " + logs.join(" ") : "")));
' "$@"; }

t 'S9 a ref click with nothing on it keeps its 5 s' 5000 "$(c 'ref=button/Add' none)"
t 'S10 a ref click under a cookie banner gets 1.5 s, and says what covers it' \
  '1500 | step ref=button/Add: div#onetrust-consent-sdk sits on it, so the click gets 1.5 s, not 5 s' \
  "$(c 'ref=button/Add' 'div#onetrust-consent-sdk')"
t 'S11 a cover check that throws (the element went away) keeps the 5 s' 5000 "$(c 'ref=button/Add' THROW)"
t 'S12 NEGATIVE: a CSS selector (a recipe) keeps Playwright click exactly, no cover check' 5000 "$(c 'button.add' 'div#banner')"

# The daemon's act path uses them: the act goto settles quietly, and both re-reads get the watch.
t 'S13 session-daemon settles the act goto, the snapshot load and each read tab through settleQuiet' 3 "$(grep -c 'await aria.settleQuiet(page, [a-z]*, watch)' browser/bin/session-daemon)"
t 'S14 session-daemon hands the watch to both act re-reads (done and failed)' 2 "$(grep -c 'await sendReport(page, req, send, {.*watch' browser/bin/session-daemon)"
t 'S15 session-daemon stops the watch wherever the plan ends after it started' 3 "$(grep -c '^ *done();' browser/bin/session-daemon)"

# lib/popup.cjs sync: the wait for a window a click opens ends when the page is quiet.
# p <quiet: none|<ms>|never> <popup at ms or none> -> elapsed ms (to 100), settled, page in view
p() { node -e '
  const { follow } = require("./browser/lib/popup.cjs");
  const [q, pop] = process.argv.slice(1);
  const sleep = (n) => new Promise((r) => setTimeout(r, n));
  const L = {}; const mk = (name) => ({ name, on: (e, f) => { (L[e] = L[e] || []).push(f); }, off: () => {}, url: () => "https://" + name + ".test/", isClosed: () => false });
  const start = mk("start");
  const f = follow(start);
  if (pop !== "none") setTimeout(() => (L.popup || []).forEach((fn) => fn(mk("popup"))), Number(pop));
  const quiet = q === "none" ? null : async (ms) => { if (q === "never") { await sleep(ms); return false; } await sleep(Number(q)); return true; };
  const t0 = Date.now();
  f.sync("click", quiet).then((pg) => console.log(Math.round((Date.now() - t0) / 100) * 100, f.settled, pg.name));
' "$@"; }
t 'S16 no quiet probe (the one-shot driver): the full second, as before' '1000 false start' "$(p none none)"
t 'S17 a page quiet at 0.3 s: the wait ends then, and the re-read is told it settled' '300 true start' "$(p 300 none)"
t 'S18 a page that never goes quiet: the full second, not settled' '1000 false never' "$(p never none | sed 's/start$/never/')"
t 'S19 a popup at 0.2 s still wins, and is not called settled' '200 false popup' "$(p 600 200)"
t 'S20 a fill (it opens no window) waits nothing' '0' "$(node -e '
  const f = require("./browser/lib/popup.cjs").follow({ on: () => {}, off: () => {}, url: () => "", isClosed: () => false });
  const t0 = Date.now(); f.sync("fill", async () => true).then(() => console.log(Math.round((Date.now() - t0) / 100) * 100));')"
t 'S21 the daemon skips the re-read settle only when the page settled AND no --settle was asked' 1 "$(grep -c 'settled && req.settle === undefined ? 0' browser/bin/session-daemon)"

echo "settle: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
