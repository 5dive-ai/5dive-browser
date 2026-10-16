'use strict';
// A POPUP AN ACT OPENS IS FOLLOWED (DIVE-6392).
//
// Round 8 of the Google sign-up benchmark (cic-arm-a, browser 1.45.0): Gamma's
// page loaded with no challenge, and "Continue with Google" then did nothing the
// agent could see. The button showed pressed, no Google page came into view,
// and the retry pressed it twice more with the same result. A Google sign-in
// button usually opens the account chooser in a POPUP window (window.open, or a
// target=_blank OAuth link), and both step loops kept acting on, and re-reading,
// the page they started on. So the chooser opened in a window the agent never saw.
//
// Now each loop keeps a stack of pages: the one it started on, then each popup
// opened from the page in view. A popup is taken into view at the next step and
// before the re-read; the steps after it act in it, and the re-read is of it.
// When the popup closes (an OAuth window closes itself once the sign-in is done),
// the page that opened it is back in view. Each change is said in the act's
// output, so "nothing happened" can no longer be what a popup looks like.
//
// It changes nothing about what may be clicked. A popup's page goes through the
// same Google sign-in guard and the same owner checks as any other page, because
// the loops run those on the page in view, which is now the popup. A Cloudflare
// check in the popup is watched (the caller's onOpen), never clicked.
//
// Both step loops (bin/driver-playwright and bin/session-daemon) use this file,
// for the reason lib/aria.cjs exists: two copies of one rule drift.

// How long a click or a key press gets to open a popup before the next step, or
// the re-read, goes on without one. Paid only after a click or a press, and only
// while no popup has arrived: one that arrives sooner ends the wait at once.
const WAIT_MS = () => {
  const v = Number(process.env.FIVEDIVE_BROWSER_POPUP_WAIT_MS);
  return Number.isFinite(v) && v >= 0 ? v : 1000;
};
// How long a popup gets to load its first page before it is shown as it is.
const LOAD_MS = () => Number(process.env.FIVEDIVE_BROWSER_POPUP_LOAD_MS) || 15000;

// The ops that can open a window. fill, type, select and upload do not, in any
// page measured, and charging them the wait would slow every form.
const OPENS = new Set(['click', 'press']);

function hostOf(u) {
  try { const x = new URL(String(u)); return x.host || x.href; } catch (e) { return String(u || ''); }
}
function originOf(u) {
  try { const x = new URL(String(u)); return /^https?:$/.test(x.protocol) ? x.origin : null; } catch (e) { return null; }
}
function isClosed(p) {
  try { return typeof p.isClosed === 'function' && p.isClosed(); } catch (e) { return true; }
}
function urlOf(p) {
  try { return p.url(); } catch (e) { return ''; }
}

// follow(<the page the act starts on>, {log, onOpen, stepTimeout}) -> a follower.
//   .page            the page in view now
//   .sync(op)        call before a step and before the re-read, with the op that
//                    ran last (or null); returns the page in view
//   .popup           what the act output names: {url, host, opener} of the popup
//                    in view, or null when the page it started on is in view
//   .pageFor(url)    the served browser's question, below
//   .home()          the page it started on back in view, popups left open
//   .use({log, onOpen}) where the next lines go: a served browser's follower
//                    outlives the request that made it
//   .stop()          stops listening
// The stub pages the harness uses may lack on/off/isClosed; each is optional.
function follow(start, opts = {}) {
  let log = () => {}, onOpen = null;
  const use = (o) => {
    log = typeof o.log === 'function' ? o.log : () => {};
    onOpen = typeof o.onOpen === 'function' ? o.onOpen : null;
  };
  use(opts);
  const stack = [start];
  const arrived = [];
  const watched = [];
  let wake = null;
  const onPopup = (p) => { arrived.push(p); if (wake) { const w = wake; wake = null; w(); } };
  const watch = (p) => {
    if (!p || typeof p.on !== 'function' || watched.includes(p)) return;
    watched.push(p); p.on('popup', onPopup);
  };
  watch(start);
  const top = () => stack[stack.length - 1];

  // A popup that closed hands the view back to the page that opened it.
  const dropClosed = () => {
    while (stack.length > 1 && isClosed(top())) {
      const gone = stack.pop();
      log(`the popup (${hostOf(urlOf(gone))}) closed; back on ${hostOf(urlOf(top()))}`);
    }
  };

  const take = async (p) => {
    if (isClosed(p)) {
      log(`a popup opened (${hostOf(urlOf(p))}) and closed again by itself; still on ${hostOf(urlOf(top()))}`);
      return;
    }
    // Its first page, or as much of it as loaded: a popup that never finishes
    // loading is still the window the click opened, and is shown as it is.
    try { if (typeof p.waitForLoadState === 'function') await p.waitForLoadState('domcontentloaded', { timeout: LOAD_MS() }); }
    catch (e) { /* shown as it is */ }
    if (isClosed(p)) {
      log(`a popup opened (${hostOf(urlOf(p))}) and closed again by itself; still on ${hostOf(urlOf(top()))}`);
      return;
    }
    if (opts.stepTimeout && typeof p.setDefaultTimeout === 'function') p.setDefaultTimeout(opts.stepTimeout);
    const opener = urlOf(top());
    watch(p);
    stack.push(p);
    log(`a popup opened: ${hostOf(urlOf(p))}, now in view (${urlOf(p)}). The steps after this act in it; ` +
      `when it closes, ${hostOf(opener)} is back in view.`);
    if (onOpen) { try { await onOpen(p); } catch (e) { /* the popup is in view whatever this says */ } }
  };

  return {
    get base() { return start; },
    get page() { return top(); },
    use,
    get popup() {
      if (stack.length < 2) return null;
      return { url: urlOf(top()), host: hostOf(urlOf(top())), opener: urlOf(stack[stack.length - 2]) };
    },
    async sync(lastOp) {
      dropClosed();
      const ms = OPENS.has(lastOp) ? WAIT_MS() : 0;
      if (!arrived.length && ms > 0) {
        let timer;
        await new Promise((resolve) => { wake = resolve; timer = setTimeout(resolve, ms); });
        clearTimeout(timer); wake = null;
      }
      while (arrived.length) await take(arrived.shift());
      dropClosed();
      return top();
    },
    // The page to use for a request on <url> in a served browser that an earlier
    // act left on a popup: the popup, while it is open and <url> is on its origin,
    // or when there is no <url> (an act that continues on the page in view);
    // otherwise null (the caller's usual page).
    pageFor(url) {
      dropClosed();
      if (stack.length < 2) return null;
      if (url == null || url === '') return top();
      const want = originOf(url);
      return want && want === originOf(urlOf(top())) ? top() : null;
    },
    home() { stack.length = 1; arrived.length = 0; return start; },
    stop() {
      for (const p of watched) {
        try { (p.off || p.removeListener).call(p, 'popup', onPopup); } catch (e) { /* gone */ }
      }
      watched.length = 0;
    },
  };
}

module.exports = { follow, OPENS, hostOf, originOf, WAIT_MS };
