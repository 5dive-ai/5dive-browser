#!/usr/bin/env node
// DIVE-7171 — the window's clipboard read and cleared, on a bare Xvfb, for the input-mode harness.
//
//   node tests/x11_clipboard.cjs <scene> [<text>]    prints one line: what the read did
//
// A second X connection plays the browser after a page's Copy button: it owns
// CLIPBOARD and answers UTF8_STRING with <text>. lib/x11.cjs is asked to read it.
//
//   held    -> "read=<text> cleared=true owner-after=none"
//   empty   nobody owns the clipboard -> "read= cleared=true owner-after=none"
//
// DISPLAY names the display.
'use strict';
const path = require('path');
const x11 = require(path.join(__dirname, '..', 'browser', 'lib', 'x11.cjs'));

async function owner(x) {   // GetSelectionOwner(CLIPBOARD) -> window id or 0
  const b = Buffer.alloc(4); b.writeUInt32LE(await x.atom('CLIPBOARD'), 0);
  const r = await x.req(23, 0, b, true);
  return r.readUInt32LE(8);
}

(async () => {
  const [scene, text] = process.argv.slice(2);
  const tx = await x11.open(process.env.DISPLAY);                 // the browser
  const x = await x11.open(process.env.DISPLAY);                  // the daemon
  if (scene === 'held') {
    const w = await tx.createInputWindow();
    await tx.ownSelection('CLIPBOARD', w, await tx.serverTime(w), { UTF8_STRING: Buffer.from(text || '', 'utf8') });
  }
  const got = await x.readClipboard(3000);
  const after = await owner(tx);
  process.stdout.write(`read=${got.text} cleared=${got.cleared} owner-after=${after ? 'held' : 'none'}\n`);
  tx.close(); x.close();
})().catch((e) => { process.stdout.write(`error=${e.message}\n`); process.exit(1); });
