'use strict';
// ---- THE CONTROLS THAT WOULD NOT TAKE (DIVE-7818) ---------------------------
//
// THE DEFECT. On the 1.70.0 bench (DIVE-7791) 10 of 32 non-wall misses were one
// shape: the agent found the filter the job named, the control would not take,
// and it filtered the result list BY EYE and said so in its answer. WebJudge
// grades the filter shown on the page, so it failed every one. The controls:
//
//   - a CUSTOM DROPDOWN (AKC's radius picker, 4shared's Duration): `select` is
//     page.selectOption, which takes a native <select> only, and a `click` on an
//     option failed with "<li> intercepts pointer events" or "not visible";
//   - a SLIDER (student.com's price, WebMD's distance): `fill` is page.fill,
//     which takes text fields only ("Element is not an <input>"); and pressing
//     arrow keys reported "ok" while the slider never moved, so nothing said so.
//
// THE FIX, in the act steps themselves, so the agent's natural step works:
//
//   select  on a native <select>: page.selectOption, exactly as before, when the
//           value names an option; a hidden <select> behind the page's own widget,
//           or a value that is an option's words but not its exact label, is set
//           through the page and the page told (input + change).
//           on anything else: the option with those words is found (in the list
//           the control owns, inside it, or that opened next to it), the control
//           opened when the option is not shown yet, the option scrolled to and
//           clicked, through the page when something sits on it. The step then
//           says what the control reads now, and warns when it does not read the
//           choice. No option with those words fails the step with the options seen.
//           on a slider: as `fill`.
//   fill    on a slider (role=slider or <input type=range>), only after page.fill
//           refused it, so a text field's fill costs exactly what it did: the
//           value is read back from the slider itself (aria-valuenow or value),
//           moved by keys (Home/End, then arrows, counted from the first step's
//           size), by a drag of its thumb when keys do not move it, and the step
//           says what it reads. A slider that will not reach the value fails the
//           step, with what it reads.
//
// EVERY ANSWER IS READ OFF THE PAGE, never assumed from the keys sent: "ok" on a
// step that changed nothing is how the agent ended up reading lists by eye.
//
// Here and not in either step loop, because there are two of them (as lib/aria.cjs).

const { classifyLabel } = require('./aria.cjs');
const ENTER_FRAME = ' >> internal:control=enter-frame >> ';
const KIND_MS = 1000;          // the look at what the control is; a miss keeps the old step
const OPEN_CLICK_MS = 2000;    // the click that opens a list
const OPEN_WAIT_MS = 2500;     // the list showing its options after that
const POLL_MS = 150;
const OPTION_CLICK_MS = 2500;  // the click on the option; after it, the page's own click
const AFTER_PICK_MS = 400;     // the control redrawing its choice
const PRESS_MAX = 400;         // keys sent to one slider, in all
const SLIDER_READ_MS = 60;     // a slider's value lagging its key by a frame or two
const OPTIONS_SAID = 15;

let seq = 0;
const newId = (p) => `${p}${Date.now().toString(36)}${(seq++).toString(36)}`;
const clean = (x) => String(x == null ? '' : x).replace(/\s+/g, ' ').trim();
const cut = (x, n = 80) => { x = clean(x); return x.length > n ? x.slice(0, n - 1) + '…' : x; };
// The frame a selector enters, so an element marked elsewhere in that frame is found there.
function framePrefix(x) { const i = String(x).lastIndexOf(ENTER_FRAME); return i >= 0 ? x.slice(0, i + ENTER_FRAME.length) : ''; }
const marked = (x, attr, id) => `${framePrefix(x)}[${attr}="${id}"]`;
const sleep = (page, ms) => (page && typeof page.waitForTimeout === 'function')
  ? page.waitForTimeout(ms) : new Promise((r) => setTimeout(r, ms));
function say(log, line) { if (log) log(line); }

// A slider takes a number: "1200", "$1,200", "50 miles", "-3.5".
function toNumber(v) {
  const m = String(v == null ? '' : v).replace(/[,\s]/g, '').match(/-?\d+(?:\.\d+)?/);
  return m ? Number(m[0]) : null;
}

// ---- page side: serialized into the browser, so nothing from module scope ----

// What the control is. `el` is the element the step's selector names.
function _kindIn(el) {
  function shown(e) {
    if (!e.getClientRects().length) return false;
    var s = getComputedStyle(e), r = e.getBoundingClientRect();
    return s.visibility !== 'hidden' && s.visibility !== 'collapse' && r.width > 1 && r.height > 1;
  }
  function opts(sel) {
    var o = [], i;
    for (i = 0; i < sel.options.length && i < 300; i++) o.push({ v: sel.options[i].value, t: sel.options[i].textContent.replace(/\s+/g, ' ').trim() });
    return o;
  }
  var tag = el.tagName.toLowerCase();
  var role = String(el.getAttribute('role') || '').toLowerCase();
  if (tag === 'select') return { kind: 'select', self: true, shown: shown(el), options: opts(el), multiple: !!el.multiple };
  if ((tag === 'input' && String(el.type).toLowerCase() === 'range') || role === 'slider') return { kind: 'slider', self: true };
  var sl = el.querySelectorAll('input[type=range],[role=slider]');
  if (sl.length === 1) return { kind: 'slider', self: false };
  if (sl.length > 1) {
    var names = [];
    for (var i = 0; i < sl.length && i < 6; i++) names.push(sl[i].getAttribute('aria-label') || sl[i].getAttribute('name') || ('#' + (i + 1)));
    return { kind: 'sliders', names: names };
  }
  var se = el.querySelectorAll('select');
  if (se.length === 1) return { kind: 'select', self: false, shown: shown(se[0]), options: opts(se[0]), multiple: !!se[0].multiple };
  return { kind: 'other', role: role, tag: tag };
}

// Set a native <select> through the page: by value, then by its words (exact,
// then the one option that starts with or contains them). Tells the page.
function _setSelectIn(el, a) {
  var sel = el.tagName.toLowerCase() === 'select' ? el : el.querySelector('select');
  if (!sel) return { ok: false, why: 'no list here' };
  function c(x) { return String(x || '').replace(/\s+/g, ' ').trim().toLowerCase(); }
  var want = c(a.value), o = sel.options, hit = -1, i, how = 'exact';
  for (i = 0; i < o.length && hit < 0; i++) if (o[i].value === a.value || c(o[i].textContent) === want || c(o[i].label) === want) hit = i;
  if (hit < 0) {
    var loose = [];
    for (i = 0; i < o.length; i++) if (want && c(o[i].textContent).indexOf(want) === 0) loose.push(i);
    if (!loose.length) for (i = 0; i < o.length; i++) if (want && c(o[i].textContent).indexOf(want) >= 0) loose.push(i);
    if (loose.length === 1) { hit = loose[0]; how = 'loose'; }
    else if (loose.length > 1) {
      return { ok: false, why: 'more than one option has those words: ' + loose.slice(0, 8).map(function (k) { return '"' + c(o[k].textContent) + '"'; }).join(', ') };
    }
  }
  if (hit < 0) {
    var seen = [];
    for (i = 0; i < o.length && i < 15; i++) seen.push(String(o[i].textContent).replace(/\s+/g, ' ').trim());
    return { ok: false, why: 'no option is "' + a.value + '"', seen: seen };
  }
  sel.selectedIndex = hit;
  sel.dispatchEvent(new Event('input', { bubbles: true }));
  sel.dispatchEvent(new Event('change', { bubbles: true }));
  return { ok: true, how: how, text: String(o[hit].textContent).replace(/\s+/g, ' ').trim(), value: sel.value };
}

// THE OPTION WITH THOSE WORDS, for a list that is not a <select>. Marks the best
// one with data-5dive-opt=<a.id> and says where it was found. In order:
//   0  in the list the control owns (aria-controls / aria-owns, its own or a child's)
//   1  inside the control (a menu drawn as its children)
//   2  an option, menu item or radio anywhere on the page
//   3  next to the control (up to four parents up: a panel drawn as its sibling)
//   4  anywhere else (only once the control has been opened: `a.anywhere`)
// Exact words first, on every tier; words that start the option only when no
// option anywhere has the exact words. Of nested elements with the same words,
// the outermost (the <li>, not the <span> inside it).
function _optionIn(el, a) {
  var doc = el.ownerDocument;
  function c(x) { return String(x || '').replace(/\s+/g, ' ').trim().toLowerCase(); }
  function shown(e) {
    if (!e.getClientRects().length) return false;
    var s = getComputedStyle(e), r = e.getBoundingClientRect();
    return s.visibility !== 'hidden' && s.visibility !== 'collapse' && r.width > 1 && r.height > 1;
  }
  var want = c(a.value);
  if (!want) return { found: false, seen: [] };
  var owned = [], ids = [], i, j;
  var withIds = [el].concat(Array.prototype.slice.call(el.querySelectorAll('[aria-controls],[aria-owns]')));
  for (i = 0; i < withIds.length; i++) {
    var v = String(withIds[i].getAttribute('aria-controls') || '') + ' ' + String(withIds[i].getAttribute('aria-owns') || '');
    ids = ids.concat(v.split(/\s+/).filter(Boolean));
  }
  for (i = 0; i < ids.length; i++) { var o = doc.getElementById(ids[i]); if (o) owned.push(o); }
  var near = [], p = el.parentElement;
  for (i = 0; i < 4 && p && p !== doc.body; i++, p = p.parentElement) near.push(p);
  var OPTION_ROLE = /^(option|menuitem|menuitemradio|menuitemcheckbox|radio|treeitem)$/;
  function tierOf(e) {
    for (var k = 0; k < owned.length; k++) if (owned[k].contains(e)) return 0;
    if (el.contains(e)) return 1;
    if (OPTION_ROLE.test(String(e.getAttribute('role') || '').toLowerCase())) return 2;
    for (k = 0; k < near.length; k++) if (near[k].contains(e)) return 3;
    return 4;
  }
  var all = doc.querySelectorAll('[role=option],[role=menuitem],[role=menuitemradio],[role=menuitemcheckbox],[role=radio],' +
    '[role=treeitem],[role=button],[role=link],li,a,button,label,td,dd,div,span,p');
  var exact = [], loose = [], seen = [], seenSet = {};
  for (i = 0; i < all.length; i++) {
    var e = all[i];
    if (e === el || e.contains(el)) continue;
    var t = c(e.textContent), al = c(e.getAttribute('aria-label'));
    var isOpt = OPTION_ROLE.test(String(e.getAttribute('role') || '').toLowerCase()) || e.tagName === 'LI';
    if (isOpt && t && t.length <= 80 && seen.length < 40 && !seenSet[t] && (tierOf(e) < 4 || shown(e))) { seenSet[t] = 1; seen.push(String(e.textContent).replace(/\s+/g, ' ').trim()); }
    if (t === want || al === want) exact.push(e);
    else if (t.length <= want.length + 40 && t.indexOf(want) === 0) loose.push(e);
  }
  var pool = exact.length ? exact : loose;
  // The outermost of nested elements with the same words.
  pool = pool.filter(function (e) {
    for (var q = e.parentElement; q; q = q.parentElement) if (pool.indexOf(q) >= 0) return false;
    return true;
  });
  var best = null, bestKey = null;
  for (i = 0; i < pool.length; i++) {
    var tier = tierOf(pool[i]);
    if (tier === 4 && !a.anywhere) continue;
    var vis = shown(pool[i]);
    var key = [tier, vis ? 0 : 1, i];
    if (!best || key[0] < bestKey[0] || (key[0] === bestKey[0] && (key[1] < bestKey[1] || (key[1] === bestKey[1] && key[2] < bestKey[2])))) { best = pool[i]; bestKey = key; }
  }
  // Same tier and shown, two of them: not "the" option.
  var twins = 0;
  if (best) for (j = 0; j < pool.length; j++) if (pool[j] !== best && tierOf(pool[j]) === bestKey[0] && shown(pool[j]) === (bestKey[1] === 0)) twins++;
  var prev = doc.querySelectorAll('[data-5dive-opt]');
  for (j = 0; j < prev.length; j++) prev[j].removeAttribute('data-5dive-opt');
  if (!best) return { found: false, seen: seen.slice(0, a.max || 15) };
  best.setAttribute('data-5dive-opt', a.id);
  return { found: true, shown: bestKey[1] === 0, tier: bestKey[0], loose: !exact.length, twins: twins,
    text: String(best.textContent).replace(/\s+/g, ' ').trim().slice(0, 80), seen: seen.slice(0, a.max || 15) };
}

// What a control reads now: its value or its words, and whether an option says it is chosen.
function _readsIn(el) {
  function c(x) { return String(x || '').replace(/\s+/g, ' ').trim(); }
  var v = (el.tagName === 'INPUT' || el.tagName === 'SELECT') ? el.value : '';
  var t = c(el.innerText !== undefined ? el.innerText : el.textContent);
  var chosen = el.getAttribute('aria-selected') === 'true' || el.getAttribute('aria-checked') === 'true' ||
    el.getAttribute('aria-current') === 'true' || !!(el.querySelector && el.querySelector('input:checked,[aria-selected=true],[aria-checked=true]'));
  return { attached: el.isConnected, value: c(v), text: t.slice(0, 120), chosen: chosen };
}

// Open a list through the page: the events a person's press sends, in order.
function _pressIn(el) {
  try { el.focus(); } catch (e) { /* not focusable */ }
  var r = el.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2;
  var o = { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y, button: 0 };
  var P = typeof PointerEvent === 'function' ? PointerEvent : MouseEvent;
  el.dispatchEvent(new P('pointerdown', o)); el.dispatchEvent(new MouseEvent('mousedown', o));
  el.dispatchEvent(new P('pointerup', o)); el.dispatchEvent(new MouseEvent('mouseup', o));
  el.click();
  return true;
}

// THE SLIDER: marks it (the element, or the one slider inside it) with
// data-5dive-ctl=<a.id> and reads it. The track is the first parent at least
// three thumbs long, which is what a drag is measured along.
function _sliderIn(el, a) {
  var s = el;
  var role = String(el.getAttribute('role') || '').toLowerCase();
  var isRange = el.tagName === 'INPUT' && String(el.type).toLowerCase() === 'range';
  if (!isRange && role !== 'slider') {
    var q = el.querySelectorAll('input[type=range],[role=slider]');
    if (q.length !== 1) return { ok: false, why: q.length ? 'it holds ' + q.length + ' sliders; name one of them' : 'it is not a slider' };
    s = q[0];
    isRange = s.tagName === 'INPUT';
  }
  if (a.id) s.setAttribute('data-5dive-ctl', a.id);
  function num(x) { var n = parseFloat(x); return isFinite(n) ? n : null; }
  var now, min, max, step, text = '';
  if (isRange) {
    now = num(s.value); min = num(s.min); max = num(s.max);
    if (min === null) min = 0; if (max === null) max = 100;
    step = String(s.step).toLowerCase() === 'any' ? 0 : (num(s.step) || 1);
  } else {
    now = num(s.getAttribute('aria-valuenow')); min = num(s.getAttribute('aria-valuemin')); max = num(s.getAttribute('aria-valuemax'));
    text = String(s.getAttribute('aria-valuetext') || '').replace(/\s+/g, ' ').trim();
    step = null;
  }
  var vertical = String(s.getAttribute('aria-orientation') || '').toLowerCase() === 'vertical';
  var r = s.getBoundingClientRect(), track = null;
  if (isRange) track = { dx: 0, dy: 0, w: r.width, h: r.height, thumbOwn: true };
  else {
    for (var p = s.parentElement, k = 0; p && k < 6; p = p.parentElement, k++) {
      var pr = p.getBoundingClientRect();
      if (vertical ? pr.height >= Math.max(3 * r.height, 24) : pr.width >= Math.max(3 * r.width, 24)) {
        track = { dx: pr.left - r.left, dy: pr.top - r.top, w: pr.width, h: pr.height, thumbOwn: false };
        break;
      }
    }
  }
  return { ok: true, range: isRange, now: now, min: min, max: max, step: step, text: text, vertical: vertical,
    focused: s.ownerDocument.activeElement === s, track: track,
    name: String(s.getAttribute('aria-label') || s.getAttribute('name') || '').replace(/\s+/g, ' ').trim() };
}

// An <input type=range> set the way a framework hears it: the prototype's setter
// (React keeps its own copy of .value), then input and change.
function _setRangeIn(el, a) {
  var d = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
  if (d && d.set) d.set.call(el, String(a.v)); else el.value = String(a.v);
  el.dispatchEvent(new Event('input', { bubbles: true }));
  el.dispatchEvent(new Event('change', { bubbles: true }));
  return parseFloat(el.value);
}

// THE PAGE'S OWN CLICK on an option: on the innermost element with the option's
// words, so it bubbles through every element a site may listen on (4shared's
// handler is on the <a> inside the <li>; a click on the <li> never reaches it).
function _clickOptionIn(el) {
  function c(x) { return String(x || '').replace(/\s+/g, ' ').trim().toLowerCase(); }
  var want = c(el.textContent), t = el, moved = true;
  while (moved) {
    moved = false;
    for (var i = 0; i < t.children.length; i++) {
      if (c(t.children[i].textContent) === want) { t = t.children[i]; moved = true; break; }
    }
  }
  try { t.scrollIntoView({ block: 'center' }); } catch (e) { /* drawn where it is */ }
  t.click();
  return t.tagName.toLowerCase();
}

function _focusIn(el) { try { el.focus(); } catch (e) { /* the page decides */ } return el.ownerDocument.activeElement === el; }

// ---- node side --------------------------------------------------------------

const NOT_FILLABLE = /not an <input>, <textarea>|cannot be filled|Input of type "range"/i;

// `fill`: page.fill, exactly as before, unless page.fill says this is no text
// field; then a slider is moved. Anything else is page.fill's own error.
async function fillStep(page, step, x, timeout, { log = null, guard = false } = {}) {
  try { return await page.fill(x, step.value, { timeout }); }
  catch (e) {
    if (!NOT_FILLABLE.test(String(e && e.message))) throw e;
    let k = null;
    try { k = await page.locator(x).evaluate(_kindIn, null, { timeout: KIND_MS }); } catch (x2) { throw e; }
    if (!k || k.kind === 'other') throw e;
    if (k.kind === 'select') return selectStep(page, step, x, timeout, { log, guard });
    return sliderStep(page, step, x, timeout, { log, kind: k });
  }
}

// `select`: see the header.
async function selectStep(page, step, x, timeout, { log = null, guard = false } = {}) {
  let k = null;
  try { k = await page.locator(x).evaluate(_kindIn, null, { timeout: Math.min(KIND_MS, timeout) }); } catch (e) { k = null; }
  // Not read (a selector matching two elements, a page with no locator): the old step.
  if (!k) return page.selectOption(x, step.value, { timeout });
  if (k.kind === 'slider' || k.kind === 'sliders') return sliderStep(page, step, x, timeout, { log, kind: k });
  if (k.kind === 'select') {
    const exact = (k.options || []).some((o) => o.v === step.value || o.t === clean(step.value));
    if (exact && k.shown) {
      return k.self ? page.selectOption(x, step.value, { timeout })
        : page.selectOption(`${x} >> select`, step.value, { timeout });
    }
    const r = await page.locator(x).evaluate(_setSelectIn, { value: String(step.value) }, { timeout: KIND_MS });
    if (!r.ok) {
      // A hidden <select> may be only the form's copy of a widget the page draws:
      // its options are the widget's too, so the widget is tried with the same words.
      if (!k.shown) return pickOption(page, step, x, timeout, { log, guard });
      throw new Error(`select ${step.selector}: ${r.why}.${r.seen && r.seen.length ? ` Its options: ${r.seen.map((s) => `"${s}"`).join(', ')}.` : ''}`);
    }
    say(log, `step ${step.selector}: ${k.shown ? '' : 'the list is a hidden <select> behind the page\'s own control; '}` +
      `set to "${r.text}"${r.how === 'loose' ? ` (the one option with the words "${clean(step.value)}")` : ''} and the page told`);
    return;
  }
  return pickOption(page, step, x, timeout, { log, guard });
}

async function findOption(page, x, value, id, anywhere) {
  return page.locator(x).evaluate(_optionIn, { value: String(value), id, anywhere, max: OPTIONS_SAID }, { timeout: KIND_MS });
}

// A list that is not a <select>: find the option, open the list if it is not
// shown, click the option, read what the control says now.
async function pickOption(page, step, x, timeout, { log = null, guard = false } = {}) {
  const deadline = Date.now() + Math.max(0, timeout);
  const left = () => Math.max(1, deadline - Date.now());
  const id = newId('o');
  const optSel = marked(x, 'data-5dive-opt', id);
  let before = null;
  try { before = await page.locator(x).evaluate(_readsIn, null, { timeout: KIND_MS }); } catch (e) { /* read after only */ }
  let f = await findOption(page, x, step.value, id, false);
  let opened = '';
  if (!(f.found && f.shown)) {
    // OPEN IT: a person's click, and when something sits on the control or it is
    // drawn too small to click, the same press through the page.
    try { await page.click(x, { timeout: Math.min(OPEN_CLICK_MS, left()) }); opened = 'opened it'; }
    catch (e) {
      try { await page.locator(x).evaluate(_pressIn, null, { timeout: KIND_MS }); opened = 'opened it through the page (a click would not reach it)'; }
      catch (e2) { throw e; }
    }
    const until = Date.now() + Math.min(OPEN_WAIT_MS, left());
    for (;;) {
      f = await findOption(page, x, step.value, id, true);
      if ((f.found && f.shown) || Date.now() >= until) break;
      await sleep(page, POLL_MS);
    }
    // A menu that opens on hover.
    if (!(f.found && f.shown) && f.found) {
      try { await page.hover(x, { timeout: Math.min(1000, left()) }); } catch (e) { /* not hoverable */ }
      f = await findOption(page, x, step.value, id, true);
    }
  }
  if (!f.found) {
    const seen = (f.seen || []).filter(Boolean);
    throw new Error(`select ${step.selector}: ${opened ? `${opened}, and ` : ''}no option in its list says "${clean(step.value)}".` +
      (seen.length ? ` The options it shows: ${seen.map((s) => `"${cut(s, 60)}"`).join(', ')}.` : ' It showed no options; it may not be a list. Open it with a click, then snapshot.'));
  }
  // THE OWNER'S FOUR (DIVE-4943): the click on an option is a click, and stepRisk
  // reads click steps only. An option whose words are a payment, a send, a delete
  // or a publish is not clicked from a `select`: a `click` on it asks the owner.
  const risk = guard ? classifyLabel(f.text) : null;
  if (risk) {
    throw new Error(`select ${step.selector}: the option "${cut(f.text, 60)}" reads as a ${risk} step, which the owner approves; ` +
      'pick it with a click step on its ref instead, so the owner is asked');
  }
  // CLICK THE OPTION. Playwright scrolls it into view (a long list) and clicks
  // like a person; when an element sits on it (a styled checkbox's <li> over its
  // <input>, a panel's mask) or it is not shown, the page's own click.
  let how = '';
  if (f.shown) {
    try { await page.click(optSel, { timeout: Math.min(OPTION_CLICK_MS, left()) }); }
    catch (e) {
      if (!/intercepts pointer events|not visible|outside of the viewport|not stable|Timeout/i.test(String(e && e.message))) throw e;
      await page.locator(optSel).evaluate(_clickOptionIn, null, { timeout: KIND_MS });
      how = ' through the page (something sat on it)';
    }
  } else {
    await page.locator(optSel).evaluate(_clickOptionIn, null, { timeout: KIND_MS });
    how = ' through the page (its list never showed it)';
  }
  await sleep(page, AFTER_PICK_MS);
  // WHAT IT READS NOW: the control, else (redrawn) the option.
  let now = null;
  try { now = await page.locator(x).evaluate(_readsIn, null, { timeout: 500 }); } catch (e) { now = null; }
  let opt = null;
  try { opt = await page.locator(optSel).evaluate(_readsIn, null, { timeout: 300 }); } catch (e) { opt = null; }
  const want = clean(step.value).toLowerCase();
  const reads = now ? (now.value || now.text) : '';
  const took = (now && (clean(now.value).toLowerCase().includes(want) || clean(now.text).toLowerCase().includes(want))) || (opt && opt.chosen);
  const changed = before && now && (before.text !== now.text || before.value !== now.value);
  const pick = `picked "${cut(f.text, 60)}"${f.loose ? ` (the option starting "${clean(step.value)}")` : ''}${opened ? ` (${opened})` : ''}${how}`;
  if (took) say(log, `step ${step.selector}: ${pick}; it now reads "${cut(reads || f.text, 80)}"`);
  else if (!now) say(log, `step ${step.selector}: ${pick}; the control was redrawn, so check the filter shows "${clean(step.value)}"`);
  else say(log, `step ${step.selector}: ${pick}, but it ${changed ? 'now reads' : 'still reads'} "${cut(reads, 80)}": check the filter took before you answer`);
}

// THE SLIDER. Read, move, read: every answer is the slider's own value.
async function sliderStep(page, step, x, timeout, { log = null, kind = null } = {}) {
  const deadline = Date.now() + Math.max(0, timeout);
  if (kind && kind.kind === 'sliders') {
    throw new Error(`${step.op} ${step.selector}: it holds ${kind.names.length} sliders (${kind.names.map((n) => `"${n}"`).join(', ')}); name the one to move with its own ref`);
  }
  const want0 = toNumber(step.value);
  if (want0 === null) throw new Error(`${step.op} ${step.selector}: a slider takes a number, and "${step.value}" is not one`);
  const id = newId('s');
  let s = await page.locator(x).evaluate(_sliderIn, { id }, { timeout: KIND_MS });
  if (!s.ok) throw new Error(`${step.op} ${step.selector}: ${s.why}`);
  const sl = page.locator(marked(x, 'data-5dive-ctl', id));
  const read = async () => { await sleep(page, SLIDER_READ_MS); return sl.evaluate(_sliderIn, {}, { timeout: KIND_MS }); };
  if (s.now === null) throw new Error(`${step.op} ${step.selector}: the slider does not say its value (no aria-valuenow), so it cannot be set and checked; use its number box or the page's own link`);
  let want = want0;
  if (s.min !== null && want < s.min) want = s.min;
  if (s.max !== null && want > s.max) want = s.max;
  const span = (s.min !== null && s.max !== null) ? s.max - s.min : 0;
  let unit = s.step || 0;   // learned from the first key on an ARIA slider
  const close = (v) => v !== null && Math.abs(v - want) <= Math.max(unit ? unit / 2 : 0, span / 1000, 1e-9);
  const said = (st) => `${st.text ? `"${st.text}" (${st.now})` : st.now}`;
  const clamped = want !== want0 ? ` (${want0} is past its end; ${want} is as far as it goes)` : '';
  const done = (how) => say(log, `step ${step.selector}: the slider now reads ${said(s)}${how}${clamped}`);
  if (close(s.now)) { say(log, `step ${step.selector}: the slider already reads ${said(s)}${clamped}`); return; }
  // 1. An <input type=range>: set the way a framework hears it.
  if (s.range) {
    try { await sl.evaluate(_setRangeIn, { v: want }, { timeout: KIND_MS }); s = await read(); } catch (e) { /* keys next */ }
    if (close(s.now)) return done('');
  }
  // 2. KEYS, from the focused slider. The first key measures the step; the rest are counted.
  let keysMove = false;
  const press = async (key) => { await page.keyboard.press(key); };
  const focus = async () => {
    let f = false;
    try { f = await sl.evaluate(_focusIn, null, { timeout: KIND_MS }); } catch (e) { f = false; }
    if (!f) { try { await sl.click({ timeout: 1000 }); s = await read(); } catch (e) { /* drag next */ } }
  };
  let sent = 0;
  const keys = async () => {
    await focus();
    if (close(s.now)) return;
    if (s.min !== null && Math.abs(want - s.min) < 1e-9) { await press('Home'); sent++; s = await read(); if (close(s.now)) { keysMove = true; return; } }
    if (s.max !== null && Math.abs(want - s.max) < 1e-9) { await press('End'); sent++; s = await read(); if (close(s.now)) { keysMove = true; return; } }
    let was = s.now;
    let up = want > s.now;
    await press(up ? 'ArrowRight' : 'ArrowLeft'); sent++;
    s = await read();
    if (s.now === was) { await press(up ? 'ArrowUp' : 'ArrowDown'); sent++; s = await read(); }
    if (s.now === null || s.now === was) return;
    keysMove = true;
    if (!unit) unit = Math.abs(s.now - was);
    const n = Math.min(PRESS_MAX - sent, Math.max(0, Math.round(Math.abs(want - s.now) / Math.abs(s.now - was))));
    up = want > s.now;
    for (let i = 0; i < n && Date.now() < deadline; i++) { await press(up ? 'ArrowRight' : 'ArrowLeft'); sent++; }
    s = await read();
    // The last few by one, toward it, never past the nearest it can stop at.
    for (let i = 0; i < 8 && !close(s.now) && sent < PRESS_MAX && Date.now() < deadline; i++) {
      was = s.now;
      const k = want > s.now ? 'ArrowRight' : 'ArrowLeft';
      await press(k); sent++;
      s = await read();
      if (s.now === null || Math.abs(s.now - want) >= Math.abs(was - want)) {
        await press(k === 'ArrowRight' ? 'ArrowLeft' : 'ArrowRight'); sent++;
        s = await read();
        break;
      }
    }
  };
  await keys();
  if (close(s.now)) return done(` (${sent} key${sent === 1 ? '' : 's'})`);
  // 3. A DRAG of the thumb along its track, for a slider keys do not move.
  let dragged = false;
  if (s.track && span > 0 && Date.now() < deadline) {
    try {
      await sl.scrollIntoViewIfNeeded({ timeout: 1000 });
      s = await read();
      const b = await sl.boundingBox();
      if (b && s.track) {
        const frac = Math.max(0, Math.min(1, (want - s.min) / span));
        const tx0 = b.x + s.track.dx, ty0 = b.y + s.track.dy;
        const toX = s.vertical ? b.x + b.width / 2 : tx0 + frac * s.track.w;
        const toY = s.vertical ? ty0 + (1 - frac) * s.track.h : b.y + b.height / 2;
        const fromX = s.track.thumbOwn ? tx0 + ((s.now - s.min) / span) * s.track.w : b.x + b.width / 2;
        await page.mouse.move(fromX, b.y + b.height / 2);
        await page.mouse.down();
        await page.mouse.move(toX, toY, { steps: 12 });
        await page.mouse.up();
        dragged = true;
        s = await read();
        if (!close(s.now) && keysMove) await keys();
        else if (!close(s.now) && s.now !== null) {
          // One correction, scaled by how far the drag landed.
          const b2 = await sl.boundingBox();
          if (b2) {
            const off = (want - s.now) / span * (s.vertical ? -s.track.h : s.track.w);
            await page.mouse.move(b2.x + b2.width / 2, b2.y + b2.height / 2);
            await page.mouse.down();
            await page.mouse.move(b2.x + b2.width / 2 + (s.vertical ? 0 : off), b2.y + b2.height / 2 + (s.vertical ? off : 0), { steps: 6 });
            await page.mouse.up();
            s = await read();
          }
        }
      }
    } catch (e) { /* the read below says where it is */ }
  }
  if (close(s.now)) return done(dragged ? ' (dragged; keys did not move it)' : '');
  // Within one step of it is as near as it stops: said, not failed.
  if (unit && s.now !== null && Math.abs(s.now - want) <= unit) return done(` (it moves in steps of ${unit}; this is the nearest to ${want})`);
  throw new Error(`${step.op} ${step.selector}: the slider would not move to ${want}; it reads ${said(s)}` +
    `${s.min !== null && s.max !== null ? ` (from ${s.min} to ${s.max})` : ''}. ${sent ? `Keys ${keysMove ? 'moved it only part way' : 'did not move it'}` : 'No key reached it'}` +
    `${dragged ? ', nor did a drag' : ''}. Try its number box or the filter's own link; if none takes, say the filter could not be set.`);
}

module.exports = { fillStep, selectStep, sliderStep, pickOption, toNumber, framePrefix, NOT_FILLABLE,
  _kindIn, _setSelectIn, _optionIn, _readsIn, _pressIn, _clickOptionIn, _sliderIn, _setRangeIn, _focusIn };
