// The login-link page's top bar (DIVE-7223): the site's name, one line of help,
// and Type / Paste, the same bar and the same behaviour as the 5dive.ai hosted
// viewer (shelld's viewerPage in 5dive-api). lodar, 2026-10-29: the self-hosted
// page should look like the hosted one, and its Keyboard button did nothing.
//
// WHY A VISIBLE FIELD AND A SEND BUTTON, not a hidden input that forwards each
// key (the DIVE-6219 Keyboard button). A phone keyboard types through an input
// method: Gboard sends keydown "Unidentified" (229) for letters and Backspace and
// rewrites a composing word on every key. Forwarding each `input` and clearing
// the field broke that word, so "hello" arrived as "hhehelhellhello", and a
// Backspace never arrived at all; an off-screen 1x1 input does not raise the
// keyboard on every phone either. Here the owner types into a real field in the
// bar, where the phone's keyboard edits it as it likes, and Send delivers the
// finished text once. Node-importable: tests/browser_viewer_keyboard_unit.sh.

export const TEXT = {
  en: {
    note: 'Log in here. This window is one-time — closing it ends the view.',
    placeholder: 'Paste or type here',
    send: 'Send',
    type: 'Type',
    typeTitle: 'Type into the page with your own keyboard',
    paste: 'Paste',
    pasteTitle: 'Paste your clipboard into the page',
    title: 'log in',
    opening: 'Opening the login screen…',
    spent: 'This login link cannot be used any more. Ask your agent for a new one.',
    closed: 'The login screen is closed. When you are done, tap Done in Telegram.',
    password: 'The login screen asked for a password it was not given. Ask your agent for a new link.',
  },
  ru: {
    note: 'Войдите здесь. Окно одноразовое — если его закрыть, просмотр закончится.',
    placeholder: 'Вставьте или введите текст',
    send: 'Отправить',
    type: 'Ввод',
    typeTitle: 'Печатать на странице со своей клавиатуры',
    paste: 'Вставить',
    pasteTitle: 'Вставить текст из буфера обмена на страницу',
    title: 'вход',
    opening: 'Открываем окно входа…',
    spent: 'Эта ссылка для входа больше не работает. Попросите агента прислать новую.',
    closed: 'Окно входа закрыто. Когда закончите, нажмите Done в Telegram.',
    password: 'Окну входа не хватило пароля. Попросите агента прислать новую ссылку.',
  },
};

// The first of the browser's own languages that TEXT has; English otherwise.
export function pickText(langs) {
  for (const l of langs || []) {
    const t = TEXT[String(l).toLowerCase().split('-')[0]];
    if (t) return t;
  }
  return TEXT.en;
}

// How long a pasted string stays on the box clipboard (the hosted viewer's
// DIVE-5020 value): Chrome reads the selection after the key, so clearing it at
// once would race the paste.
export const PASTE_CLEAR_MS = 2000;

// Puts text into the focused field of the box's browser. x11vnc speaks only
// classic cut text, which noVNC sends as Latin-1, so Latin-1 text goes through
// the box clipboard and Ctrl+V (then the clipboard is emptied, so a pasted
// password does not stay where the agent's browser could read it); anything
// else is typed as Unicode keysyms. Same rules as the hosted viewer.
export function sendText(rfb, text, timer = { id: 0 }) {
  if (!text) return;
  if ([...text].every((ch) => ch.codePointAt(0) < 0x100)) {
    rfb.clipboardPasteFrom(text);
    rfb.sendKey(0xffe3, 'ControlLeft', true);
    rfb.sendKey(0x76, 'KeyV');
    rfb.sendKey(0xffe3, 'ControlLeft', false);
    clearTimeout(timer.id);
    timer.id = setTimeout(() => rfb.clipboardPasteFrom(''), PASTE_CLEAR_MS);
  } else {
    for (const ch of text) {
      const cp = ch.codePointAt(0);
      if (cp === 13 || (cp < 0x20 && cp !== 9 && cp !== 10)) continue;
      rfb.sendKey(cp === 10 ? 0xff0d : cp === 9 ? 0xff09 : cp < 0x100 ? cp : 0x01000000 + cp, null);
    }
  }
  rfb.focus();
}

// Labels the bar in the viewer's language and wires Type, Paste and Send to the
// noVNC connection. The buttons stay disabled until connect() is called.
export function wireBar(doc, rfb, t, clipboard) {
  const $ = (id) => doc.getElementById(id);
  const note = $('note'), typeBtn = $('type'), pasteBtn = $('paste'), box = $('pastebox'), field = $('pastein');
  note.textContent = t.note;
  field.placeholder = t.placeholder;
  box.querySelector('button').textContent = t.send;
  typeBtn.textContent = t.type; typeBtn.title = t.typeTitle;
  pasteBtn.textContent = t.paste; pasteBtn.title = t.pasteTitle;
  let live = false;
  const timer = { id: 0 };
  // Shown and focused in the tap's own handler, on screen: that is what lets a
  // phone raise its keyboard.
  const open = () => { note.hidden = true; box.hidden = false; field.focus(); };
  typeBtn.addEventListener('click', open);
  pasteBtn.addEventListener('click', async () => {
    let text = null;
    try { text = await clipboard.readText(); } catch (e) { text = null; }
    if (text && live) sendText(rfb, text, timer); else open();
  });
  box.addEventListener('submit', (e) => {
    e.preventDefault();
    const text = field.value;
    field.value = '';
    if (live) sendText(rfb, text, timer);
  });
  return {
    connect() { live = true; typeBtn.disabled = false; pasteBtn.disabled = false; },
    disconnect() {
      live = false; typeBtn.disabled = true; pasteBtn.disabled = true;
      box.hidden = true; field.value = '';
      clearTimeout(timer.id);
    },
  };
}
