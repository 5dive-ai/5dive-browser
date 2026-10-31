#!/usr/bin/env bash
# DIVE-7223 — typing on a phone into the self-hosted login viewer.
#
# A headless browser cannot raise a soft keyboard, so this proves the handler:
# the same keystroke sequences a phone's keyboard produces are fed to the page's
# bar (browser/lib/login-link/viewer-ui.js) through a small DOM fake, and what
# reaches the box is read off a fake noVNC that models the focused field on the
# box (keysyms typed, Ctrl+V pasting the box clipboard, Backspace).
#
#   K  the new bar: Type shows and focuses a VISIBLE field, the phone's keyboard
#      edits it, Send delivers exactly what was typed (Gboard composition,
#      "Unidentified" 229 keys, Backspace, non-Latin text, a desktop keyboard)
#   C  CONTROL: the DIVE-6219 handler it replaces (a hidden input that forwards
#      each `input` and clears itself), copied verbatim, on the same sequences —
#      each phone sequence must come out WRONG there, or this harness proves nothing
#   L  the bar's language, and nothing is sent before connect or after disconnect
#   Z  a phone does not stay zoomed in (DIVE-7379): the field's text is 16px (a
#      phone zooms in on a focused field with smaller text), the page may still
#      zoom, and Send or the keyboard closing takes the page back to its scale
# Pure node, no browser.
set -uo pipefail
cd "$(dirname "$0")/.."
command -v node >/dev/null || { echo "SKIP: needs node"; exit 1; }
TMP=$(mktemp -d)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cp browser/lib/login-link/viewer-ui.js "$TMP/viewer-ui.mjs"

cat >"$TMP/t.mjs" <<'JS'
import { wireBar, pickText, TEXT, unzoom, UNZOOM_MS } from './viewer-ui.mjs';
import { readFileSync } from 'node:fs';

let PASS = 0, FAIL = 0;
const t = (name, want, got) => {
  if (JSON.stringify(want) === JSON.stringify(got)) PASS++;
  else { FAIL++; console.log(`FAIL: ${name}\n   expected: ${JSON.stringify(want)}\n   got:      ${JSON.stringify(got)}`); }
};
const tn = (name, bad, got) => {
  if (JSON.stringify(bad) !== JSON.stringify(got)) PASS++;
  else { FAIL++; console.log(`FAIL: ${name}\n   expected NOT: ${JSON.stringify(bad)}`); }
};

// ---- a DOM just big enough for the bar ----
class El extends EventTarget {
  constructor(doc, id) { super(); this.doc = doc; this.id = id; this.hidden = false; this.disabled = false;
    this.value = ''; this.textContent = ''; this.placeholder = ''; this.title = ''; this.children = []; }
  focus() { this.doc.activeElement = this; this.doc.focusLog.push({ id: this.id, visible: this.doc.visible(this) }); }
  querySelector(sel) { return this.children.find((c) => c.tag === sel) || null; }
  click() { this.dispatchEvent(new Event('click')); }
}
function makeDoc(ids) {
  const doc = { els: {}, activeElement: null, focusLog: [], parent: {} };
  doc.getElementById = (id) => doc.els[id] || null;
  doc.visible = (el) => { for (let e = el; e; e = doc.parent[e.id]) if (e.hidden) return false; return true; };
  for (const id of ids) doc.els[id] = new El(doc, id);
  return doc;
}
function barDoc() {
  const doc = makeDoc(['note', 'type', 'paste', 'pastebox', 'pastein', 'send']);
  const box = doc.els.pastebox, field = doc.els.pastein, send = doc.els.send;
  send.tag = 'button'; box.children = [send]; box.hidden = true;
  doc.parent = { pastein: box, send: box };
  field.form = box;
  doc.els.type.disabled = doc.els.paste.disabled = true;
  return doc;
}

// ---- the box's focused field, as the keys noVNC sends would change it ----
function fakeRfb() {
  const box = { text: '', clip: '', ctrl: false, keys: [], focused: 0 };
  return {
    box,
    clipboardPasteFrom(s) { box.clip = s; },
    focus() { box.focused++; },
    sendKey(sym, code, down) {
      box.keys.push(sym);
      if (sym === 0xffe3) { if (down !== undefined) box.ctrl = down; return; }
      if (down === false) return;
      if (box.ctrl && sym === 0x76) { box.text += box.clip; return; }
      if (sym === 0xff08) { box.text = [...box.text].slice(0, -1).join(''); return; }
      if (sym === 0xff0d) { box.text += '\n'; return; }
      if (sym === 0xff09) { box.text += '\t'; return; }
      box.text += String.fromCodePoint(sym >= 0x01000000 ? sym - 0x01000000 : sym);
    },
  };
}
// noVNC's keysymdef.lookup, for the control: Latin-1 is itself, the rest Unicode.
const keysyms = { lookup: (cp) => (cp < 0x100 ? cp : 0x01000000 + cp) };

// ---- the keyboards ----
const ev = (type, props = {}) => Object.assign(new Event(type, { cancelable: true }), props);
const fire = (el, e) => { el.dispatchEvent(e); return e; };
// Gboard on Android Chrome: every key is keydown "Unidentified" (229); a word is
// a composition the IME rewrites whole on each key from ITS OWN buffer (the text
// before the word, as it was when the word began). Clearing the field under it
// does not clear that buffer, which is how the old handler doubled words.
function gboard(el, steps) {
  for (const s of steps) {
    if (s.word !== undefined) {
      const before = el.value;
      fire(el, ev('compositionstart', { data: '' }));
      for (let i = 1; i <= [...s.word].length; i++) {
        const comp = [...s.word].slice(0, i).join('');
        fire(el, ev('keydown', { key: 'Unidentified', keyCode: 229, isComposing: true }));
        fire(el, ev('beforeinput', { inputType: 'insertCompositionText', data: comp, isComposing: true }));
        el.value = before + comp;
        fire(el, ev('input', { inputType: 'insertCompositionText', data: comp, isComposing: true }));
      }
      fire(el, ev('compositionend', { data: s.word }));
    } else if (s.text !== undefined) {           // a space, a symbol: committed at once
      fire(el, ev('keydown', { key: 'Unidentified', keyCode: 229 }));
      fire(el, ev('beforeinput', { inputType: 'insertText', data: s.text }));
      el.value += s.text;
      fire(el, ev('input', { inputType: 'insertText', data: s.text }));
    } else if (s.back) {
      fire(el, ev('keydown', { key: 'Unidentified', keyCode: 229 }));
      fire(el, ev('beforeinput', { inputType: 'deleteContentBackward' }));
      el.value = [...el.value].slice(0, -1).join('');
      fire(el, ev('input', { inputType: 'deleteContentBackward' }));
    }
  }
}
// A desktop keyboard: real keys, one committed character each.
function desk(el, text) {
  for (const ch of text) {
    const kd = fire(el, ev('keydown', { key: ch, keyCode: ch.toUpperCase().charCodeAt(0) }));
    if (kd.defaultPrevented) continue;
    el.value += ch;
    fire(el, ev('input', { inputType: 'insertText', data: ch }));
  }
}

// ---- the two subjects: open the keyboard, type, finish ----
async function viaBar(type, text) {
  const doc = barDoc(), rfb = fakeRfb();
  const bar = wireBar(doc, rfb, TEXT.en, { readText: async () => { throw new Error('denied'); } });
  bar.connect();
  doc.els.type.click();
  const field = doc.els.pastein;
  type(field, text);
  fire(doc.els.pastebox, ev('submit'));   // Send (or Enter in the field)
  return { rfb, doc, field };
}
function viaOld(type, text) {
  // VERBATIM from browser/lib/login-link/page.js before DIVE-7223 (1.63.1).
  const doc = makeDoc(['kbd', 'kin']), rfb = fakeRfb();
  const kbd = doc.getElementById('kbd'), kin = doc.getElementById('kin');
  kbd.style = {};
  kbd.style.display = 'block';
  kbd.addEventListener('click', () => kin.focus());
  const key = (sym) => rfb.sendKey(sym);
  kin.addEventListener('keydown', (e) => {
    const special = { Backspace: 0xff08, Enter: 0xff0d, Tab: 0xff09, Escape: 0xff1b };
    if (special[e.key]) { e.preventDefault(); key(special[e.key]); }
  });
  kin.addEventListener('input', () => {
    for (const ch of kin.value) key(keysyms.lookup(ch.codePointAt(0)));
    kin.value = '';
  });
  kbd.click();
  type(kin, text);
  return { rfb, doc };
}

const PHONE = [
  ['K1 a word and a space and a word (Gboard composition)', [{ word: 'hello' }, { text: ' ' }, { word: 'world' }], 'hello world'],
  ['K2 a typo fixed with Backspace (Gboard sends it as Unidentified)', [{ word: 'helx' }, { back: true }, { word: 'lo' }], 'hello'],
  ['K3 an email address', [{ word: 'owner' }, { text: '@' }, { word: 'example' }, { text: '.' }, { word: 'com' }], 'owner@example.com'],
  ['K4 Cyrillic (typed as Unicode keysyms, not pasted)', [{ word: 'пароль' }], 'пароль'],
];

for (const [name, steps, want] of PHONE) {
  const { rfb, doc } = await viaBar(gboard, steps);
  t(name + ': the box gets exactly what was typed', want, rfb.box.text);
  t(name + ': ... once (one Send, one delivery)', 1, rfb.box.focused);
  const old = viaOld(gboard, steps);
  tn('C' + name.slice(1) + ': CONTROL — the old hidden-input handler gets it wrong', want, old.rfb.box.text);
}
{
  const old = viaOld(gboard, [{ word: 'hello' }]);
  t('C1 ... (the old handler doubled the composing word)', 'hhehelhellhello', old.rfb.box.text);
}

// K5: what Send uses for Latin-1 vs the rest, and the clipboard is emptied after.
{
  const { rfb } = await viaBar(gboard, [{ word: 'secret' }]);
  t('K5 Latin-1 goes by the box clipboard and Ctrl+V', [0xffe3, 0x76, 0xffe3], rfb.box.keys);
  await new Promise((r) => setTimeout(r, 2100));
  t('K5 ... and the box clipboard is empty again after', '', rfb.box.clip);
  const ru = await viaBar(gboard, [{ word: 'да' }]);
  t('K5 non-Latin text is typed as Unicode keysyms', [0x01000434, 0x01000430], ru.rfb.box.keys);
}

// K6: Type puts the focus in a VISIBLE field in the tap's own handler (what lets a
// phone raise its keyboard); the old button focused a field off the page.
{
  const doc = barDoc(), rfb = fakeRfb();
  const bar = wireBar(doc, rfb, TEXT.en, { readText: async () => '' });
  bar.connect();
  doc.els.type.click();
  t('K6 Type focuses the field, visible, in the same tap', [{ id: 'pastein', visible: true }], doc.focusLog);
  t('K6 ... and the help line gives it the room', true, doc.els.note.hidden);
}

// K7: a desktop keyboard still works, on both (the control is not broken by design).
{
  const { rfb } = await viaBar(desk, 'abc');
  t('K7 a desktop keyboard: abc', 'abc', rfb.box.text);
  t('K7 ... the old handler managed that too (control sanity)', 'abc', viaOld(desk, 'abc').rfb.box.text);
}

// K8: Paste with a readable clipboard sends it at once; denied, it opens the field.
{
  const doc = barDoc(), rfb = fakeRfb();
  const bar = wireBar(doc, rfb, TEXT.en, { readText: async () => 'pa55word' });
  bar.connect();
  doc.els.paste.click();
  await new Promise((r) => setTimeout(r, 0));
  t('K8 Paste sends the clipboard', 'pa55word', rfb.box.text);
  const doc2 = barDoc(), rfb2 = fakeRfb();
  wireBar(doc2, rfb2, TEXT.en, { readText: async () => { throw new Error('denied'); } }).connect();
  doc2.els.paste.click();
  await new Promise((r) => setTimeout(r, 0));
  t('K8 ... a denied clipboard opens the field instead', [false, 'pastein'], [doc2.els.pastebox.hidden, doc2.activeElement?.id]);
}

// L: language, and the connection's edges.
{
  t('L1 a Russian browser gets the Russian bar', TEXT.ru, pickText(['ru-RU', 'en']));
  t('L1 ... an unknown language gets English', TEXT.en, pickText(['de-DE']));
  const doc = barDoc(), rfb = fakeRfb();
  const bar = wireBar(doc, rfb, TEXT.ru, { readText: async () => '' });
  t('L2 the bar is labelled in that language', ['Ввод', 'Вставить', 'Отправить'],
    [doc.els.type.textContent, doc.els.paste.textContent, doc.els.send.textContent]);
  t('L3 Type and Paste are off until the screen connects', [true, true], [doc.els.type.disabled, doc.els.paste.disabled]);
  doc.els.pastebox.hidden = false; doc.els.pastein.value = 'early';
  fire(doc.els.pastebox, ev('submit'));
  t('L3 ... and a Send before it sends nothing', [], rfb.box.keys);
  bar.connect(); bar.disconnect();
  t('L4 after the screen closes: buttons off, field hidden and emptied',
    [true, true, true, ''], [doc.els.type.disabled, doc.els.paste.disabled, doc.els.pastebox.hidden, doc.els.pastein.value]);
}

// Z: zoom (DIVE-7379). lodar's phone zoomed in on Type and could not get out.
{
  const html = readFileSync('browser/lib/login-link-server.py', 'utf8');
  // The field's font size as the cascade leaves it: `font:` resets the size (to
  // the body's 14px through inherit), a later `font-size:` wins over it.
  const body = /html,body\{[^}]*font:(\d+)px/.exec(html);
  const rule = /#pastein\{([^}]*)\}/.exec(html);
  let px = 0;
  for (const d of (rule ? rule[1] : '').split(';')) {
    const [k, v = ''] = d.split(':').map((x) => x.trim());
    if (k === 'font') px = v === 'inherit' ? +body[1] : parseFloat(v);
    if (k === 'font-size') px = v === 'inherit' ? +body[1] : parseFloat(v);
  }
  t('Z1 the Type field\'s text is at least 16px (no zoom on focus)', true, px >= 16);
  const vp = /<meta name="viewport" content="([^"]*)"/.exec(html);
  t('Z2 the page may still zoom (no user-scalable=no, no maximum-scale)', true,
    !!vp && !/user-scalable\s*=\s*(no|0)|maximum-scale/i.test(vp[1]));
}
function zoomDoc(scale) {
  const doc = barDoc();
  const meta = { content: 'width=device-width, initial-scale=1', log: [] };
  meta.getAttribute = () => meta.content;
  meta.setAttribute = (k, v) => { meta.content = v; meta.log.push(v); };
  doc.querySelector = (sel) => (sel === 'meta[name="viewport"]' ? meta : null);
  doc.documentElement = { style: { minHeight: '' } };
  const win = { visualViewport: { scale }, setTimeout: (f, ms) => setTimeout(f, ms) };
  return { doc, meta, win };
}
{
  const { doc, meta, win } = zoomDoc(3);
  t('Z3 zoomed in: unzoom caps the page at its own scale', true, unzoom(doc, win));
  t('Z3 ... with maximum-scale=1, and a layout for Chrome to take it at', ['width=device-width, initial-scale=1, maximum-scale=1', '100.01%'],
    [meta.content, doc.documentElement.style.minHeight]);
  await new Promise((r) => setTimeout(r, UNZOOM_MS + 50));
  t('Z3 ... then gives the old viewport back, so the owner can pinch again', ['width=device-width, initial-scale=1', ''],
    [meta.content, doc.documentElement.style.minHeight]);
  const one = zoomDoc(1);
  t('Z4 not zoomed: unzoom leaves the page alone', [false, []], [unzoom(one.doc, one.win), one.meta.log]);
}
{
  const { doc, meta, win } = zoomDoc(2.5);
  wireBar(doc, fakeRfb(), TEXT.en, { readText: async () => '' }, win).connect();
  doc.els.type.click();
  doc.els.pastein.value = 'owner@example.com';
  fire(doc.els.pastebox, ev('submit'));
  t('Z5 Send takes a zoomed page back to its scale', ['width=device-width, initial-scale=1, maximum-scale=1'], meta.log);
  const b = zoomDoc(2.5);
  wireBar(b.doc, fakeRfb(), TEXT.en, { readText: async () => '' }, b.win).connect();
  b.doc.els.type.click();
  fire(b.doc.els.pastein, ev('blur'));
  t('Z6 the keyboard closing without Send does too', ['width=device-width, initial-scale=1, maximum-scale=1'], b.meta.log);
  await new Promise((r) => setTimeout(r, UNZOOM_MS + 50));
  // Send with focus moving to the screen: submit AND blur, both before the page
  // has redrawn (found on 5dive-ci: the viewport stayed capped, no pinch again).
  const c = zoomDoc(2.5);
  const field = c.doc.els.pastein;
  const rfb = Object.assign(fakeRfb(), { focus() { fire(field, ev('blur')); } });
  wireBar(c.doc, rfb, TEXT.en, { readText: async () => '' }, c.win).connect();
  c.doc.els.type.click();
  field.value = 'owner@example.com';
  fire(c.doc.els.pastebox, ev('submit'));
  await new Promise((r) => setTimeout(r, UNZOOM_MS + 50));
  t('Z7 Send that also closes the keyboard gives the page its own viewport back', 'width=device-width, initial-scale=1', c.meta.content);
}

console.log(`\n${PASS} passed, ${FAIL} failed`);
process.exit(FAIL ? 1 : 0);
JS
node "$TMP/t.mjs"
