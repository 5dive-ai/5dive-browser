'use strict';
// A FILE AN ACT DOWNLOADED, HANDED TO THE SEAT (DIVE-5751).
//
// A click on an export button (a report, an audio file, a CSV) starts a download.
// Playwright keeps it as a nameless temp file inside the browser's own 0700 cache
// and deletes it when the context closes, so before this the file never reached
// the seat that asked: `act` said "done: every step ran" and nothing else, and on
// a seat without sudo there was no way to reach it at all (measured 2026-10-06:
// a 24.6 MB m4a, found only by `sudo find`).
//
// Both step loops (bin/driver-playwright and bin/session-daemon) use this file,
// for the reason lib/aria.cjs exists: two copies of one rule drift. Each loop
// watches the pages of the act, and after the re-read saves every download into
// a directory, under the name the site suggested, made safe. Where the bytes go
// next is the caller's business: the one-shot driver runs as the caller and
// writes into the caller's own staging directory; the daemon runs as the
// profile's owner and sends the bytes back over the socket (the DIVE-4664 trade
// `render` and `snapshot` already make), so the caller writes them itself.

const fs = require('fs');
const path = require('path');

// The longest a download is waited for after the steps. An export the server is
// still building is normal; one that has not finished in two minutes is reported
// as unfinished and cancelled, never waited on forever under the lease.
const WAIT_MS = Number(process.env.FIVEDIVE_BROWSER_DOWNLOAD_WAIT_MS) || 120000;
// The most one act hands over. The served path carries the bytes as base64 over
// the socket, so the cap is what keeps one act from holding hundreds of MB in two
// processes. Over it, the file is named and its size given, and nothing is saved.
const MAX_BYTES = (Number(process.env.FIVEDIVE_BROWSER_DOWNLOAD_MAX_MB) || 100) * 1024 * 1024;
// Raw bytes per chunk line on the socket: a multiple of 3, so the base64 chunks
// concatenate into one valid stream and `base64 -d` decodes them as one.
const CHUNK = 3 * 256 * 1024;

// THE NAME IS THE SITE'S, SO IT IS UNTRUSTED. A suggested filename of
// `../../.bashrc` or `.ssh/authorized_keys` must land as a plain file inside the
// directory, never beside it: the last path segment only, no control characters,
// no leading dots, and never empty. A second file with the same name gets -2, -3.
function safeName(suggested, taken) {
  let n = String(suggested == null ? '' : suggested).replace(/[\x00-\x1f\x7f]/g, '');
  n = n.split(/[\\/]/).pop().trim().replace(/^\.+/, '').trim();
  if (Buffer.byteLength(n) > 180) {
    const ext = path.extname(n).slice(0, 16);
    n = Buffer.from(n.slice(0, n.length - ext.length)).subarray(0, 160).toString('utf8').replace(/�+$/, '') + ext;
  }
  if (!n) n = 'download';
  let out = n, k = 2;
  const ext = path.extname(n), stem = n.slice(0, n.length - ext.length);
  while (taken.has(out)) out = `${stem}-${k++}${ext}`;
  taken.add(out);
  return out;
}

// Start listening on every page the act can reach: the one it acts on, any other
// open tab, and any tab a click opens (an export that opens a new tab to download
// is common). Returns the list it fills and a stop().
function watch(ctx, page) {
  const seen = [];
  const pages = new Set();
  const onDownload = (d) => seen.push(d);
  const add = (p) => {
    if (!p || pages.has(p) || typeof p.on !== 'function') return;
    pages.add(p); p.on('download', onDownload);
  };
  add(page);
  try { for (const p of (ctx && typeof ctx.pages === 'function' ? ctx.pages() : [])) add(p); } catch (e) { /* best effort */ }
  const onPage = (p) => add(p);
  if (ctx && typeof ctx.on === 'function') ctx.on('page', onPage);
  return {
    list: seen,
    stop() {
      for (const p of pages) { try { (p.off || p.removeListener).call(p, 'download', onDownload); } catch (e) { /* gone */ } }
      if (ctx && typeof ctx.off === 'function') { try { ctx.off('page', onPage); } catch (e) { /* gone */ } }
    },
  };
}

// A download raced against a deadline. The timer is cleared when the save wins,
// so a finished save never holds the process open for the rest of the wait.
function saveBefore(d, file, ms) {
  let t;
  const late = new Promise((resolve) => { t = setTimeout(() => resolve('timeout'), ms); });
  return Promise.race([d.saveAs(file).then(() => 'saved'), late]).finally(() => clearTimeout(t));
}

// Save every download the watch saw into <dir>, waiting for unfinished ones up
// to WAIT_MS in all. One entry per download, in the order they started:
//   { name, bytes, file }          saved: <dir>/<name>
//   { name, bytes?, error }        not saved, and why in words
async function save(w, dir, opts = {}) {
  const waitMs = opts.waitMs || WAIT_MS, max = opts.maxBytes || MAX_BYTES;
  const deadline = Date.now() + waitMs;
  const taken = new Set(), out = [];
  for (const d of w.list) {
    let raw = '';
    try { raw = d.suggestedFilename(); } catch (e) { /* unnamed */ }
    const name = safeName(raw, taken);
    const file = path.join(dir, name);
    try {
      const left = Math.max(1000, deadline - Date.now());
      const r = await saveBefore(d, file, left);
      if (r === 'timeout') {
        try { await d.cancel(); } catch (e) { /* it may have just finished */ }
        try { fs.unlinkSync(file); } catch (e) { /* never written */ }
        out.push({ name, error: `still downloading after ${Math.round(waitMs / 1000)}s, so it was cancelled` });
        continue;
      }
      const bytes = fs.statSync(file).size;
      if (bytes > max) {
        fs.unlinkSync(file);
        const cap = max >= 1048576 ? `${Math.round(max / 1048576)} MB` : `${max} bytes`;
        out.push({ name, bytes, error: `${bytes} bytes is over the limit an act hands over (${cap}, FIVEDIVE_BROWSER_DOWNLOAD_MAX_MB)` });
        continue;
      }
      out.push({ name, bytes, file });
    } catch (e) {
      let why = '';
      try { why = (await d.failure()) || ''; } catch (e2) { /* no reason to give */ }
      try { fs.unlinkSync(file); } catch (e3) { /* never written */ }
      out.push({ name, error: `the download failed: ${why || (e && e.message) || 'no reason given'}` });
    } finally {
      // Playwright's own temp copy goes now, not when the context closes: a served
      // browser stays up for days, and every export would otherwise stay in its cache.
      if (typeof d.delete === 'function') { try { await d.delete(); } catch (e) { /* already gone */ } }
    }
  }
  return out;
}

// The served path's wire shape: one metadata line per download, then its bytes as
// chunk lines. `send` is the daemon's out-line writer.
function stream(entries, send) {
  entries.forEach((e, i) => {
    const meta = { act_download: true, i, name: e.name };
    if (e.bytes != null) meta.bytes = e.bytes;
    if (e.error) meta.error = e.error;
    send(JSON.stringify(meta) + '\n');
    if (e.error || !e.file) return;
    const fd = fs.openSync(e.file, 'r');
    try {
      const buf = Buffer.alloc(CHUNK);
      let n;
      while ((n = fs.readSync(fd, buf, 0, CHUNK, null)) > 0) {
        send(JSON.stringify({ act_download_chunk: true, i, b64: buf.subarray(0, n).toString('base64') }) + '\n');
      }
    } finally { fs.closeSync(fd); }
  });
}

module.exports = { safeName, watch, save, stream, WAIT_MS, MAX_BYTES, CHUNK };
