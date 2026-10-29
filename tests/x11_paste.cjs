#!/usr/bin/env node
// DIVE-7237 — a paste step's clipboard, on a bare Xvfb, for browser_input_paste_unit.sh.
//
//   node tests/x11_paste.cjs <scene> [<text>]    prints one line: what the paste did
//
// lib/x11.cjs pastes <text> (offers it on CLIPBOARD, presses ctrl+v). A second
// X connection plays the browser that reads it on ctrl+v.
//
//   read      -> "served=true read=<json of what the browser read> owner-after=none"
//   noreader  nobody asks -> "served=false owner-after=none"
//   big       one byte over the cap -> "error=<the refusal>"
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
  const x = await x11.open(process.env.DISPLAY);                  // the daemon
  const br = await x11.open(process.env.DISPLAY);                 // the browser
  if (scene === 'big') {
    try { await x.paste('a'.repeat(200001), 500); process.stdout.write('error=none\n'); }
    catch (e) { process.stdout.write(`error=${e.message}\n`); }
  } else if (scene === 'read') {
    let read = null;
    const reader = (async () => { await new Promise((r) => setTimeout(r, 250)); read = (await br.readClipboard(3000)).text; })();
    const r = await x.paste(text, 3000);
    await reader;
    process.stdout.write(`served=${r.served} read=${JSON.stringify(read)} owner-after=${(await owner(br)) ? 'held' : 'none'}\n`);
  } else {
    const r = await x.paste(text || 'x', 600);
    process.stdout.write(`served=${r.served} owner-after=${(await owner(br)) ? 'held' : 'none'}\n`);
  }
  x.close(); br.close();
})().catch((e) => { process.stdout.write(`error=${e.message}\n`); process.exit(1); });
