# Logins, Google sign-up, captchas, blocks and two accounts

Part of the use-browser skill. Read it when a page verb stops on a sign-in, a Google page, a captcha or a block, or a site has two accounts.

## Pages that need the owner's login

A page verb refuses a page that is visibly a sign-in form or a challenge, and never hands one
back as evidence. On a site with no adapter it proceeds otherwise, and says that no adapter
confirmed the login. If you hit the sign-in refusal on a page that must be the owner's account,
switch to the `connect-site` skill. Never type the owner's password yourself, and never try to
get past a CAPTCHA or other challenge.
**Claude in Chrome, only when the stop names it.** If this agent has Claude in Chrome connected
(opt-in, `5dive browser claude status`), the sign-in stop starts with "This agent has Claude in
Chrome". Then, and only then, finish that one sign-in step with your Claude in Chrome tools and come
back here for the rest of the task. Never reach for Claude in Chrome for anything else.
An authenticator-app 2FA prompt is the one exception, and only on a site whose owner saved its
seed on the box: `run` types the code itself, and `5dive browser totp fill <site> [<url>]` does
it on demand. Neither shows you the code. With no seed saved, it stops like any challenge.

**"Sign up / Sign in with Google" when the browser already holds a Google login.** If your
default group (Main) holds the Google sign-in, a page verb on a new site puts that site in Main by
itself and says so in one line ("shopify.com joined Main …"), so its Google button sees the
account. Nothing for you to run first. Google's own pages get one fixed answer each, whatever
site led there:

- **You may click:** the account chooser, to pick the saved account the task names (never another
  one); the "Sign in to <app> with Google" / "Continue as …" confirm; a consent screen that asks
  only for basic profile and email (the "See your gender / languages" lines under the profile
  item are its details, not extra access). Carry on with `act <the site you started on>` and no
  URL: the whole sign-up stays in that one browser. Never copy a Google URL into a command; its
  long query IS the sign-up, and a cut copy opens Google's "400. That's an error." page.
- **Hard stop (exit 75), hand it over:** a password field, a verification code or 2-step prompt, a
  robot check, Google asking for an email address (adding an account), a chooser whose account is
  signed out. `5dive browser handoff <site>` (a robot check: `connect-request <site> --challenge`).
- **Google's error page (exit 76)**, "400. That's an error.": the sign-up was lost, not refused.
  Open the site's sign-up again and click its Google button.
- **A sign-up that lands on the site's own login page** with "Continue with Google" (or a button
  that says just "Google") on it comes back with a note saying so. Click that button and nothing
  else on that page, again with `act <site>` and no URL.
- **The site's own terms step** ("I agree to the Terms of Use / Privacy Policy" box + Continue,
  e.g. Pitch's "We take your privacy seriously"): tick it and continue, `act <site>` and no URL.
  Agreeing to the terms of the account the job names IS the sign-up, not a grant. Leave optional
  boxes (newsletters, marketing) unticked.
- **Ask your owner (exit 73):** a Google consent screen that wants more than basic profile and
  email (calendar, contacts, Drive, extra scope boxes to tick). Tell them what it wants. Never click Allow on it; if
  they say yes, they click it themselves through `handoff`.

**Do not ask about sign-up housekeeping** when the job says "sign up": a required workspace or
team name the job did not give takes a neutral default (the page's placeholder, or "My
Workspace"), and a session on the site for another account than the one the job names is signed
out first. Say what you did in your report.

**Blocked from a server IP** ("Request blocked by network security", "suspicious network"):
some sites block server IPs; `5dive browser proxy set <url>` sends this box's browser through
your own proxy. That is the owner's proxy and the owner's call — tell them, and use only a URL
they give you. Switching the proxy mid-session can end a site's login (the site sees a new IP).

**Two accounts on one site** (`github.com_work`, `github.com_personal`): a URL alone is refused
and the refusal names both. **Ask the owner which one, never guess**, then name it:
`5dive browser act github.com_work <url> --steps=…`.

## Stuck on a captcha: ask the owner to clear it, then carry on (DIVE-5200)

A CAPTCHA, a "verify you are human" or a "Just a moment…" check is a hard stop. You never
solve it and never look for a way round it. A "Just a moment…" usually clears by itself, so the
browser already watches it for up to 90 s in the same page load before it says STOP; once it has,
do not sleep and snapshot again: a fresh load starts the check over. But you do not give up the task either: ask the
person, wait, and finish the job yourself.

```bash
5dive browser connect-request <site> --challenge --url=<the page you were stopped on> \
  --reason="<one line: what you were doing>"
```

`<site>` is the host (`futuretools.io`), even if you were browsing with nothing connected.
A page verb that hits a check prints this exact command for you. Your paired owner gets
"I'm stuck on a captcha on <site>" with an **Open <site>** button; their tap opens the box
browser on that page and sends them a one-time link as code, from root, never through you.
They clear the check and tap **Done**. Done closes their view and **hands the same browser
back to you, on that page**, so the check stays cleared for you.

**The box loads the page first** (DIVE-6725). If the page is an error, nobody is messaged and
the command fails: a 4xx/5xx with no check on it, a "Page not found", or a page that does not
load at all means the address is wrong. Find the right one first (`5dive browser snapshot <url>`).
If the page loads with no check on it, the owner is still asked, but to **take over** and not to
clear a captcha. Then `--reason` is what they read as what to do, so make it the one thing to tap
(`--reason="tap Got it on the URL inspection bubble"`). Done tells you what the page shows now
(its title, its address, and whether a check is still on it). It never says the check was cleared.

After the `[browser challenge] … tapped Done` message, carry on **without asking again**:

1. First check what already happened. If the step you were on may have gone through,
   read the result (the listing, the sent folder, the confirmation page) before you redo it.
   Nothing is sent twice.
2. Re-read the page you were stopped on (`5dive browser snapshot <url>`). It goes through
   the browser profile the owner just used.
3. Clear: continue from that step. Still a check: say so once and stop.

Do not poll while you wait. Do not open the link. A flat block with nothing to click
("access denied", a 403 from a server IP) is not a check a person can clear; see
"Blocked from a server IP".

