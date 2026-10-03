#!/usr/bin/env node
// DIVE-5433 — the keyboard map of a display, for the input-mode harness.
//
//   node tests/x11_keys.cjs spare                 keys a character can be typed on
//   node tests/x11_keys.cjs bound                 characters bound to a key of their own
//   node tests/x11_keys.cjs type <from> <count>   type <count> distinct characters
//                                                 from code point <from> on; prints rc
//
// Reads the map with GetKeyboardMapping directly, not through lib/x11.cjs's own
// bookkeeping, so the arms it feeds grade any version of the library. "spare" is
// a key above the first 8 with nothing on it, or with one Unicode keysym and
// nothing else (a character an earlier connection bound). DISPLAY names the
// display.
'use strict';
const path = require('path');
const x11 = require(path.join(__dirname, '..', 'browser', 'lib', 'x11.cjs'));
const isUni = (ks) => ks >= 0x01000100 && ks <= 0x0110ffff;

async function rows(x) {
  const { minKeycode: min, maxKeycode: max } = x.setup;
  const b = Buffer.alloc(4); b[0] = min; b[1] = max - min + 1;
  const r = await x.req(101, 0, b, true), per = r[1], out = [];     // GetKeyboardMapping
  for (let kc = min; kc <= max; kc++) {
    const on = new Set();
    for (let l = 0; l < per; l++) { const ks = r.readUInt32LE(32 + ((kc - min) * per + l) * 4); if (ks) on.add(ks); }
    out.push({ kc, on: [...on], high: kc > min + 8 });
  }
  return out;
}

(async () => {
  const [cmd, from, count] = process.argv.slice(2);
  const x = await x11.open(process.env.DISPLAY);
  if (cmd === 'spare') {
    console.log((await rows(x)).filter(k => k.high && (!k.on.length || (k.on.length === 1 && isUni(k.on[0])))).length);
  } else if (cmd === 'bound') {
    console.log((await rows(x)).filter(k => k.on.length === 1 && isUni(k.on[0]))
      .map(k => k.on[0] - 0x01000000).sort((a, b) => a - b).map(c => c.toString(16)).join(','));
  } else if (cmd === 'type') {
    const text = Array.from({ length: Number(count) }, (_, i) => String.fromCodePoint(Number(from) + i)).join('');
    try { await x.type(text, 0); console.log(0); } catch (e) { console.log(1); console.error(e.message); }
  } else { console.error('usage: x11_keys.cjs spare | bound | type <from> <count>'); process.exit(64); }
  process.exit(0);
})().catch((e) => { console.error(e.message); process.exit(1); });
