'use strict';
// THE NAMED SITE'S TAB, IN FRONT (DIVE-7257).
//
// lodar, 10-29, on chill-gorge: the sign-in link for bing.com showed the Google
// Play console. The sites of a sign-in group share ONE Chrome (every new site
// joins the group "Main"), so bing.com and Play were two tabs of one window, and
// the viewer showed the window as it was: whichever tab was last in front.
//
// When a person is shown the window for a site, a tab on that site is brought to
// the front first: the tab agents drive when it is already on the site (a check
// an agent stopped on is in that tab), else the first open tab on the site, else
// none, and the caller opens one. The other tabs are left as they are.
//
// The tab shown is then the tab agents drive (session-daemon pageOf), so the
// person watches the tab the agent's next step acts in.

function hostOf(u) {
  try { return new URL(u).hostname.toLowerCase(); } catch (e) { return ''; }
}

// On the site: the same host or one under it. `www.` on the site's own URL is
// dropped, so www.bing.com and bing.com are one site either way round.
function onSite(url, host) {
  const h = hostOf(url);
  const want = String(host || '').toLowerCase().replace(/^www\./, '');
  if (!h || !want) return false;
  return h === want || h.endsWith('.' + want);
}

function pick(pages, host, driven) {
  const open = pages.filter((p) => !(typeof p.isClosed === 'function' && p.isClosed()));
  if (driven && open.includes(driven) && onSite(driven.url(), host)) return driven;
  return open.find((p) => onSite(p.url(), host)) || null;
}

module.exports = { hostOf, onSite, pick };
