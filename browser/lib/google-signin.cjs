'use strict';
// GOOGLE'S SIGN-IN PAGES, ONE ANSWER EACH (DIVE-6228).
//
// "Sign up with Google" walks a page through accounts.google.com, and before
// this file every one of those pages met the generic sign-in guard: a URL with
// /signin/ in it is a sign-in form, refused. So the agent stopped one click
// short on every sign-up (round 1 of the Claude in Chrome head-to-head: 0 of 6),
// and not even consistently: the generic guard only runs when the site's own
// front page left the login unconfirmed, so the SAME chooser was let through on
// one attempt and refused on the next (DIVE-6214, Jamie A4g vs A4h).
//
// The rule now, and it is a pure function of (url, html), so the same page
// always gets the same answer whichever site led there:
//   allow  Google's account chooser listing a saved, signed-in account; the
//          "Continue as …" / "Sign in to <app> with Google" confirm; a consent
//          screen that asks for nothing beyond basic profile and email.
//   ask    a consent screen asking for more than that (calendar, contacts,
//          Drive, …), or Google's unverified-app warning. The owner decides.
//   stop   a password field; a verification code or any 2-step prompt; a robot
//          check; adding an account (Google's email box, or a chooser with no
//          signed-in account on it); Google refusing the browser; and any
//          accounts.google.com page this file does not recognise (fail closed).
//
// Used twice, and the two must never disagree: by bin/browser on the page a
// verb hands back (`node google-signin.cjs <html-file> <url>`), and by both
// step loops BEFORE each step on a Google page (stepStop), so a password is
// never typed and a wide grant is never clicked, whatever the steps say.

const STOP_PREFIX = '5dive-google-stop: ';

const GOOGLE_HOST = /^(accounts\.google\.[a-z.]+|(?:www\.)?google\.[a-z.]+)$/i;

function hostPath(url) {
  try { const u = new URL(url); return { host: u.hostname.toLowerCase(), path: u.pathname, search: u.search, u }; }
  catch (e) { return null; }
}

// Only these pages are this file's to judge. www.google.com is only its robot
// page (/sorry/); everything else on google.com is not a sign-in at all.
function isGooglePage(url) {
  const h = hostPath(url);
  if (!h || !GOOGLE_HOST.test(h.host)) return false;
  if (h.host.startsWith('accounts.')) return true;
  return /^\/sorry(\/|$)/i.test(h.path);
}

function decode(s) {
  return s.replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&quot;/g, '"')
    .replace(/&#39;|&#x27;|&rsquo;|&lsquo;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&#(\d+);/g, (m, n) => String.fromCharCode(Number(n)));
}

// What a person could read: scripts, styles, templates and hidden blocks out,
// tags out. Google ships most of its page as script data, and a word in there
// (an invisible reCAPTCHA loader, a scope list for another step) is not on screen.
function visibleText(html) {
  const t = String(html || '')
    .replace(/<(script|style|noscript|template)\b[\s\S]*?<\/\1\s*>/gi, ' ')
    .replace(/<([a-z0-9]+)\b[^>]*\b(?:hidden|aria-hidden=["']?true["']?|style=["'][^"']*display\s*:\s*none[^"']*["'])[^>]*>[\s\S]*?<\/\1\s*>/gi, ' ')
    .replace(/<[^>]+>/g, ' ');
  return decode(t).replace(/[‘’]/g, "'").replace(/\s+/g, ' ').trim().toLowerCase();
}

function attrsOf(tag) {
  const a = {};
  const re = /([a-z_:][-a-z0-9_:.]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?/gi;
  let m; const body = tag.replace(/^<[a-z0-9]+/i, '').replace(/\/?>$/, '');
  while ((m = re.exec(body))) a[m[1].toLowerCase()] = m[2] ?? m[3] ?? m[4] ?? '';
  return a;
}

function hiddenInput(a) {
  return 'hidden' in a || a['aria-hidden'] === 'true' || a.tabindex === '-1' || (a.type || '').toLowerCase() === 'hidden'
    || /display\s*:\s*none|visibility\s*:\s*hidden/i.test(a.style || '')
    || /^hidden/i.test(a.name || '');
}

// A password box a person could type into. Google's email page carries a
// hidden one (name="hiddenPassword", aria-hidden, tabindex=-1) for password
// managers; that one is not a password prompt.
function visibleInputs(html, pred) {
  const out = [];
  const re = /<input\b[^>]*>/gi; let m;
  const src = String(html || '').replace(/<(script|template)\b[\s\S]*?<\/\1\s*>/gi, ' ');
  while ((m = re.exec(src))) { const a = attrsOf(m[0]); if (!hiddenInput(a) && pred(a)) out.push(a); }
  return out;
}

// The accounts a chooser offers: Google tags each one with data-identifier
// (or data-email); a signed-out one is labelled "Signed out" and leads to a
// password page, so it does not count as a saved session.
function chooserAccounts(html, text) {
  const ids = new Set();
  const re = /\bdata-(?:identifier|email)\s*=\s*["']([^"']+@[^"']+)["']/gi; let m;
  while ((m = re.exec(String(html || '')))) ids.add(m[1].toLowerCase());
  if (!ids.size) { const re2 = /[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}/g; while ((m = re2.exec(text))) ids.add(m[0]); }
  const signedOut = (text.match(/\bsigned out\b/g) || []).length;
  return { count: ids.size, live: Math.max(0, ids.size - signedOut) };
}

// BASIC IS AN ALLOW-LIST; WIDE IS EVERYTHING ELSE. In the URL that is exact
// (OAuth scope names). On the screen it is Google's own wording, so the test
// is the other way round: any word for data beyond name, picture and email
// makes it wide, and a word we did not think of errs toward asking.
const BASIC_SCOPES = new Set(['openid', 'email', 'profile', 'https://www.googleapis.com/auth/userinfo.email',
  'https://www.googleapis.com/auth/userinfo.profile', 'https://www.googleapis.com/auth/plus.me']);
const WIDE_WORDS = new RegExp('\\b(' + [
  'calendars?', 'events?', 'contacts?', 'drive', 'gmail', 'inbox', 'e-?mail messages', 'send email',
  'youtube', 'photos?', 'files?', 'documents?', 'docs', 'sheets', 'spreadsheets?', 'slides', 'presentations?',
  'tasks?', 'locations?', 'street address(?:es)?', 'phone numbers?', 'birthday', 'gender', 'age range',
  'fitness', 'health', 'payments?', 'purchases?', 'google ads', 'analytics', 'cloud platform', 'admin',
  'groups', 'google chat', 'google meet', 'classroom', 'google keep', 'books', 'google forms', 'apps script',
  'blogger', 'search console', 'tag manager', 'business profile', 'on your behalf', 'edit, create',
  'and delete', 'additional access',
].join('|') + ')\\b', 'i');

function scopeVerdict(u, text, html) {
  const wide = [];
  const scope = u && (u.searchParams.get('scope') || '');
  for (const s of scope.split(/[\s+,]+/).filter(Boolean)) if (!BASIC_SCOPES.has(s)) wide.push(s);
  // The account's own address (…@gmail.com) is on every one of these screens.
  const w = text.replace(/[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}/g, ' ').match(WIDE_WORDS);
  if (w) wide.push(`"${w[0]}" on the screen`);
  // Google's granular consent puts a checkbox beside every scope beyond the
  // basic ones; the basic ones have none.
  if (visibleInputs(html, (a) => (a.type || '').toLowerCase() === 'checkbox').length) wide.push('a box to tick per extra permission');
  return wide;
}

function classify(url, html) {
  if (!isGooglePage(url)) return null;
  const { host, path, u } = hostPath(url);
  const text = visibleText(html);
  const r = (verdict, kind, why) => ({ verdict, kind, why });

  // ROBOT CHECKS FIRST: a challenge page often still carries the form under it.
  if (!host.startsWith('accounts.') || /\/challenge\/(recaptcha|captcha)\b/i.test(path)
      || /<iframe\b[^>]*src=["'][^"']*(recaptcha\/(?:api2|enterprise)\/(?:anchor|bframe)(?![^"']*size=invisible)|hcaptcha\.com|challenges\.cloudflare\.com)/i.test(html || '')
      || /unusual traffic|not a robot|type the text you (hear|see)/.test(text)) {
    return r('stop', 'robot', 'Google is showing a robot check. 5dive never solves one');
  }
  if (/\/signin\/(v2\/)?rejected\b/i.test(path) || /couldn't sign you in|this browser or app may not be secure/.test(text)) {
    return r('stop', 'rejected', 'Google refused to sign in from this browser');
  }
  if (/\/challenge\/pwd\b/i.test(path) || visibleInputs(html, (a) => (a.type || '').toLowerCase() === 'password').length) {
    return r('stop', 'password', 'Google is asking for a password. The agent never types one');
  }
  if (/\/challenge\//i.test(path) || /2-step verification|verification code|enter the code|check your phone|get a verification/.test(text)) {
    return r('stop', 'code', 'Google is asking for a verification code or a 2-step prompt');
  }
  if (/\/(v3\/)?signin\/(v2\/)?identifier\b|\/addsession\b|\/signup\b|\/lifecycle\//i.test(path)) {
    return r('stop', 'add-account', 'Google is asking for an email address, which means adding an account here. A person does that once');
  }
  if (/\/signin\/oauth\/(v2\/)?(warning|danger)\b/i.test(path) || /hasn't verified this app|google hasn't verified/.test(text)) {
    return r('ask', 'unverified', "Google warns the app is not verified. Ask the owner; it is their call");
  }
  if (/\/signin\/oauth\/(v2\/)?(consent|consentsummary)\b|\/o\/oauth2\/(v2\/)?consent\b/i.test(path)
      || /wants to access your google account|wants additional access/.test(text)) {
    const wide = scopeVerdict(u, text, html);
    if (wide.length) return r('ask', 'wide-consent', `Google is asking to grant more than basic profile and email (${wide.slice(0, 3).join(', ')}). Ask the owner; never click Allow on it`);
    return r('allow', 'basic-consent', 'a consent screen for basic profile and email only');
  }
  if (/accountchooser|oauthchooseaccount|selectaccount/i.test(path) || /choose an account/.test(text)) {
    const a = chooserAccounts(html, text);
    if (a.live) return r('allow', 'chooser', `Google's account chooser with ${a.live} saved account(s) signed in`);
    return r('stop', 'add-account', a.count
      ? 'every account on Google\'s chooser is signed out, so picking one leads to a password'
      : 'Google\'s chooser has no saved account to pick, only "Use another account"');
  }
  if (visibleInputs(html, (a) => (a.type || '').toLowerCase() === 'email' || /^identifier/i.test(a.id || a.name || '')).length) {
    return r('stop', 'add-account', 'Google is asking for an email address, which means adding an account here. A person does that once');
  }
  if (/\bcontinue as\b/.test(text) || (/\bsign in to\b/.test(text) && /\bwith google\b/.test(text))
      || /\/signin\/oauth\/(id|legacy)\b/i.test(path)) {
    const wide = scopeVerdict(u, text.replace(/\bsign in to .*? with google\b/, ''), html);
    if (wide.length) return r('ask', 'wide-consent', `Google is asking to grant more than basic profile and email (${wide.slice(0, 3).join(', ')}). Ask the owner; never click Allow on it`);
    return r('allow', 'continue', 'Google\'s "Continue as …" confirm for a saved account');
  }
  return r('stop', 'unknown', 'a Google sign-in page this browser does not recognise, so it stops rather than guess');
}

// BEFORE EACH STEP, in both loops. A goto leaves the page, and leaving is never
// the danger, so it is not checked. Everything else on a page that is not an
// allow stops the plan before that step touches it.
async function stepStop(page, s) {
  if (!s || s.op === 'goto') return null;
  let url = '';
  try { url = page.url(); } catch (e) { return null; }
  if (!isGooglePage(url)) return null;
  let html = '';
  try { html = await page.content(); } catch (e) { html = ''; }
  const v = classify(url, html);
  return v && v.verdict !== 'allow' ? { ...v, url } : null;
}

module.exports = { classify, isGooglePage, stepStop, visibleText, STOP_PREFIX };

if (require.main === module) {
  // node google-signin.cjs <html-file> <url>  ->  one JSON line, or nothing when
  // the URL is not a Google sign-in page.
  const fs = require('fs');
  const [file, url] = process.argv.slice(2);
  let html = '';
  try { html = fs.readFileSync(file, 'utf8'); } catch (e) { html = ''; }
  const v = classify(url || '', html);
  if (v) process.stdout.write(JSON.stringify(v) + '\n');
}
