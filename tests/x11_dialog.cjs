#!/usr/bin/env node
// DIVE-5740 — the browser's file chooser, on a bare Xvfb, for the input-mode harness.
//
//   node tests/x11_dialog.cjs <scene>     prints one line: what the library did
//
// Builds what Chrome puts on the display when a page's upload control is clicked:
// a main window ("<page> - Google Chrome") and a small top-level "Open File"
// window of the same process, transient for it. Then the keyboard focus is put
// on the ROOT window, which is where chill-gorge found it (0x21f is Xvfb's root),
// and lib/x11.cjs is asked to make the keys reach the browser.
//
//   chooser   both windows up   -> "focus=dialog" is right: the path a person types
//                                  belongs in the chooser, not in the page behind it
//   closed    the chooser gone  -> "focus=main": with nothing open, keys go to the page
//   popup     an override-redirect "Open File"-named popup instead of a dialog
//                               -> "focus=main": menus and popups are not dialogs
//
// DISPLAY names the display.
'use strict';
const path = require('path');
const x11 = require(path.join(__dirname, '..', 'browser', 'lib', 'x11.cjs'));
const PID = 424242;

async function prop(x, win, name, type, fmt, data) {
  const n = data.length / (fmt / 8), pad = (4 - (data.length % 4)) % 4;
  const b = Buffer.alloc(20 + data.length + pad);
  b.writeUInt32LE(win, 0); b.writeUInt32LE(await x.atom(name), 4); b.writeUInt32LE(await x.atom(type), 8);
  b[12] = fmt; b.writeUInt32LE(n, 16); data.copy(b, 20);
  x.req(18, 0, b, false);                                         // ChangeProperty, Replace
}
const u32 = (v) => { const b = Buffer.alloc(4); b.writeUInt32LE(v, 0); return b; };

async function win(x, id, geo, name, opts) {
  const o = opts || {}, b = Buffer.alloc(36);
  b.writeUInt32LE(id, 0); b.writeUInt32LE(x.root, 4);
  b.writeInt16LE(geo[0], 8); b.writeInt16LE(geo[1], 10); b.writeUInt16LE(geo[2], 12); b.writeUInt16LE(geo[3], 14);
  b.writeUInt16LE(0, 16); b.writeUInt16LE(1, 18); b.writeUInt32LE(0, 20);
  b.writeUInt32LE(0x2 | 0x200, 24);                               // CWBackPixel | CWOverrideRedirect
  b.writeUInt32LE(0xdddddd, 28); b.writeUInt32LE(o.override ? 1 : 0, 32);
  x.req(1, 0, b, false);                                          // CreateWindow
  await prop(x, id, 'WM_NAME', 'STRING', 8, Buffer.from(name, 'latin1'));
  await prop(x, id, 'WM_CLASS', 'STRING', 8, Buffer.from('google-chrome\0Google-chrome\0', 'latin1'));
  await prop(x, id, '_NET_WM_PID', 'CARDINAL', 32, u32(PID));
  if (o.transientFor) await prop(x, id, 'WM_TRANSIENT_FOR', 'WINDOW', 32, u32(o.transientFor));
  x.req(8, 0, u32(id), false);                                    // MapWindow
  await x.sync();
  for (let i = 0; i < 50 && !(await x.viewable(id)); i++) await new Promise(r => setTimeout(r, 20));
}

(async () => {
  const scene = process.argv[2];
  const x = await x11.open(process.env.DISPLAY);
  const main = x.setup.ridBase | 0x100, dlg = x.setup.ridBase | 0x200;
  await win(x, main, [0, 0, 600, 400], 'Ad draft - Google Chrome');
  if (scene === 'chooser') await win(x, dlg, [100, 80, 300, 200], 'Open File', { transientFor: main });
  if (scene === 'popup') await win(x, dlg, [100, 80, 300, 200], 'Open File', { override: true });
  await x.setFocus(x.root);                                       // where chill-gorge found it
  let got;
  try {
    const w = await x.ensureBrowserFocus(PID, 1000);
    const r = await x.req(43, 0, null, true), f = r.readUInt32LE(8);   // GetInputFocus
    got = f === dlg ? 'focus=dialog' : f === main ? 'focus=main' : `focus=0x${f.toString(16)}`;
    if (w !== f && !(await x.lineage(f)).includes(w)) got += ' (returned another window)';
  } catch (e) { got = 'threw: ' + e.message; }
  process.stdout.write(got + '\n');
  x.close();
  process.exit(0);
})().catch(e => { console.error(e.message); process.exit(1); });
