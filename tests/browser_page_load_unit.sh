#!/usr/bin/env bash
# DIVE-7572 — input mode reads a page's title only once the page has LOADED.
#
# exact-swallow, browser 1.66.3 (2026-11-02): `snapshot amazon.co.jp
# https://www.amazon.co.jp/dp/B00D81RNDK` came back rc 0 titled
# "amazon.co.jp/dp/B00D81RNDK": the ADDRESS Chrome shows while a page has no
# title yet, read at a fixed 2.5 s, so the error page's refused title was never
# matched. lib/page-load.cjs decides "still the address" and waits it out.
#
#   A1-A7  addressTitle: Chrome's loading titles are addresses, real titles are not
#   W1     untilLoaded waits past the address to the page's own title, then the quiet gate
#   W2     a title that never comes ends loaded:false at the bound, not a hang
#   W3     a client redirect that lands back on an address after the quiet gate is not loaded
#
# The live arms (a real Chrome on Xvfb, a page that sends its <title> 4 s late)
# are L16 in tests/browser_input_drive_unit.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
node - "$PWD/browser/lib/page-load.cjs" <<'JS'
const { addressTitle: a, untilLoaded } = require(process.argv[2]);
let pass = 0, fail = 0;
const arm = (name, want, got) => {
  const ok = JSON.stringify(want) === JSON.stringify(got);
  ok ? pass++ : fail++;
  console.log(`${ok ? 'PASS' : 'FAIL'}: ${name}${ok ? '' : ` — want ${JSON.stringify(want)}, got ${JSON.stringify(got)}`}`);
};
const U = 'https://www.amazon.co.jp/dp/B00D81RNDK';
arm('A1 the measured exact-swallow title is the address', true, a('amazon.co.jp/dp/B00D81RNDK', U));
arm('A2 ...with the scheme or www. Chrome sometimes keeps, too', [true, true], [a('https://www.amazon.co.jp/dp/B00D81RNDK', U), a('www.amazon.co.jp/dp/B00D81RNDK/', U)]);
arm('A3 an elided address, another path on the host, and a host:port address', [true, true, true],
  [a('amazon.co.jp/dp/B00D8', U), a('amazon.co.jp/ap/signin?x=1', U), a('127.0.0.1:8080/slow', 'http://127.0.0.1:8080/slow')]);
arm('A4 an empty tab title or New Tab is not a page', [true, true], [a('', U), a('New Tab', U)]);
arm("A5 the error page's own title and a product title are pages", [false, false],
  [a('ご迷惑をおかけしています！', U), a('Amazon.co.jp: Banneren Tea Organic Easy Uji Matcha 30g : 食品・飲料・お酒', U)]);
arm('A6 the bot interstitial titled plain "Amazon.co.jp" is a page (case-sensitive host)', false, a('Amazon.co.jp', U));
arm("A7 another site's one-word title is a page", false, a('GitHub', 'https://github.com/'));

(async () => {
  // A fake clock: sleep advances it, nothing really waits.
  const clock = () => { let t = 0; return { now: () => t, sleep: async (ms) => { t += ms; } }; };
  {
    const c = clock(); let settledAt = -1;
    const titles = (t) => (t < 4000 ? '127.0.0.1:9/slow' : 'Slow Fixture');
    const r = await untilLoaded(async () => titles(c.now()), async () => { settledAt = c.now(); },
      { url: 'http://127.0.0.1:9/slow', minMs: 2500, maxMs: 20000, pollMs: 100, ...c });
    arm('W1 waits past the address (4 s) to the page title, then runs the quiet gate', [true, 'Slow Fixture', true, true],
      [r.loaded, r.title, r.waited_ms >= 4000 && r.waited_ms < 4200, settledAt >= 4000]);
  }
  {
    const c = clock(); let settledRan = false;
    const r = await untilLoaded(async () => 'amazon.co.jp/dp/B00D81RNDK', async () => { settledRan = true; },
      { url: U, minMs: 2500, maxMs: 20000, pollMs: 100, ...c });
    arm('W2 a title that never comes: loaded:false at the 20 s bound, the address as title', [false, 'amazon.co.jp/dp/B00D81RNDK', true],
      [r.loaded, r.title, r.waited_ms >= 20000 && r.waited_ms < 20200]);
  }
  {
    const c = clock(); let n = 0;
    const r = await untilLoaded(async () => (++n === 1 ? 'Redirecting' : 'amazon.co.jp/ap/signin'), async () => {},
      { url: U, minMs: 0, maxMs: 1000, pollMs: 100, ...c });
    arm('W3 a title that goes back to an address after the quiet gate is not loaded', false, r.loaded);
  }
  console.log(`\n${pass} pass, ${fail} fail`);
  process.exit(fail ? 1 : 0);
})();
JS
