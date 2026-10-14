// The login-link page (DIVE-6219). Redeems the one-time link from THIS origin,
// then shows the box's browser through noVNC. Nothing is redeemed until this
// script runs, so a link preview that only fetches the URL spends nothing.
const msg = document.getElementById('msg');
const say = (t) => { msg.textContent = t; msg.style.display = 'block'; };
const base = location.pathname.replace(/\/+$/, '');
let r;
try {
  r = await fetch(base + '/redeem', { method: 'POST', cache: 'no-store', headers: { 'x-5dive-viewer': '1' } });
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
  const rfb = new RFB(document.getElementById('screen'), 'wss://' + location.host + j.ws, { credentials: { password: j.password } });
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
