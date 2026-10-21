// The login-link page (DIVE-6219). Redeems the one-time link from THIS origin,
// then shows the box's browser through noVNC. Nothing is redeemed until this
// script runs, so a link preview that only fetches the URL spends nothing.
//
// A PHONE SEES A PHONE PAGE (DIVE-6646). The redeem carries this page's size. A
// phone-wide page gets the box's browser window narrowed to it (fit=WxH), so the
// site uses its own phone layout, and this page draws only that corner of the
// box's screen, scaled to the phone's width: about 1:1, not 1280 px at 0.3. A
// desktop page gets no fit and draws the whole screen, as before.
const msg = document.getElementById('msg');
const say = (t) => { msg.textContent = t; msg.style.display = 'block'; };
const base = location.pathname.replace(/\/+$/, '');
let r;
try {
  r = await fetch(base + '/redeem', {
    method: 'POST', cache: 'no-store',
    headers: { 'x-5dive-viewer': '1', 'content-type': 'application/json' },
    body: JSON.stringify({ w: Math.round(innerWidth), h: Math.round(innerHeight) }),
  });
} catch (e) {
  r = null;
}
let j = {};
try { j = r ? await r.json() : {}; } catch (e) { j = {}; }
if (!r || !r.ok || !j.ws || !j.password) {
  say(j.error || 'This login link cannot be used any more. Ask your agent for a new one.');
} else {
  const { default: RFB } = await import('/browser/viewer/assets/novnc/core/rfb.js');
  const { default: keysyms } = await import('/browser/viewer/assets/novnc/core/input/keysymdef.js');
  msg.style.display = 'none';
  const screen = document.getElementById('screen');
  const fit = /^(\d+)x(\d+)$/.exec(j.fit || ''), full = /^(\d+)x(\d+)$/.exec(j.screen || '');
  if (fit && full) {
    // The whole screen, scaled so the fitted window's width is this page's
    // width, laid from the top-left corner: noVNC's own fit-to-box scaling then
    // draws exactly that, and a tap lands where it is drawn (no CSS transform
    // between the canvas and noVNC's pointer maths). The rest is off the page.
    const place = () => {
      const s = innerWidth / +fit[1];
      screen.style.cssText = 'position:fixed;left:0;top:0;right:auto;bottom:auto;' +
        'width:' + (+full[1] * s) + 'px;height:' + (+full[2] * s) + 'px';
    };
    place();
    document.body.style.overflow = 'hidden';
    addEventListener('resize', place);
  }
  const rfb = new RFB(screen, 'wss://' + location.host + j.ws, { credentials: { password: j.password } });
  j.password = '';
  rfb.scaleViewport = true;
  rfb.addEventListener('disconnect', () => say('The login screen is closed. When you are done, tap Done in Telegram.'));
  rfb.addEventListener('credentialsrequired', () => say('The login screen asked for a password it was not given. Ask your agent for a new link.'));
  // A phone has no physical keyboard: a hidden input raises the soft one and
  // forwards what is typed, character by character.
  const kbd = document.getElementById('kbd'), kin = document.getElementById('kin');
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
}
