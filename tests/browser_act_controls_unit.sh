#!/usr/bin/env bash
# DIVE-7818 — the act steps drive the controls that would not take.
#
# On the 1.70.0 bench (DIVE-7791) 10 of 32 non-wall misses were a filter the agent
# found and could not set: a custom dropdown (`select` is a native <select> only;
# a click on its option "intercepts pointer events" / "not visible") or a slider
# (`fill` refuses anything but a text field; arrow keys said "ok" and moved
# nothing). It then filtered the list by eye, and WebJudge failed it.
#
# REAL CHROME, real DOM: a stub cannot grade what a page does with a click. The
# fixtures are small pages built the way those sites build the control. The
# browser is CHROME_CDP (connectOverCDP, e.g. `ci-browser endpoint`) or the
# runner's Chrome (CHROME, default google-chrome), with playwright-core on
# NODE_PATH. No browser: the C arms are skipped and SAID, unless
# CONTROLS_REQUIRE_BROWSER=1 (CI), where that is a failure.
#
#   C  lib/controls.cjs against real pages, through the step as both loops run it:
#      C1 custom dropdown, option scrolled out of sight in its list (AKC's radius)
#      C2 a control something sits on, options inside it (4shared's Duration)
#      C3 a listbox it owns by aria-controls, drawn at the end of the page, with
#         the same words elsewhere on the page first (a sort menu)
#      C4 a hidden <select> behind the page's own label
#      C5 CONTROL: a visible native <select> by its exact label: the old call
#      C6 an ARIA slider moved by keys (student.com's price)
#      C7 an <input type=range> (fill used to refuse it)
#      C8 a slider keys do not move: dragged (WebMD's distance)
#      C9 no option with those words: the step fails and lists the options
#      C10 two sliders in one control: the step fails and names both
#      C11 CONTROL: fill on a text field is page.fill, unchanged
#      C12 a slider that will not move fails, never "ok"
#      C13 to its end by Home · C14 `select` on a slider · C15 the owner's four:
#         an option that reads as a delete is refused under the guard
#   W  both step loops call lib/controls.cjs for fill and select
#   U  the url dropped a filter: lib/look.cjs paramsLost + the act's warning line
#
# RED ON MAIN: CONTROLS_TREE=<a tree without lib/controls.cjs> runs each C arm
# through main's case lines (page.fill / page.selectOption), so the same fixture
# grades the old step. `CONTROLS_TREE=<main tree> bash tests/browser_act_controls_unit.sh`.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
TREE="${CONTROLS_TREE:-$ROOT}"
printf 'grading tree: %s @ %s\n' "$TREE" "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }
tn() { if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected NOT to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }

# ============================================================= W  wiring
for f in session-daemon driver-playwright; do
  t "W1 $f: fill goes through lib/controls.cjs" 1 "$(grep -c "case 'fill':.*controls.fillStep(page, s, x, timeout" "$TREE/browser/bin/$f")"
  t "W2 $f: select goes through lib/controls.cjs" 1 "$(grep -c "case 'select':.*controls.selectStep(page, s, x, timeout" "$TREE/browser/bin/$f")"
done

# ============================================================= U  the url dropped a filter
U="$(node -e '
const L = require(process.argv[1]);
if (typeof L.paramsLost !== "function") { console.log("no paramsLost"); process.exit(0); }
const a = L.lookOf("https://shop.test/s?q=tv&sp=Price-Low-To-High&utm_source=x&page=2", [], "x");
const b = L.lookOf("https://shop.test/s?q=tv", [], "x");
const o = L.lookOf("https://other.test/s?q=tv", [], "x");
console.log([JSON.stringify(L.compare(a, b).params_lost), JSON.stringify(L.compare(a, o).params_lost),
  JSON.stringify(L.compare(null, b).params_lost), JSON.stringify(L.paramsLost("not a url", "https://x.test/")),
  JSON.stringify(L.paramsLost("https://x.test/s?a=1&b=2&c=3&d=4&e=5&f=6&g=7&h=8", "https://x.test/s"))].join("\n"));
' "$TREE/browser/lib/look.cjs" 2>&1)"
t 'U1 same page, sp= gone: said; tracking and paging keys are not filters' '["sp=Price-Low-To-High"]' "$(sed -n 1p <<<"$U")"
t 'U2 another page: nothing dropped' '[]' "$(sed -n 2p <<<"$U")"
t 'U3 the first look: nothing dropped' '[]' "$(sed -n 3p <<<"$U")"
t 'U4 not a url: nothing' '[]' "$(sed -n 4p <<<"$U")"
t 'U5 at most six' 6 "$(sed -n 5p <<<"$U" | jq length 2>/dev/null)"
eval "$(awk '/^_act_look_say\(\) \{/{f=1} f{print} f&&/^}/{f=0}' "$TREE/browser/bin/browser")"
base='{same_url:true,refs_now:9,refs_added:[],refs_added_total:0,refs_removed:[],refs_removed_total:0,options:[],text_added:["x"],text_added_total:1,text_removed_total:0}'
jq -nc "{look:($base + {params_lost:[\"sp=Price-Low-To-High\"]})}" > "$TMP/u1.json"
SAY="$(_act_look_say "$TMP/u1.json" 2>&1)"
tc 'U6 the act says the dropped key' '  ! the url dropped sp=Price-Low-To-High: a filter or sort you set may be undone; check it is still on before you answer' "$SAY"
tn 'U7 ...and no `set now:` line (PR #136 did not help; not kept)' 'set now' "$SAY"
jq -nc "{look:($base + {params_lost:[]})}" > "$TMP/u2.json"
tn 'U8 nothing dropped: no warning' 'url dropped' "$(_act_look_say "$TMP/u2.json" 2>&1)"
jq -nc "{look:$base}" > "$TMP/u3.json"
tn 'U9 an older daemon'"'"'s look (no params_lost): no warning' 'url dropped' "$(_act_look_say "$TMP/u3.json" 2>&1)"

# ============================================================= C  real pages
cat > "$TMP/c.js" <<'JS'
const path = require('path');
const tree = process.argv[2];
let pw;
// NODE_PATH first: the script sits under the temp dir, and a node_modules above it would win.
try { pw = require(require.resolve('playwright-core', { paths: String(process.env.NODE_PATH || '').split(':').filter(Boolean).concat([__dirname]) })); }
catch (e) { console.log('NOBROWSER no playwright-core on NODE_PATH'); process.exit(0); }
let controls = null;
try { controls = require(path.join(tree, 'browser', 'lib', 'controls.cjs')); } catch (e) { controls = null; }
// THE STEP AS THE LOOPS RUN IT; without lib/controls.cjs, main's case lines.
const logs = [];
const log = (l) => logs.push(l);
const fill = (page, s, x, t, o = {}) => controls ? controls.fillStep(page, s, x, t, { log, ...o }) : page.fill(x, s.value, { timeout: t });
const select = (page, s, x, t, o = {}) => controls ? controls.selectStep(page, s, x, t, { log, ...o }) : page.selectOption(x, s.value, { timeout: t });
const STEP_MS = 5000;

const F = {};
F.akc = `<style>#list li{height:30px;line-height:30px;padding:0 8px;cursor:pointer;position:relative}
#list li input{position:absolute;inset:0;opacity:0;width:1px;height:1px}</style>
<div class="dd"><button id="trig" data-5dive-ref="t" onclick="document.getElementById('list').style.display='block'">25 miles</button>
<ul id="list" style="display:none;max-height:60px;overflow:auto;margin:0;padding:0;list-style:none;border:1px solid #888;width:160px">
${['10 miles', '25 miles', '50 miles', '100 miles', '250 miles'].map((m) => `<li class="pure-checkbox"><input type="checkbox"><label>${m}</label></li>`).join('')}
</ul></div><p id="out">25</p>
<script>document.querySelectorAll('#list li').forEach(function (li) { li.addEventListener('click', function () {
  document.getElementById('trig').textContent = li.textContent.trim(); document.getElementById('list').style.display = 'none';
  document.getElementById('out').textContent = parseInt(li.textContent, 10); }); });</script>`;
F.cover = `<div id="w" data-5dive-ref="t" style="position:relative;width:220px;height:30px;border:1px solid #888">
<span class="cur">Duration All</span>
<ul id="opts" style="display:none;position:absolute;top:30px;left:0;margin:0;padding:0;list-style:none;background:#fff;width:220px">
<li><a href="#" data-v="all">All</a></li><li><a href="#" data-v="short">Short (&lt;4 minutes)</a></li><li><a href="#" data-v="long">Long (20+ minutes)</a></li></ul></div>
<div style="position:absolute;top:0;left:0;width:400px;height:200px;z-index:5"></div>
<script>var w = document.getElementById('w');
w.addEventListener('click', function (e) { if (e.target.tagName !== 'A') document.getElementById('opts').style.display = 'block'; });
document.querySelectorAll('#opts a').forEach(function (a) { a.addEventListener('click', function (e) { e.preventDefault();
  document.querySelector('#w .cur').textContent = 'Duration ' + a.textContent; document.getElementById('opts').style.display = 'none';
  w.dataset.chosen = a.dataset.v; }); });</script>`;
F.listbox = `<p>Popular: <span>Price: low to high</span></p>
<button id="sort" data-5dive-ref="t" aria-haspopup="listbox" aria-controls="lb">Sort: Relevance</button>
<script>document.getElementById('sort').addEventListener('click', function () {
  if (document.getElementById('lb')) return;
  var lb = document.createElement('div'); lb.id = 'lb'; lb.setAttribute('role', 'listbox');
  ['Relevance', 'Price: low to high', 'Newest'].forEach(function (t) { var o = document.createElement('div'); o.setAttribute('role', 'option'); o.textContent = t;
    o.addEventListener('click', function () { document.getElementById('sort').textContent = 'Sort: ' + t; o.setAttribute('aria-selected', 'true'); lb.remove(); });
    lb.appendChild(o); });
  document.body.appendChild(lb); });</script>`;
F.hidden = `<select id="s" data-5dive-ref="t" style="display:none"><option value="rel">Relevance</option><option value="new">Newest</option></select>
<span id="lab">Relevance</span><script>document.getElementById('s').addEventListener('change', function (e) {
  document.getElementById('lab').textContent = e.target.selectedOptions[0].textContent; });</script>`;
F.native = `<select id="s" data-5dive-ref="t"><option value="rel">Relevance</option><option value="new">Newest</option></select>`;
F.aria = `<div id="sl" data-5dive-ref="t" role="slider" tabindex="0" aria-label="Maximum" aria-valuemin="0" aria-valuemax="2000" aria-valuenow="2000"
 style="width:20px;height:20px;background:#333"></div><span id="out">2000</span>
<script>var sl = document.getElementById('sl'); sl.addEventListener('keydown', function (e) {
  var v = +sl.getAttribute('aria-valuenow');
  if (e.key === 'ArrowRight' || e.key === 'ArrowUp') v += 50; else if (e.key === 'ArrowLeft' || e.key === 'ArrowDown') v -= 50;
  else if (e.key === 'Home') v = 0; else if (e.key === 'End') v = 2000; else return;
  v = Math.max(0, Math.min(2000, v)); sl.setAttribute('aria-valuenow', v); document.getElementById('out').textContent = v; e.preventDefault(); });</script>`;
F.range = `<input id="r" data-5dive-ref="t" type="range" min="5" max="100" step="5" value="25"><span id="out">25</span>
<script>document.getElementById('r').addEventListener('input', function (e) { document.getElementById('out').textContent = e.target.value; });</script>`;
F.drag = `<div id="track" style="position:relative;margin:40px;width:300px;height:8px;background:#ccc">
<div id="th" data-5dive-ref="t" role="slider" aria-label="Distance slider from 5 to 100 miles" aria-valuemin="5" aria-valuemax="100" aria-valuenow="25"
 style="position:absolute;top:-6px;width:20px;height:20px;margin-left:-10px;background:#333;border-radius:10px"></div></div><span id="out">25</span>
<script>var tr = document.getElementById('track'), th = document.getElementById('th'), on = false;
function put(v) { th.style.left = ((v - 5) / 95 * 300) + 'px'; th.setAttribute('aria-valuenow', v); document.getElementById('out').textContent = v; }
put(25);
th.addEventListener('pointerdown', function (e) { on = true; e.preventDefault(); });
document.addEventListener('pointermove', function (e) { if (!on) return; var r = tr.getBoundingClientRect();
  var f = Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)); put(Math.round((5 + f * 95) / 5) * 5); });
document.addEventListener('pointerup', function () { on = false; });</script>`;
F.two = `<div data-5dive-ref="t"><div role="slider" aria-label="Minimum" aria-valuenow="0" tabindex="0">a</div>
<div role="slider" aria-label="Maximum" aria-valuenow="9" tabindex="0">b</div></div>`;
F.text = `<input id="q" data-5dive-ref="t" type="text" value="">`;
F.stuck = `<div id="sl" data-5dive-ref="t" role="slider" tabindex="0" aria-valuemin="0" aria-valuemax="100" aria-valuenow="10" style="width:20px;height:20px;background:#333"></div>`;

const X = '[data-5dive-ref="t"]';
async function arm(page, name, html, op, value, check, o = {}) {
  logs.length = 0;
  await page.setContent(`<!doctype html><html><body style="font:16px sans-serif">${html}</body></html>`);
  const s = { op, selector: 'ref=x/t', value };
  let err = null; const t0 = Date.now();
  try { await (op === 'fill' ? fill : select)(page, s, X, STEP_MS, o); } catch (e) { err = String(e && e.message || e).split('\n')[0]; }
  const ms = Date.now() - t0;
  let r;
  try { r = await check(page, err); } catch (e) { r = `check threw: ${e.message}`; }
  console.log(JSON.stringify({ name, err, ms, log: logs.join(' | '), r }));
}
const txt = (sel) => (page) => page.textContent(sel).then((x) => x.trim());
(async () => {
  let browser, page;
  try {
    if (process.env.CHROME_CDP) {
      browser = await pw.chromium.connectOverCDP(process.env.CHROME_CDP);
      const ctx = await browser.newContext();
      await ctx.addInitScript('window.__5diveAutomation = true');
      page = await ctx.newPage();
    } else {
      browser = await pw.chromium.launch({ executablePath: process.env.CHROME || 'google-chrome', headless: true, args: ['--no-sandbox'] });
      page = await browser.newPage();
    }
  } catch (e) { console.log(`NOBROWSER ${String(e.message).split('\n')[0]}`); process.exit(0); }
  await page.setViewportSize({ width: 800, height: 600 });
  await arm(page, 'C1', F.akc, 'select', '50 miles', async (p) => `${await txt('#trig')(p)}|${await txt('#out')(p)}`);
  await arm(page, 'C2', F.cover, 'select', 'Long (20+ minutes)', async (p) => `${await txt('#w .cur')(p)}|${await p.$eval('#w', (e) => e.dataset.chosen || '')}`);
  await arm(page, 'C3', F.listbox, 'select', 'Price: low to high', txt('#sort'));
  await arm(page, 'C4', F.hidden, 'select', 'Newest', async (p) => `${await p.$eval('#s', (e) => e.value)}|${await txt('#lab')(p)}`);
  await arm(page, 'C5', F.native, 'select', 'Newest', (p) => p.$eval('#s', (e) => e.value));
  await arm(page, 'C6', F.aria, 'fill', '1200', async (p) => `${await p.$eval('#sl', (e) => e.getAttribute('aria-valuenow'))}|${await txt('#out')(p)}`);
  await arm(page, 'C7', F.range, 'fill', '50', async (p) => `${await p.$eval('#r', (e) => e.value)}|${await txt('#out')(p)}`);
  await arm(page, 'C8', F.drag, 'fill', '50', (p) => p.$eval('#th', (e) => e.getAttribute('aria-valuenow')));
  await arm(page, 'C9', F.akc, 'select', '500 miles', txt('#trig'));
  await arm(page, 'C10', F.two, 'fill', '5', async () => 'n/a');
  await arm(page, 'C11', F.text, 'fill', 'hello', (p) => p.$eval('#q', (e) => e.value));
  await arm(page, 'C12', F.stuck, 'fill', '60', (p) => p.$eval('#sl', (e) => e.getAttribute('aria-valuenow')));
  await arm(page, 'C13', F.aria, 'fill', '$0', (p) => p.$eval('#sl', (e) => e.getAttribute('aria-valuenow')));
  await arm(page, 'C14', F.aria, 'select', '650', (p) => p.$eval('#sl', (e) => e.getAttribute('aria-valuenow')));
  // The owner's four: an option that reads as a delete is not clicked from a select.
  await arm(page, 'C15', F.akc.replace('250 miles', 'Delete account'), 'select', 'Delete account', txt('#trig'), { guard: true });
  await browser.close().catch(() => {});
})().catch((e) => { console.log(`HARNESS-ERROR ${e.message}`); process.exit(1); });
JS
C="$(node "$TMP/c.js" "$TREE" 2>&1)"
if grep -q '^NOBROWSER' <<<"$C"; then
  if [[ "${CONTROLS_REQUIRE_BROWSER:-0}" == 1 ]]; then t 'C0 a real browser to grade the controls on' yes "no: $C"
  else printf 'SKIP: the C arms need a real browser (%s); set CHROME_CDP or CHROME\n' "$C"; fi
else
  tn 'C0 the harness ran' 'HARNESS-ERROR' "$C"
  j() { jq -r --arg n "$1" "select(.name==\$n)|$2" <<<"$(grep '^{' <<<"$C")"; }
  t  'C1 custom dropdown, option out of sight in its list: picked, the control reads it' '50 miles|50' "$(j C1 .r)"
  tc 'C1 ...and the step says what it reads now' 'it now reads "50 miles"' "$(j C1 .log)"
  t  'C1 ...no error' null "$(j C1 .err)"
  t  'C2 something sits on the control, options inside it: picked' 'Duration Long (20+ minutes)|long' "$(j C2 .r)"
  tc 'C2 ...and the step says it went through the page' 'through the page' "$(j C2 .log)"
  t  'C3 the listbox it owns, not the same words elsewhere on the page' 'Sort: Price: low to high' "$(j C3 .r)"
  t  'C4 a hidden <select>: set, and the page heard it' 'new|Newest' "$(j C4 .r)"
  tc 'C4 ...said so' 'hidden <select>' "$(j C4 .log)"
  t  'C5 CONTROL: a visible <select> by its label, as before' 'new' "$(j C5 .r)"
  t  'C5 ...with nothing extra said' '' "$(j C5 .log)"
  t  'C6 an ARIA slider by keys: reads the value' '1200|1200' "$(j C6 .r)"
  tc 'C6 ...and the step says it, from the slider' 'the slider now reads 1200' "$(j C6 .log)"
  t  'C7 CONTROL: an <input type=range> (page.fill already takes it): set, the page heard it' '50|50' "$(j C7 .r)"
  t  'C8 a slider keys do not move: dragged to it' '50' "$(j C8 .r)"
  tc 'C8 ...said it was dragged' 'dragged' "$(j C8 .log)"
  tc 'C9 no such option: the step fails and lists the options' 'The options it shows: "10 miles", "25 miles", "50 miles"' "$(j C9 .err)"
  tc 'C10 two sliders in one control: names both' '"Minimum", "Maximum"' "$(j C10 .err)"
  t  'C11 CONTROL: fill on a text field, as before' 'hello' "$(j C11 .r)"
  t  'C11 ...with nothing extra said' '' "$(j C11 .log)"
  tc 'C12 a slider that will not move: the step fails, with what it reads' 'the slider would not move to 60; it reads 10' "$(j C12 .err)"
  t  'C13 a slider to its end: Home' '0' "$(j C13 .r)"
  t  'C14 select on a slider moves it' '650' "$(j C14 .r)"
  tc 'C15 guard on: an option that reads as a delete is refused, not clicked' 'reads as a delete step' "$(j C15 .err)"
  t  'C15 ...and the control still reads what it did' '25 miles' "$(j C15 .r)"
  printf '%s\n' "$C" | grep '^{' | jq -c '{name, ms, log: (.log // "" | .[0:160]), err: (.err // "" | .[0:90])}' >&2
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
