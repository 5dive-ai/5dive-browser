#!/usr/bin/env node
// DIVE-6704 — a file dropped onto the browser, on a bare Xvfb, for the input-mode harness.
//
//   node tests/x11_drop.cjs <scene> <file>     prints one line: what the drop did
//
// A second X connection plays the browser the way Chrome does as a drop target:
// a top-level window with XdndAware 5, which on each XdndPosition fetches the
// dragged data (ConvertSelection of XdndSelection as text/uri-list), answers
// XdndStatus, and on XdndDrop answers XdndFinished. lib/x11.cjs is asked to
// drop <file> on it.
//
//   take        says no to the FIRST position (Chrome's page has not seen the
//               drag yet), yes after   -> "drop=ok uri=file:///... finished=true"
//   refuse      says no to every position -> "drop=refused left=yes": the drop
//               fails by name and the browser is told the drag went away
//   notbrowser  the same yes, from a window that is not the browser's
//                                     -> "drop=refused left=no": nothing is sent
//
// DISPLAY names the display.
'use strict';
const path = require('path');
const x11 = require(path.join(__dirname, '..', 'browser', 'lib', 'x11.cjs'));
const PID = 424242;
const u32 = (v) => { const b = Buffer.alloc(4); b.writeUInt32LE(v, 0); return b; };

async function prop(x, win, name, type, fmt, data) {
  const n = data.length / (fmt / 8), pad = (4 - (data.length % 4)) % 4;
  const b = Buffer.alloc(20 + data.length + pad);
  b.writeUInt32LE(win, 0); b.writeUInt32LE(await x.atom(name), 4); b.writeUInt32LE(await x.atom(type), 8);
  b[12] = fmt; b.writeUInt32LE(n, 16); data.copy(b, 20);
  x.req(18, 0, b, false);                                         // ChangeProperty, Replace
}

async function browserWindow(x, id, cls) {
  const b = Buffer.alloc(36);
  b.writeUInt32LE(id, 0); b.writeUInt32LE(x.root, 4);
  b.writeInt16LE(0, 8); b.writeInt16LE(0, 10); b.writeUInt16LE(600, 12); b.writeUInt16LE(400, 14);
  b.writeUInt16LE(0, 16); b.writeUInt16LE(1, 18); b.writeUInt32LE(0, 20);
  b.writeUInt32LE(0x2 | 0x200, 24);                               // CWBackPixel | CWOverrideRedirect
  b.writeUInt32LE(0xdddddd, 28); b.writeUInt32LE(0, 32);
  x.req(1, 0, b, false);                                          // CreateWindow
  await prop(x, id, 'WM_NAME', 'STRING', 8, Buffer.from('Upload - Google Chrome', 'latin1'));
  await prop(x, id, 'WM_CLASS', 'STRING', 8, Buffer.from(cls, 'latin1'));
  if (cls.startsWith('google-chrome')) await prop(x, id, '_NET_WM_PID', 'CARDINAL', 32, u32(PID));
  await prop(x, id, 'XdndAware', 'ATOM', 32, u32(5));
  x.req(8, 0, u32(id), false);                                    // MapWindow
  await x.sync();
  for (let i = 0; i < 50 && !(await x.viewable(id)); i++) await new Promise(r => setTimeout(r, 20));
}

(async () => {
  const [scene, file] = process.argv.slice(2);
  const tx = await x11.open(process.env.DISPLAY);                 // the browser
  const x = await x11.open(process.env.DISPLAY);                  // the daemon
  const main = tx.setup.ridBase | 0x100;
  await browserWindow(tx, main, scene === 'notbrowser' ? 'xterm\0XTerm\0' : 'google-chrome\0Google-chrome\0');

  const A = {};
  for (const n of ['XdndEnter', 'XdndPosition', 'XdndStatus', 'XdndLeave', 'XdndDrop', 'XdndFinished',
    'XdndSelection', 'XdndActionCopy', 'text/uri-list', '_FAKE_DROP']) A[n] = await tx.atom(n);
  const seen = { enter: 0, positions: 0, left: false, dropped: false, uri: '' };
  let src = 0;
  tx.listeners.add((e) => {
    const kind = e[0] & 0x7f;
    if (kind === x11.XE.SelectionNotify && e.readUInt32LE(20)) {
      tx.prop(main, '_FAKE_DROP', 'text/uri-list').then((v) => { seen.uri = v.trim(); });
      return;
    }
    if (kind !== x11.XE.ClientMessage || e.readUInt32LE(4) !== main) return;
    const type = e.readUInt32LE(8), d0 = e.readUInt32LE(12);
    if (type === A.XdndEnter) { seen.enter++; src = d0; return; }
    if (type === A.XdndLeave) { seen.left = true; return; }
    if (type === A.XdndPosition) {
      seen.positions++;
      const b = Buffer.alloc(20);                                 // ConvertSelection, as Chrome does on a position
      b.writeUInt32LE(main, 0); b.writeUInt32LE(A.XdndSelection, 4); b.writeUInt32LE(A['text/uri-list'], 8);
      b.writeUInt32LE(A._FAKE_DROP, 12); b.writeUInt32LE(e.readUInt32LE(24), 16);
      tx.req(24, 0, b, false);
      const yes = scene !== 'refuse' && seen.positions >= 2;
      tx.clientMessage(src, 'XdndStatus', [main, yes ? 1 : 0, 0, 0, yes ? A.XdndActionCopy : 0]);
      return;
    }
    if (type === A.XdndDrop) {
      seen.dropped = true;
      tx.clientMessage(src, 'XdndFinished', [main, 1, A.XdndActionCopy]);
    }
  });

  let line;
  try {
    const r = await x.dropFile(300, 200, file, PID, { acceptMs: 2500, finishMs: 2000 });
    await new Promise(res => setTimeout(res, 100));
    line = `drop=ok uri=${seen.uri} finished=${r.finished} accepted=${r.accepted} fetched=${r.fetched > 0} ` +
      `positions>1=${seen.positions > 1} dropped=${seen.dropped}`;
  } catch (e) {
    await new Promise(res => setTimeout(res, 100));
    line = `drop=refused left=${seen.left ? 'yes' : 'no'} msg=${e.message}`;
  }
  process.stdout.write(line + '\n');
  x.close(); tx.close();
})().catch((e) => { process.stdout.write(`drop harness broke: ${e.stack}\n`); process.exit(1); });
