#!/usr/bin/env bash
# DIVE-6966 — the page map reaches inside frames, and a step follows a ref into one.
#
# On bench v3 Chase's IRA calculator (om2w-9ed38272) sat in a cross-origin iframe:
# 5dive's `snapshot` listed 0 of its controls, OpenClaw snapshotted the frame and set
# each slider with ArrowUp. The walk now runs in every drawn child frame through
# Playwright's own handle on it, and a frame's refs name the frame:
#   ref=frame:IRA calculator >> slider/Annual contribution
#
# Graded on a page/frame shim (no Chrome on this host): each Frame swaps the global
# document before running a page function, which is what frame.evaluate means.
set -uo pipefail
cd "$(dirname "$0")/.."
ARIA="$PWD/browser/lib/aria.cjs"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }
tn() { if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected NOT to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }

cat > "$TMP/frames.js" <<'SHIM'
const aria = require(process.env.ARIA);
class El {
  constructor(tag, attrs = {}, text = '', kids = [], css = {}) {
    this.tagName = tag.toUpperCase(); this._a = attrs; this._t = text; this.kids = kids; this.css = css;
    kids.forEach(k => { k.parent = this; });
  }
  get parentElement() { return this.parent || null; }
  get id() { return this._a.id || ''; }
  get type() { return this._a.type || ''; }
  get value() { return this._a.value || ''; }
  getAttribute(n) { return Object.prototype.hasOwnProperty.call(this._a, n) ? this._a[n] : null; }
  hasAttribute(n) { return Object.prototype.hasOwnProperty.call(this._a, n); }
  setAttribute(n, v) { this._a[n] = v; }
  get textContent() { return this._t + this.kids.map(k => k.textContent).join(''); }
  get innerText() { return this.textContent; }
  closest() { return null; }
  getRootNode() { return this.doc; }
  get ownerDocument() { return this.doc; }
  getClientRects() { return this.css.display === 'none' ? [] : [{}]; }
  getBoundingClientRect() { return { width: this.css.w ?? 300, height: this.css.h ?? 200 }; }
  querySelector() { return null; }
}
class Doc {
  constructor(body) {
    this.body = body; this.title = '';
    this.defaultView = { getComputedStyle: (e) => ({ display: e.css.display || 'block', visibility: 'visible', cursor: 'auto' }) };
    this.flat().forEach(e => { e.doc = this; });
  }
  flat() { const out = []; const go = (e) => { out.push(e); e.kids.forEach(go); }; go(this.body); return out; }
  get documentElement() { return { outerHTML: '<html>' + this.body.textContent + '</html>' }; }
  querySelectorAll(q) {
    if (q === 'input,textarea,select') return this.flat().filter(e => ['INPUT', 'TEXTAREA', 'SELECT'].includes(e.tagName));
    if (q === '*') return this.flat();
    return [];
  }
  querySelector(q) {
    const m = /^\[(data-5dive-(?:frame|ref))="(.*)"\]$/.exec(q);
    return m ? this.flat().find(e => e.getAttribute(m[1]) === m[2]) || null : null;
  }
  getElementById(id) { return this.flat().find(e => e.id === id) || null; }
}
const calls = { frameEval: 0, childFrames: 0 };
class Frame {
  constructor(name, doc, el = null, kids = []) {
    this.name = name; this.doc = doc; this.el = el; this.kids = kids; this.parent = null;
    kids.forEach(k => { k.parent = this; });
  }
  enter() { global.document = this.doc; global.location = { href: 'https://' + this.name + '/' }; }
  async evaluate(fn, arg) { if (this.parent) calls.frameEval++; this.enter(); return fn(arg); }
  childFrames() { calls.childFrames++; return this.kids; }
  parentFrame() { return this.parent; }
  async frameElement() {
    const el = this.el, parent = this.parent;
    return { evaluate: async (fn, v) => { parent.enter(); return fn(el, v); }, dispose: async () => {} };
  }
  async $(sel) {
    const el = this.doc.querySelector(sel);
    if (!el) return null;
    const fr = this.kids.find(k => k.el === el) || null;
    return { contentFrame: async () => fr };
  }
}
const P = (w = 300, h = 200, display) => ({ w, h, display });
// the calculator, cross-origin, no title: named by its host
const calcBody = new El('body', {}, 'Your balance at 65: $412,000', [
  new El('input', { type: 'range', 'aria-label': 'Annual contribution', value: '6000' }),
  new El('input', { type: 'range', 'aria-label': 'Current age', value: '30' }),
  new El('button', {}, 'Go'),
]);
const calcDoc = new Doc(calcBody);
// two chat widgets with one title, the second holding a nested frame
const chat1 = new Doc(new El('body', {}, '', [new El('button', {}, 'Start chat')]));
const innerDoc = new Doc(new El('body', {}, '', [new El('a', { href: '/x' }, 'Deep link')]));
const chat2 = new Doc(new El('body', {}, '', [new El('button', {}, 'Start chat'), new El('iframe', { title: 'inner' }, '', [], P())]));
const hiddenDoc = new Doc(new El('body', {}, '', [new El('button', {}, 'Ghost')]));
const pixelDoc = new Doc(new El('body', {}, '', [new El('button', {}, 'Pixel')]));

const calcEl = new El('iframe', { src: 'https://calculators.chase.example/ira' }, '', [], P());
const chat1El = new El('iframe', { title: 'Chat' }, '', [], P());
const chat2El = new El('iframe', { title: 'Chat' }, '', [], P());
const hidEl = new El('iframe', { title: 'Hidden' }, '', [], P(300, 200, 'none'));
const pixEl = new El('iframe', { title: 'Pixel' }, '', [], P(1, 1));
const top = new Doc(new El('body', {}, 'Retirement planning', [
  new El('button', {}, 'Go'),
  new El('a', { href: '/home' }, 'Home'),
  calcEl, chat1El, chat2El, hidEl, pixEl,
]));
const inner = new Frame('inner.example', innerDoc, chat2.body.kids[1]);
const fCalc = new Frame('calculators.chase.example', calcDoc, calcEl);
const main = new Frame('www.chase.example', top, null, [
  fCalc,
  new Frame('chat.example', chat1, chat1El),
  new Frame('chat.example', chat2, chat2El, [inner]),
  new Frame('hidden.example', hiddenDoc, hidEl),
  new Frame('pixel.example', pixelDoc, pixEl),
]);
const page = {
  mainFrame: () => main,
  evaluate: (fn, arg) => main.evaluate(fn, arg),
  $: (s) => main.$(s),
  url: async () => 'https://www.chase.example/ira',
  title: async () => 'IRA',
  content: async () => '<html></html>',
};
global.CSS = { escape: (s) => s };

(async () => {
  const out = {};
  const w = await aria.walk(page, { interactiveOnly: true });
  out.refs = w.nodes.map(n => n.ref);
  const s = await aria.snapshot(page, { interactiveOnly: true });
  out.snapRefs = s.nodes.map(n => n.ref);
  // a step on the page's own control does not visit frames
  calls.frameEval = 0; calls.childFrames = 0;
  out.mainSel = await aria.resolveRef(page, 'ref=button/Go');
  out.mainCost = calls.frameEval + calls.childFrames;
  // a step on a frame's control
  out.frameSel = await aria.resolveRef(page, 'ref=frame:calculators.chase.example >> slider/Annual contribution');
  out.calcFrameMark = calcEl.getAttribute('data-5dive-frame');
  const slider = calcBody.kids[0];
  out.sliderMark = slider.getAttribute('data-5dive-ref');
  const ff = await aria.frameFor(page, out.frameSel);
  out.frameForIsCalc = ff.at === fCalc;
  out.frameForSel = ff.sel;
  out.nestedSel = await aria.resolveRef(page, 'ref=frame:Chat#2 >> frame:inner >> link/Deep link');
  out.nestedMarked = innerDoc.body.kids[0].getAttribute('data-5dive-ref') !== null;
  try { await aria.resolveRef(page, 'ref=frame:calculators.chase.example >> slider/Retirement age'); out.miss = 'resolved'; }
  catch (e) { out.miss = (e.refMiss ? 'refMiss ' : '') + e.message; }
  try { await aria.resolveRef(page, 'ref=frame:Nope >> button/Go'); out.frameMiss = 'resolved'; }
  catch (e) { out.frameMiss = (e.refMiss ? 'refMiss ' : '') + e.message; }
  out.parts = aria.splitRef('frame:A >> frame:B#2 >> button/x >> y');
  out.field = aria.fieldRoleMatch([{ ref: 'frame:F >> combobox/Search' }], 'frame:F >> searchbox/Search');
  // the owner's check reads a frame's control in its frame
  const payDoc = new Doc(new El('body', {}, '', [new El('button', { 'aria-label': 'Pay now' }, 'Continue')]));
  const payEl = new El('iframe', { title: 'Checkout' }, '', [], P());
  top.body.kids.push(payEl); payEl.parent = top.body; payEl.doc = top;
  const fPay = new Frame('pay.example', payDoc, payEl); fPay.parent = main; main.kids.push(fPay);
  const paySel = await aria.resolveRef(page, 'ref=frame:Checkout >> button/Pay now');
  let labelAt = null;
  const orig = fPay.evaluate.bind(fPay);
  fPay.evaluate = async (fn, arg) => { if (arg && arg.riskOf) labelAt = 'frame'; return orig(fn, arg); };
  const origMain = main.evaluate.bind(main);
  main.evaluate = async (fn, arg) => { if (arg && arg.riskOf) labelAt = 'page'; return origMain(fn, arg); };
  const risk = await aria.stepRisk(page, { op: 'click', selector: 'ref=frame:Checkout >> button/Pay now' }, paySel);
  out.riskCls = risk && risk.cls; out.labelAt = labelAt;
  // the re-read after an act reads the frame's text: --expect is graded on it
  const after = await aria.pageAfter(page, { expect: '412,000' });
  out.afterText = /412,000/.test(after.text);
  out.afterValues = after.values;
  // a page with no frame API (every older test shim) walks exactly as before
  const bare = { evaluate: (fn, arg) => main.evaluate(fn, arg) };
  out.bareRefs = (await aria.walk(bare, { interactiveOnly: true })).nodes.map(n => n.ref);
  console.log(JSON.stringify(out));
})().catch(e => { console.log(JSON.stringify({ crash: String(e && e.stack || e) })); });
SHIM

R="$(ARIA="$ARIA" node "$TMP/frames.js")"
j() { jq -r "$1" <<<"$R"; }
REFS="$(j '.refs|join("|")')"
t  'F0 (control) the shim ran' 'null' "$(j '.crash')"
tc 'F1 a cross-origin frame with no title is named by its host, its slider listed' 'frame:calculators.chase.example >> slider/Annual contribution' "$REFS"
tc 'F1b ...the second slider too' 'frame:calculators.chase.example >> slider/Current age' "$REFS"
tc 'F2 the page own button keeps its ref' '|button/Go|' "|$REFS|"
tn 'F2b ...with no #n: a frame with the same button never renumbers the page' 'button/Go#' "$REFS"
tc 'F2c the frame counts its own: its button is plain too' 'frame:calculators.chase.example >> button/Go' "$REFS"
tc 'F3 two sibling frames with one title take #n' 'frame:Chat#1 >> button/Start chat' "$REFS"
tc 'F3b ...' 'frame:Chat#2 >> button/Start chat' "$REFS"
tc 'F4 a nested frame chains its frames' 'frame:Chat#2 >> frame:inner >> link/Deep link' "$REFS"
tn 'F5 a frame the page hides is not walked' 'Ghost' "$REFS"
tn 'F5b a 1x1 tracking frame is not walked' 'Pixel' "$REFS"
t  'F6 snapshot lists exactly what the walk lists (one walk)' "$REFS" "$(j '.snapRefs|join("|")')"
t  'F7 a step on the page own control resolves as before' '[data-5dive-ref="r0"]' "$(j '.mainSel')"
t  'F7b ...and does not visit a single frame' '0' "$(j '.mainCost')"
FS="$(j '.frameSel')"
t  'F8 a frame ref resolves to one selector that enters the frame' 'yes' \
   "$([[ "$FS" == '[data-5dive-frame="'*'"] >> internal:control=enter-frame >> [data-5dive-ref="r0"]' ]] && echo yes || echo no)"
tc 'F8b ...the iframe element carries the frame marker it names' "[data-5dive-frame=\"$(j '.calcFrameMark')\"]" "$FS"
t  'F8c ...and the slider carries the element marker' 'r0' "$(j '.sliderMark')"
t  'F9 frameFor lands in the calculator frame' 'true' "$(j '.frameForIsCalc')"
t  'F9b ...with the selector inside it' '[data-5dive-ref="r0"]' "$(j '.frameForSel')"
t  'F10 a nested ref enters both frames' '2' "$(j '.nestedSel' | grep -o 'internal:control=enter-frame' | wc -l | tr -d ' ')"
t  'F10b ...and marks the link in the inner one' 'true' "$(j '.nestedMarked')"
tc 'F11 a miss inside a frame is a refMiss (the poll and the repick read it)' 'refMiss' "$(j '.miss')"
tc 'F11b ...whose hint names the sliders that ARE there, in their frame' 'ref=frame:calculators.chase.example >> slider/Annual contribution' "$(j '.miss')"
tc 'F12 a frame that is not on the page is a refMiss too' 'refMiss' "$(j '.frameMiss')"
t  'F13 splitRef reads the frame chain and leaves the element whole' '["A","B#2"] button/x >> y' "$(j '.parts.frames|tojson') $(j '.parts.el')"
t  'F14 the same field under another role keeps its frame' 'frame:F >> combobox/Search' "$(j '.field')"
t  "F15 the owner's check reads a frame's button in its frame" 'frame pay' "$(j '.labelAt') $(j '.riskCls')"
t  "F16 the re-read after an act holds the frame's text (--expect grades it)" 'true' "$(j '.afterText')"
tc "F16b ...and the frame's field values" '6000' "$(j '.afterValues')"
t  'F17 a page with no frame API walks as before (older shims)' 'button/Go|link/Home' "$(j '.bareRefs|join("|")')"

# ---- the mutants: each part of the change, removed, turns its arm red ---------
MUT="$TMP/mut"; mkdir -p "$MUT"
mutate() {  # name, perl substitution -> a copy of aria.cjs; the anchor arm says it landed
  perl -0pe "$2" "$ARIA" > "$MUT/$1.cjs"
  t "X-$1 (anchor) the mutant really differs" 'yes' "$(cmp -s "$ARIA" "$MUT/$1.cjs" && echo no || echo yes)"
}
mutate nowalk 's/  const more = await frameNodes\(page, args\);\n  if \(more.length\) top.nodes = top.nodes.concat\(more\);\n//'
tn 'X1 without the frame walk the slider is gone' 'slider/Annual contribution' \
   "$(ARIA="$MUT/nowalk.cjs" node "$TMP/frames.js" | jq -r '.refs|join("|")')"
mutate nomark 's/  if \(mark && splitRef\(mark\).frames.length\) return markInFrame\(page, mark, interactiveOnly\);\n//'
tn 'X2 without the frame resolve a frame ref does not enter the frame' 'enter-frame' \
   "$(ARIA="$MUT/nomark.cjs" node "$TMP/frames.js" | jq -r '.frameSel')"
mutate norisk 's/  try \{ \(\{ at, sel: inSel \} = await frameFor\(page, sel\)\); \} catch \(e\) \{ at = page; inSel = sel; \}\n//'
t  "X3 without frameFor the owner's check reads the page, not the frame" 'page' \
   "$(ARIA="$MUT/norisk.cjs" node "$TMP/frames.js" | jq -r '.labelAt')"
mutate notext "s/    try \{ const t = await framesEval\(page, _textIn[^\n]*\n//"
t  "X4 without the frame text --expect cannot see the calculator's answer" 'false' \
   "$(ARIA="$MUT/notext.cjs" node "$TMP/frames.js" | jq -r '.afterText')"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
