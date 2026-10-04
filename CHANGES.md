# 5dive browser — changelog

One plugin, one repo, one changelog. Entries before 2026-09-20 were carried over from
`5dive-ai/5dive-plugins/CHANGES.md`, which browser shared with telegram, dashboard, buzz and
voice — every two PRs to that file collided trivially, and splitting it is the reason this repo
exists (DIVE-4661). Only the sections that named a `browser <version>` came across; the rest of
that file stays where it is.

## Unreleased

### Fixed — two serves of one site no longer leave a browser nothing tracks (DIVE-5528), 1.32.2

On hale-hawk (2026-10-04) an OINOA cabinet retried a Connect that the API's proxy had cut at 30 s
while the first was still starting on the box. Both `serve`s read "not running" and launched. The
loser's daemon found the profile taken ("Opening in existing browser session"), its plain-Chrome
fallback handed off and exited 0, and its failure path removed the WINNER's pidfile. The winner's
browser kept the profile with nothing pointing at it: `served` listed nothing, a stop had nothing to
stop, and every later serve of avito.ru and ya.ru failed with "chrome exited immediately".

- **One start at a time per site.** `serve` takes `<profile>/.5dive-serve.lock` (flock, 120 s,
  `FIVEDIVE_BROWSER_SERVE_LOCK_WAIT`) before it reads "is it running", so the second serve waits and
  then answers "already serving". `_tmp_exec` closes the lock fd before exec: a daemon that lives
  for hours must not hold every later serve of its site.
- **A session daemon no pidfile names is stopped.** Under the lock, with nothing running per the
  pidfile, a profile whose SingletonLock holder is the child of `session-daemon serve <this dir>` is
  the race's leftover. The daemon gets SIGTERM (it closes the context, which writes the profile
  out), then its Xvfb goes, and the serve proceeds. Any other holder (a person's plain Chrome, a
  probe) is never touched. This is what heals a box already stuck this way, on its next connect.
- **A lock wait that runs out refuses** (exit 69, "another start of <site> is still running"). It
  never goes on without the lock: that is the race itself, and the reap would stop the other serve's
  daemon mid-start. With no `flock` on the box nothing is reaped.
- `tests/browser_serve_race_unit.sh`: R1–R5, 16 arms pass; on 1.32.1, 6 fail (R1: the second serve
  started its own daemon; R3: the untracked daemon blocks every serve), and on the first cut of this
  fix R5's 3 fail (the timed-out serve went on and reaped the live daemon).

### Fixed — input mode types a whole Chinese (or any non-Latin) message, not the first 18 distinct characters (DIVE-5433), 1.32.1

On chill-gorge (2026-10-03 03:21Z) Clicker typed a lodar-approved Chinese DM into Telegram Web in input
mode and it stopped after '服务器上'. A character the keyboard has no key for is typed on a spare
keycode bound to it for the moment. Xvfb's keymap has 18 spare keycodes, and 1.32.0 bound one per
distinct character and never released it, so the 19th distinct character threw "no spare key" and
the act ended with the text cut short. Bindings lived on the X server, so a restarted daemon on the
same display found no spare keys at all.

- **Spare keys are recycled, least recently used first** (`lib/x11.cjs` `keyFor`). A key is rebound
  only after every other spare has been used since, so the page has long read the character it
  carried. A character already on a key is reused without a rebind.
- **A new connection reclaims keys an earlier one bound** (a single Unicode keysym and nothing else),
  so a daemon restart on a live display types on.
- `tests/browser_input_drive_unit.sh`: K1–K3 on a bare Xvfb (43 distinct characters on 18 spare
  keys; the keys left bound are the newest 18; a new connection reclaims them), 3 pass, all 3 red
  on 1.32.0 (K1 fails at the 19th character, as on chill-gorge). L12 types the Chinese sentence
  into live Chrome and reads it back whole. New probe `tests/x11_keys.cjs` reads the map directly.

### Added — a hired agent uses a site the owner just connected, with no admin step (DIVE-5389), 1.32.0

On chill-gorge (2026-10-02) lodar connected discord.com and tapped Done. Clicker, a hired seat that
uses the owner's logins through the broker, was refused until head ran a box-local serve script by
hand; devhunt.org went the same way on 09-30 (DIVE-5242). Done is viewer-revoke, `serve --stop`,
status, so after every Connect nothing holds the profile, and a brokered seat could only be told
to ask somebody.

- **A brokered verb starts the box's browser for that site itself.** When the box offers the login
  and nothing serves it, `_broker_ready` (every brokered verb, input or CDP) runs
  `sudo -n /usr/local/bin/5dive browser _serve-offered` with the site on stdin, then carries on.
  The seat sees one line on stderr saying the browser was started.
- **`_serve-offered` (root)** takes exactly one site and no flags. It reads the caller from
  SUDO_UID, never from input. It serves only a site the box offers to a seat that is not the owner
  and has no login of its own (DIVE-4813's three box facts). It runs plain `serve <site>` as the
  owner and nothing else: no stop, auth, forget or profile creation. One start runs at a time per
  owner, so two seats arriving together start one browser. Under systemd the browser runs in its
  own transient scope, not in the asking agent's unit. Restarting that agent does not kill a
  session other seats are using, and its ~420 MB does not count against that agent's memory limit.
- **Memory floor:** below 800 MB MemAvailable the start is refused with that reason and nothing
  starts (each served site is a Chrome of ~420 MB, and chill-gorge has 3.8 GB). Only the on-demand
  path is floored. An owner's own `serve` is not.
- **The grant:** `sudo 5dive browser setup` now writes `/etc/sudoers.d/5dive-browser`, checked by
  `visudo -c`, for the rendezvous group. That is the same group that can already drive every
  served socket. It is the one exact command with no argument wildcard. A box that has not re-run
  setup keeps the old refusal, which now also says the start was tried and why it failed.
  `FIVEDIVE_BROWSER_NO_WAKE=1` turns the start off for a seat.
- **Not chosen:** leaving the site warm-served at Done. That would hold ~420 MB per connected site
  whether or not any agent uses it.
- Harness: `tests/browser_input_drive_unit.sh` R9b–R9e, covering an input site and a CDP site
  started on demand, an already-served site left alone, the floor and its control, the no-grant
  refusal, and the root verb's refusals.

### Fixed — the Connected-sites panel says what a person reading the page would say (DIVE-5388), 1.31.0

On chill-gorge (2026-10-02) the panel said "Needs you" on reddit.com and openalternative.co
while their served browsers were signed in, "No automatic check" on 7 of 13 connected sites,
and every served site's stamp was hours old. Reddit's "prove your humanity" and Cloudflare
Turnstile meet the headless probe, not the real Chrome the session lives in. `probe-all`
skipped every served profile, and there is no adapter for most sites a customer types.

- **A served site is checked through the browser that holds it.** `probe-all` no longer skips a
  served profile that has a session daemon. A CDP daemon answers the probe in its own tab, as
  `status` already did, and now also reports the URL the page landed on. Only a served browser
  with no daemon (a plain-Chrome login view) is still `skipped: served`.
- **Input mode: the probe page's title, in a tab of its own.** A new daemon op, `title_probe`,
  opens a new tab, types the probe URL, reads the settled window title and closes the tab. It
  closes the tab only if it provably opened it. `status` asks only when nobody is driving (no
  handoff, no viewer, no lease). A challenge title gives `challenge`. A sign-in title gives
  `expired` (generic words, or `probe.logged_out_when_title_matches`, never when the probe URL is
  itself a sign-in page). `probe.logged_in_when_title_matches` gives `authenticated`. Anything
  else gives `unverifiable`, or `unknown` if it was never seen signed in. No DOM channel was added
  to input mode.
- **A bot check that meets the check is not "Needs you".** Each signed-in read is remembered in
  `<profile>/.5dive-signed-in` (`<iso> headless|served|input`). A headless challenge on a login
  last read signed in by a served or input browser stamps `unverifiable`, dated by that read, and
  exits 0. A challenge in the owner's own browser, or with no such read, is still `challenge`.
- **Every connected site gets a check.** With no adapter, `status` runs `lib/generic-login.cjs`
  over the page. It reads a Log in / Sign in / Sign up control in the header or nav, a password
  form, or a redirect to a sign-in path as signed out. It reads a header with controls and no
  sign-in as signed in. Anything else stays `unknown`. The page verbs' gate keeps its narrower
  check.
- **Re-check after Done**: `_connect_done` already runs `status` last. For an input site, which
  stays served, that is now a real check through its own window.
- Dashboard: `unverifiable` is a new stamp word in the same `<iso> <word>` shape, so the API is
  unchanged. 5dive-frontend renders it as "Can't check automatically · last seen signed in <age>".
  An older dashboard shows its default, "Not checked recently".
- Harness: `tests/browser_served_probe_unit.sh` has 48 arms, with a fake Chrome and a fake
  daemon (the real `call` client). On 1.29.2, 27 of them are red. `browser_plugin_unit.sh` T39f's
  no-adapter booking.com mutant now reads the measured logged-out header as signed out, through
  the generic check.

### Added — stuck on a captcha, the agent asks the owner and carries on (DIVE-5200 ported from the registry), 1.30.0

DIVE-5200 shipped as browser 1.24.0 in the 5dive-plugins registry copy only (5dive-plugins#140)
and never landed here, so the two copies diverged both ways: the registry had the captcha ask and
none of 1.28–1.29.2, and this repo had those and not the ask. The box converger's floor is a min
over both copies, so it was held at the registry's 1.27.0 and DIVE-5374's sign-in fix could not
reach a box installed from the registry. This release ports the ask, and the registry copy is
synced from this one byte-for-byte (DIVE-5386).

- `5dive browser connect-request <site> --challenge --url=<page>` sends the paired owner
  "<agent> is stuck on a captcha on <site>" with an Open button, on the DIVE-4992 rails (no tap,
  no bind; root mints the link and sends it as code). The page must be an http(s) page of that
  site; root re-checks it, and again at the tap and at Done.
- The browser opens on the stopped page as plain Chrome for the person. Done closes the view and
  serves the page back to the agent, which re-reads it through the profile the check was cleared
  in and carries on without a second ask. `serve --url=<page>` opens a page of the site only.
- Page verbs name the command when a render is titled like a check. 5dive still never solves a
  challenge.
- It sits next to DIVE-5287's input-mode `handoff` in the same privileged `_connect` verb:
  `request`, `challenge`, `handoff`, `tap`, `done`.
- Harness: `tests/browser_connect_request_unit.sh` gains the C1–C17 and H1–H3 arms from
  5dive-plugins 905a394 (127 pass; 27 red against the 1.29.2 binary).

### Fixed — a wedged probe Chrome can no longer hold a login's profile for hours (DIVE-5375), 1.29.2

On chill-gorge (2026-10-01 01:52Z) a status probe's headless Chrome logged "Failed to connect to
the bus" at start and never exited. It held linkedin.com's SingletonLock for 28 hours, every later
probe failed on "SingletonLock: File exists" and stamped `UNKNOWN — chrome did not load the page`,
and the dashboard read "Not checked yet". `--virtual-time-budget` bounds page time only, and the
probe's launch had no wall-clock cap.

- Every one-shot headless launch (status probe, launch check, `shot` and its DOM pass,
  `capture`) runs under `timeout -k 5 <budget + slack>` (`FIVEDIVE_BROWSER_CHROME_SLACK_S`,
  default 30 s), the shape `read` already had. `timeout` owns the process group, so Chrome's
  children are stopped with it.
- A capped probe reports `UNKNOWN (probe timed out …)`, stamps `UNKNOWN — probe timed out` and
  removes a SingletonLock that names the dead pid, so the next probe opens the profile.
- A probe that finds the profile locked by a one-shot headless Chrome (`--headless` plus
  `--dump-dom`/`--screenshot` at this `--user-data-dir`, no debugging channel) older than
  `FIVEDIVE_BROWSER_PROBE_STALE_S` (default 600 s) stops it and its children first. A viewer's or
  served browser (not headless) and the session daemon's (a debugging pipe) are never touched.
- Harness: `tests/browser_probe_timeout_unit.sh`, 19 arms with a fake Chrome that keeps the
  one-instance rule and can hang. The pre-fix tree hangs on T1 until the harness's 40 s cap
  (7 red).

### Fixed — a sign-in made through the viewer survives Done on an input-mode (or warm) browser (DIVE-5374), 1.29.1

On 2026-10-02 the owner signed in to github.com through the viewer on chill-gorge (a `drive=input`
box) and tapped Done 7 s later. The dashboard said "log in again", and no `user_session` was on
disk. DIVE-5286's wait for Chrome's cookie commit ran only for a login view (`login=1`, a
`chrome_pid` in the serve record). On an input-mode box the viewer attaches to the session
daemon's plain Chrome, which has neither, so the stop asked the daemon to go at once and the
daemon SIGTERMed Chrome about 1 s after Done. A SIGTERM drops Chrome's uncommitted batch.

- `viewer-redeem` now writes `.5dive-viewer.admitted` (`admitted_at=<epoch>`) in the profile. The
  revoke that Done runs first overwrites the ticket's state, so this record is what tells the
  stop that a person was in.
- `serve --stop` waits for the cookie commit (same `FIVEDIVE_BROWSER_COOKIE_SETTLE` cap, default
  24 s) when the serve is a login view OR a person was admitted after the serve started,
  whichever process holds the Chrome: a direct Chrome, the input-mode daemon or a warm CDP
  daemon. The wait now runs BEFORE the daemon is asked to shut down. The stop removes the record.
- Only within 60 s of the person leaving (`left_at`, written when the view is taken down — Done's
  revoke does that a second before its stop). An input-mode daemon lives for hours, and a later
  stop (the idle sweep's) must not sit out the cap for a view that ended long ago.
- An agent's own stop of a browser nobody viewed is not held.
- Harness: `tests/browser_input_drive_unit.sh` R11 (the fake daemon now commits a sign-in on a
  timer and loses it on shutdown). The pre-fix tree fails R11a and R11e. A mutant without the
  new key loses the sign-in. Also, the fake daemon now honours `shutdown` on a warm serve, as the
  real one does.

### Added — routines (`act --record`, `replay`) and `snapshot --delta`: the second run costs less (DIVE-5335), 1.29.0

(1.27.0 was held for this entry while it was in review; DIVE-5338 shipped 1.28.0 first, so it lands as 1.29.0.)

The owner asked what the trending browser-agent projects could give our browser (2026-10-01).
Two ideas, copied as ideas and not code: Stagehand's **action caching** and agent-browser's
**`snapshot --delta` / `screenshot --if-changed`**. A daily browser routine (the distribution
team's clicker, a publisher) paid the full snapshot-decide-act loop every day for the same clicks.

- **`act --record=<name>`** keeps the steps of an act that succeeded — the refs (already
  re-derivable role+name locators), the start URL and the `--expect` — and never a typed value:
  fill/type/select values become numbered slots. An act that failed, was not ready or did not
  match `--expect` is not recorded. Input mode refuses `--record` (no DOM to record).
- **`replay <site> <name> [--values=…]`** runs every recorded act as an ordinary `act` (lease,
  scope, login gate, owner's policy unchanged), in one call with no snapshot, and reports its
  model calls. A renamed element gets the executors' existing one re-pick, and a rescued step is
  written back to the routine. A miss nothing can re-pick stops on that act with the re-record
  command; a pay stop is 73 with `--from=<k> --approved=<id>` to resume.
- **`routine ls | show | forget [--from=<k>]`**.
- **A ref whose element the page replaces is found again**, in both step loops
  (`lib/aria.cjs` `onRef`). On en.wikipedia.org a `fill` on the search box loads the typeahead,
  which mounts a new input in its place, and the next `press Enter` on the same ref timed out
  ("element was detached from the DOM"): every record and replay of that routine failed. A step
  now runs in short attempts and, when its marker is gone, re-resolves the same ref and runs
  again — never after a navigation or an action that completed, never for `type`, never for a
  CSS selector, and the owner's check is read again on the element found again. "Again" is the
  same ref; else the one field of the same name in the text-field roles (Wikipedia's comes back
  a `combobox`, not a `searchbox`); else, for `press` only, the focused text field.
- **`snapshot --delta`**: refs added/removed and text lines changed since the seat's last
  snapshot of the site, and no `page.png` when under 1% of its pixels changed. Falls back to
  full on a stale baseline (30 min) or a delta longer than the page. `lib/delta.cjs` (new): a
  PNG decoder on node's zlib, no new packages.
- **Measured**: `tests/browser_routine_bench.sh`, the new `routine-bench` CI job — a fixed
  routine on en.wikipedia.org with real Chrome; it fails unless run 3 makes fewer model calls
  than run 1. The numbers are on the PR.
- **Harness**: `tests/browser_routine_delta_unit.sh` (record without values, replay with zero
  snapshot walks, self-heal write-back, miss, ls/show/forget, input-mode refusal, PNG decoder
  across all five filters, delta through the real verb) with three mutants.

**Considered, not taken** (main's teardown on the row): jev-ultrafast and browser-harness need an
open Chrome debugging port, which the session daemon deliberately does not have; browser-use's
"skills" are this same idea and its stealth is cloud-only; Playwright MCP's snapshots and
persistent profiles we already have; Skyvern is AGPL; steel-browser's anti-bot layer waits for a
count of how often box runs actually hit bot walls.

### Added — a box-level default drive mode: `config drive=input|cdp|auto` (DIVE-5338), 1.28.0

lodar, 2026-10-01: agents should browse in the owner's own plain Chrome by default, with no
automation channel, and hand that same window to the owner when a person is needed. Input mode
(DIVE-5287) did that for one site at a time; this makes it a box setting, so one box can trial it
while every other box is unchanged. (1.27.0 is DIVE-5335's, still in review.)

- **`5dive browser config`** shows the box default; **`sudo 5dive browser config
  drive=input|cdp|auto`** sets it. One root-owned file, `/var/lib/5dive/browser/drive-default`, so
  a seat cannot opt itself back into automation. `auto` removes it: the shipped default.
- **Precedence:** a site adapter's explicit `"drive"` wins (`input` or, new, `cdp`), then the box
  default, then the automated browser. The public profile is never input.
- **A proxied seat falls back, it is not refused.** Under the box default it keeps its proxy and
  the automated browser, and `serve` prints one NOTE line. An adapter's own `input` is still
  refused under a proxy (DIVE-4951), because that site works no other way.
- A site already served the other way switches on the owner's next page verb (as an adapter's
  input already did). A brokered seat follows what the owner serves (the `.offered` marker), so
  after flipping a box, re-serve its sites: `serve <site> --stop && sudo 5dive browser serve <site>`.
- **`tests/browser_input_drive_unit.sh` R10** (15 arms): the default serves an adapter-less site as
  input, routes `shot` to the screen and refuses `read` by name; an adapter's `cdp` wins; the proxy
  fallback and its note; root-only; `cdp` restores the automated browser. `INPUT_DRIVE_SKIP_LIVE=1`
  runs the routing arms without real Chrome.

### Added — the owner's authenticator seed: `run` passes an authenticator-app 2FA prompt itself (DIVE-5336), 1.26.0

lodar, 2026-10-01: a box agent should get past a two-factor login on its own instead of stalling
until a person taps a code in, and "the secret should never touch our api".

- **`5dive browser totp set|import|status|fill|forget <site>`.** `set` takes the seed (base32 or
  an `otpauth://totp/` link) from stdin only, and writes `.5dive-totp` 0600 inside the site's 0700
  profile. `sudo … totp import` moves a seed the owner pasted on the one-time secrets link
  (DIVE-5319; connector `browser-totp`, key `TOTP_<SITE>`) into the profile and removes the
  store's copy. `totp` joins the set of verbs root keeps, for `import` only.
- **`run` on a `CHALLENGE`** tries the seed first: the executor, or the warm session for a
  brokered seat, types the RFC 6238 code into the code box on the site's own host, and the
  RE-PROBE decides. No seed, no field, a foreign host, or a page that is still a challenge
  after the code: the old stop, word for word.
- **`lib/totp.cjs`** is shared by `bin/driver-playwright` (`mode: "totp"`) and
  `bin/session-daemon` (`op: "totp"`). Their result names the field, never the code.
- **`tests/browser_totp_unit.sh`** (new CI step, after `npm install` of the pinned
  playwright-core): RFC vectors, the host and field rules, the verbs, `run` with a fake driver,
  the real `sudo` import, and a LIVE arm against a local TOTP-gated site in real Chrome. That arm
  greps for the seed and every accepted code and expects 0.

### Added — input mode: agents act in plain Chrome through the screen, keyboard and mouse (DIVE-5287), 1.25.0

tiktok.com would not render for the automated browser: blank `/foryou`, no challenge, no
sign-in form, while plain Chrome on the same profile, box and IP rendered it (chill-gorge,
2026-09-30). The owner approved a mode that uses no automation channel at all, and asked that
**a person can be called in at any time, on the same window**. That is what this is: "a real
browser for agents".

- **`"drive": "input"` in an adapter** makes that site input mode. Any site can opt in, and
  `adapters/tiktok.com.json` ships with it. Sites that work under the daemon keep the fast CDP
  path, unchanged.
- **`session-daemon --input`** launches plain Chrome (the DIVE-5203 login-view flags; it refuses
  `--remote-debugging-*`, `--enable-automation` and `--headless` even from the operator's extra
  args) and drives it through the X display with **`lib/x11.cjs`**. That is a small pure-Node
  X11 client: XTEST pointer, wheel and keys (`isTrusted` in the page; non-ASCII typed through a
  spare keycode, as xdotool does), `GetImage` to PNG, and the window title. No new packages.
- **Same door**: the broker socket, lease, `SO_PEERCRED` attribution and audit log are
  unchanged. Every input step re-checks the lease, a live viewer, and an open handoff.
- **Verbs**: `shot`/`snapshot` return the screen plus the page title. `act` takes pixel steps
  (`click move type press scroll goto wait`). `tree`/`read`/`links`/`run` and selector steps are
  refused by name, with the verb to use instead.
- **The owner's policy** applies to a step's declared `"kind"` (pay/publish/send/delete). A kind
  set to `ask` stops with 73 before anything runs. There is no DOM to read a button's label from,
  so this is declared, not detected, and the docs say so.
- **`handoff <site>`**: agent input is suspended at the daemon, and the owner gets the Connect
  button ("needs you to take over") onto the same window. `viewer` and `serve --login` leave an
  input browser alone, and Connect-Done closes the handoff instead of stopping the browser.
  `handoff --wait` returns when they are done, including when their view ended after they were
  in it.
- **The hard stop stays.** A challenge whose title says so stops an act between steps (75, with
  the handoff command). TikTok's in-page slider does not change the title, so the skill tells the
  agent to hand over the moment it sees one. `status` reads the title and never navigates the
  window.
- A proxied seat is refused input mode (plain Chrome cannot carry a proxy login, DIVE-4951).
- **Input is held until the page takes it, and a lost click fails the step** (quinn, iteration
  1: a CI run sent the harness's click and text, got rc=0, and nothing reached the page).
  Measured on Chrome 153 / Xvfb: input sent within ~100ms of a page's title appearing is
  dropped by Chrome (no mousedown, no keydown), with X focus on Chrome's window all along. It
  is the page coming up, not focus. Forcing focus to PointerRoot or to no window did NOT
  reproduce it. So (1) every input step waits until the title has been quiet 500ms
  (`FIVEDIVE_BROWSER_INPUT_QUIET_MS`, capped at 8s for pages that retitle forever). (2) The
  daemon says `ready` only once Chrome's window is viewable and holds an explicit, confirmed
  keyboard focus. (3) A click checks that the window under the pointer is the browser's before
  the button goes down, and that the browser holds the focus after. Either failure stops the
  plan non-zero instead of returning 0. (4) Keys re-take the focus for the browser, confirmed,
  or fail. `title` now reports `focused` and `quiet_ms`. A step that navigates, then another
  sent before the new page even retitles, can still race. Split such plans, or put a `wait`
  between them.

**Choices, and the alternatives not taken** (main's 15:15Z design note asked for this record):

- *Read through a 5dive Chrome extension* (main's preferred hybrid). Blocked: branded Google
  Chrome ignores `--load-extension` since 137. On Chrome 153 here, both the flag and
  `--disable-features=DisableLoadExtensionCommandLineSwitch` load nothing (measured: no entry in
  the profile's extension settings). The installs left are (a) box-wide enterprise policy
  (`ExtensionInstallForcelist` with a self-hosted CRX). It is root-only, applies to every Chrome
  on the box, shows "managed by your organization", and needs an update server. (b) The owner
  clicks "Load unpacked" once in the viewer, which is a manual step on every box. (c) Editing
  Secure Preferences, which is tamper-protected and is malware's technique. None fits a release
  that must work on every box. The input layer is built so a reader can be added later without
  changing the act side.
- *`chrome.debugger` in an extension*: that is CDP and shows the "being debugged" bar. Not taken,
  per the design note.
- *Chrome's accessibility tree over AT-SPI* (text and element boxes with no CDP and no
  extension): a real candidate for the next step. It needs an accessibility D-Bus and
  `--force-renderer-accessibility` per serve, so it is its own row.
- *xdotool / ImageMagick*: two more packages on every box for about 400 lines of protocol.
  Not taken.
- *Chrome for Testing or Chromium* (they still honour `--load-extension`): a different binary
  than the one the owner signed in with, on the same profile. Not taken.
### Fixed — a login made just before Done is no longer lost (DIVE-5286), 1.24.2

A person signed in to GitHub through the dashboard's Connect, pressed Done 13 seconds later, and was
told to log in again. Every agent then refused the site as logged out. Chrome batches cookie
changes and commits them to disk ~30 s after the first change of a batch, and its SIGTERM shutdown
does not reliably write the pending batch. So a sign-in less than ~30 s before Done was lost
(13 s, 8 s and 9 s on the same box; 20 s ones survived).

- `serve --stop` of a login view now waits for Chrome's next cookie commit before it stops Chrome:
  it watches the Cookies DB for a write after the stop was asked for, and every change made
  before that is in it. The wait is capped at `FIVEDIVE_BROWSER_COOKIE_SETTLE` seconds (default
  24), so the dashboard's Done (revoke, stop and status in one request the proxy cuts at 30 s)
  still answers. What the cap gives up: a sign-in under ~6 s before Done can still be lost.
  Measured through `serve --login`/`--stop` with the real Chrome: a cookie set 8 s before the stop
  was kept 5/5 (stop ~22.5 s), and 0/5 without the wait; set 3 s before, the cap cuts in and it is
  lost (0/3), which is the residual above.
- An agent's plain Chrome is not held: only a login view (`login=1`) waits.
- Then it sends Chrome SIGTERM and waits for it to exit before it stops the display (bounded at
  `FIVEDIVE_BROWSER_STOP_GRACE`, 10 s, then SIGKILL). It returns only once Chrome is gone, so the
  status check Done runs next no longer races the dying browser for the profile. That race was the
  "Failed to create SingletonLock: File exists" that `ls` printed as UNKNOWN.

### Fixed — a signed-in Reddit no longer reads as a security challenge (DIVE-5285), 1.24.1

1.24.0 is DIVE-5200 (an agent stuck on a captcha asks the owner), which shipped in the registry
first (5dive-plugins#140) and reached this repo in 1.30.0 (DIVE-5386). This entry is numbered after
it so both repos name the same fix with the same version.

Every agent reading a connected, signed-in Reddit was told "reddit.com is presenting a security
challenge" and stopped. The reddit adapter probes `/login/`, and that page carries Google's
invisible reCAPTCHA (`<textarea name="g-recaptcha-response">`) whether or not the session is
signed in. The probe checks for a challenge first, and the generic challenge list matches bare
`g-recaptcha`, so a healthy session was read as a challenge. The browser launch and the IP were
not involved.

- `adapters/reddit.com.json` now has its own `challenge_when_dom_matches`: the generic list without
  `g-recaptcha`, plus the words of Reddit's own block pages ("Prove your humanity", "blocked by
  network security"). A signed-in `/login/` reads `authenticated`, a signed-out one `expired`, and
  Reddit's real interstitial is still a challenge.
- The generic default is unchanged. A site with no marker of its own still names a reCAPTCHA page
  a challenge.
- A box that worked around this with a seat copy at `<profile-root>/<seat>/.adapters/reddit.com.json`
  can delete it once 1.24.1 is installed. The seat copy wins over the shipped one until then.

### Fixed — a person signs in through plain Chrome, so Google stops refusing the login (DIVE-5203), 1.23.2

Connect google.com, and every site's "Sign in with Google", was refused whatever the person did:
the view showed the warm serve, which is the session daemon's Playwright launch
(`--remote-debugging-pipe`), and Google refuses a sign-in typed into a browser under automation
control. It was not the box IP: the same refusal on two boxes, and plain Chrome on the same profile
signed in first try.

- `viewer` re-serves a warm browser as plain Chrome (no `--remote-debugging-*`) before it mints.
  Every person's view goes through it: the dashboard's Connect, the Telegram Connect tap and a
  hand-minted link, so no caller has to know the rule.
- New `serve <site> --login` does the same on purpose. `auth` on a display-less box and the Connect
  tap use it, so they do not start a daemon only to stop it again.
- Once nobody is in the view, the next plain `serve` swaps the login browser back for the warm
  session, so a brokered seat is not left behind a browser nobody is using. A box that cannot start
  a daemon keeps the plain one rather than restarting it for nothing.
- A seat with a proxy set keeps the daemon for the login, because plain Chrome cannot carry the
  proxy's login and would sign in from the box's own IP (DIVE-4951). It says so on stderr.

### Fixed — Chrome's temp files no longer pile up in /tmp (DIVE-5190), 1.23.1

A customer box had 3.0G in /tmp that was nothing but Chrome: 256 `.com.google.Chrome.*` files
(~9.7M each) and `scoped_dir*` directories (~52M each). Chrome writes both into `$TMPDIR` and
removes them only on a clean close, and most of this plugin's browsers end with a kill (a timeout,
an evict, a stopped serve), so every one of them left its set behind and nothing swept /tmp.

- Every `5dive browser` launch now gets its own `TMPDIR`, `~/.cache/5dive-browser/tmp/<pid>.<start>`
  (the seat's own home, never /tmp), and every Chrome it starts inherits it: the headless probes,
  the Playwright driver, the session daemon and `auth`'s window.
- It is removed when the command exits, including through a verb's own exit cleanup and after an
  error. A launch that was killed outright is swept by the next launch, which removes every
  directory whose owning process is gone. The process start time is part of the name, so a
  recycled pid does not keep a dead launch's files alive, and a live owner is never touched.
- A served browser (the session daemon, or plain Chrome when there is none) outlives the command
  that started it, so it gets a directory of its own, named for its own pid; it stays while that
  browser runs and is swept by the first command after it stops.
- Where no private directory can be made (no home owned by this user), the launch goes ahead with
  the `TMPDIR` it was given, as before. `FIVEDIVE_BROWSER_TMP_ROOT` moves the root.

`tests/browser_tmpdir_unit.sh` grades it through the real `bin/browser` with a fake Chrome that
litters `$TMPDIR`, and runs in CI.

## Released

### Changed — paying asks by default on a customer box; a third preset, `standard` (DIVE-5148), browser 1.23.0

**Before:** the default was `yolo` — pay, publish, send and delete all ran and were logged
(DIVE-5006, which fixed an owner with no dashboard and no shell being unable to approve anything).
Since then the owner-ask relay turned an ask into one tap in Telegram, so the stop is cheap again.
A page the agent reads can carry hidden instructions; a post or a delete can be undone or
apologised for, and money charged to a customer's card cannot.

**Now:** the default is per kind — `{"pay":"ask","publish":"allow","send":"allow","delete":"allow"}`.
On a box with no policy file, a pay step stops with exit **73** and an ask carrying the payee, the
amount and a screenshot; publish, send and delete run and are logged to `allowed.jsonl` as
`allowed_by: "default"`, and stderr says `ALLOWED (default standard)` (it said `default yolo`).

- **`sudo 5dive browser approvals policy set standard`** is a third preset, this default, beside
  `yolo` (all four allow) and `careful` (all four ask). `set standard` followed by
  `set pay=allow` is `yolo` again.
- **`approvals policy --json`** reports `"mode":"standard"` for exactly this map, then `yolo`,
  `careful` or `custom` as before, so the dashboard switch can show it.
- **Unchanged:** an explicit owner setting still wins over the default; only the owner changes the
  policy (a seat's `set` is still refused, 77); a policy file the granting uid does not own is
  still ignored and the default applies; every allowed step is still logged with its payload and
  its screenshot.
- Our own boxes stay `yolo`: `sudo 5dive browser approvals policy set yolo`.
- Harness: T36b/T36c/T36d and T37 grade the new default, one arm per preset (`standard`, `yolo`,
  `careful`), and T37e's mutant is now the old all-`allow` default — with it, a pay runs.

### Fixed — a plain Enter in a chat composer with no form is a send, and asks under `careful` (DIVE-620), browser 1.22.5

**Before:** under `send=ask`, on Telegram Web, `act` with `fill` on the message composer
(`div.input-message-input[contenteditable=true]`) and then `press Enter` delivered the message:
`step 2 (press) ok`, `verified`, exit 0, and no ask. `stepRisk` read a plain Enter as "submit the
element's form" and looked for that form's submit button. A chat composer is a `contenteditable`
with no `<form>` around it, so the label was `''`, `''` classifies as nothing, and the step ran.
Ctrl/Cmd+Enter was already a send without a label; a plain Enter was not.

**Now:** a plain Enter whose target has no form is `send`, without reading a label, when the
target is a composer: `contenteditable`, `textarea` or `[role=textbox]`. When the target is not a
composer, the focused element is checked the same way. Under `careful` the step stops with exit 73
and a send ask that carries the message's first line. What keeps running with no ask: a plain Enter
in a formless search box (`input[type=search]`, a plain text input), Shift+Enter (a composer's new
line), and a composer inside a form, which still follows that form's submit button.

### Fixed — a `--wait-for` timeout reads as a timeout, and `served` lists the public browser (DIVE-4991), browser 1.22.4

**Before:** a cold `read --wait-for` (nothing served) on a real page said `--wait-for was not
honoured: the served browser for this profile runs a session daemon from before --wait-for
existed … Restart it`, whether the element timed out or arrived. No daemon was in the path. The
executor printed its reply and called `process.exit`, and `read` takes that reply through a pipe,
which carries the first 64 KB and drops the rest. A real page's node list is past 64 KB, so the
JSON arrived cut, no `wait_for` could be read from it, and the only branch for a missing
`wait_for` was the old-daemon one. Restarting changed nothing. Separately, `5dive browser served`
printed nothing while a `_public` browser ran, although `serve _public --stop` found it and
stopped it.

**Now:** the executor waits until its reply has been flushed before it exits, for `tree` and
`snapshot` alike, so the reply arrives whole at any size. A timeout says
`--wait-for=<target> did not appear within <ms> ms` (76). A daemon with no `wait_for` in its reply
is still named as the old daemon, with the restart (76). A cold capture with no verdict says the
`--wait-for` *was not answered*, names the capture, and blames no daemon (76). `served` lists
`_public` while it runs; `ls`, `status` and `probe-all` still skip it, because it is not a login.

### Fixed — a signed-out Telegram Web profile no longer probes `authenticated` (DIVE-4998), browser 1.22.3

**Before:** the `web.telegram.org` adapter's logged-in marker was `class="[^"]*chatlist`. The K
app's signed-out render now carries `class="tabs-tab chatlist-container sidebar …"`, and
`[^"]*chatlist` matches the `chatlist` inside `chatlist-container`. So `status web.telegram.org`
read a signed-out profile as `authenticated` on the first poll, and every acting verb then ran on a
dead session.

**Now:** the marker is `class="([^"]* )?chatlist[ "]`: `chatlist` as a whole class name, at the
start of the attribute or after a space, and followed by a space or the closing quote. On the
2026-09-25 renders it matched 0 on both signed-out renders, the cold render and the curl'd shell, and
1 on the live signed-in render (`class="chatlist virtual-chatlist"`). A signed-out profile whose
page shows neither marker now reads `UNKNOWN`, and the acting verbs refuse it. The README's
shipped-adapter row carries the new marker. The adapter's `_comment` drops its 2026-09-21 "0 on a
logged-out render" note, which no longer holds, and names three fallback markers that measured the
same way: `id=folders-sidebar`, `id=new-menu` and `id=folders-tabs`.

### Fixed — a send's ask lists each recipient once, as the chip's address, browser 1.22.2

**Before:** the ask for a one-recipient Gmail send read `to user@example.comLoading...,
user@example.com`. Recipients were read from every chip and every To/Cc/Bcc field, and a field
with no `email` attribute was read by its text. Gmail's To field is such a field, and its text is
the chip's glued to the hover card's. No address pattern can split `com` from `comLoading`, and the
chip's clean copy was kept beside it, so the owner was asked to approve a send to an address that
does not exist.

**Now:** when the form holds any `[email]` node (a recipient chip), the recipients are those
attributes and the fields' input values only; a field's text is read only on a page with no
`[email]` node at all. The same send asks for `to user@example.com`.

### Fixed — a step that fails fails `act`, whatever `--expect` matched, and the failure names the step (DIVE-4990), browser 1.22.1

**Before:** `act --expect` was graded on the page alone. Measured at 1.13.0 on booking.com: step 2,
`click ref=button/Decline`, failed with "matches nothing on this page", and the run printed
`verified: the page after the steps matches --expect` and exited 0, because the expected text was
on the page before any step ran. `--json` said `"verdict":"verified"` next to a non-zero
`executor_rc`. Without `--expect`, the failure read "a step failed (the executor exited 1)" and did
not say which step.

**Now:** a step that fails fails the run, whatever --expect matched. The order is `step_failed` >
`not_ready` > `not_verified` > `verified`; `verified` needs the executor's exit 0 and the match.
The failure names the step:

```
act: step 2 (click ref=button/Decline) failed: ref=button/Decline matches nothing on this page — the run is NOT verified, whatever --expect matched. Some steps may have run; look at …/page.png before retrying.
```

- `--json` adds `failed_step: {index, op, selector, error}` (null unless the verdict is
  `step_failed`); `selector` is null for a `goto`.
- Both step loops (the cold `driver-playwright` and the warm `session-daemon`) print the failed
  step as one `5dive-step-failed: {…}` line on stderr, from `lib/aria.cjs`.
- `run` is unchanged: its verify is an out-of-band re-read of a different URL, and a red executor
  with a live artifact reads verified there by design — a failure there is what double-posts on a
  retry.

### Added — a redirected landing is said, and a cold run is retried once in the served browser (DIVE-4991), browser 1.22.0

**Before:** a cold `act` or `run` that the site redirected said nothing about it. Measured
2026-09-26 on booking.com: three different search URLs, one copied from a real browser with
`dest_id`, `label` and `ac_meta`, landed on `https://www.booking.com/city/pt/lisbon.html`; the
next `wait_for [data-testid=property-card]` failed with "a step failed (the executor exited 1)",
and nothing said a redirect had happened. A fourth landed on `searchresults.html?nflt=…` with the
dates and `ss` dropped. The same URLs after `serve booking.com` landed on the results (477
properties found).

**Now:** after every `goto` (the `act` URL included) both executors compare the URL asked for with
the one the page is on, and a redirect prints:

```
redirected: https://www.booking.com/searchresults.html?ss=Lisbon&… → https://www.booking.com/city/pt/lisbon.html (path /searchresults.html became /city/pt/lisbon.html); retrying once in the served browser
```

- A redirect is a changed path, or more than half of the requested query keys missing. A moved
  fragment, a trailing slash, or the same path with params only added is not one.
- On the cold executor, while nothing but a `goto` has run, the run stops there and `act` or `run`
  takes the whole step list once through the served browser: served if nothing was, and stopped
  afterwards only if this run started it. That run's result is the verdict. Never twice.
- After a click, fill or any other step, the line alone, and nothing is replayed. The served
  executor prints the line and has nothing to retry in. No session daemon or no Xvfb on the box
  (or `FIVEDIVE_BROWSER_NO_DAEMON=1`): the line alone. A served browser that will not start: the
  run stops at the redirect and says why.
- Optional, where reflex is configured: `5dive reflex landing <site> --state=<file> --json` is
  asked whether the landing answered the request (requested and landed URL, title, at most 300
  characters of visible text — page text leaves the box only under that opt-in). `generic_page`
  or `bot_block` is a redirect, `login_wall` fails with `log in first: 5dive browser auth <site>`,
  `answered` at 0.9 or more overrides a base redirect, and an error leaves the base verdict.
  `FIVEDIVE_BROWSER_REFLEX_TIMEOUT_MS` bounds it (default 60000). With no reflex nothing is asked.
  The 5dive CLI has no `reflex landing` verb yet; until it ships, the call errors and the URLs
  decide, so this tier changes nothing today.
- Harness T41: a changed path retried once in a served browser the run starts and stops (`act`);
  dropped keys retried (`run`); added params, a moved fragment, a trailing slash and exactly half
  the keys not; no replay after a click; reflex's login_wall (cold and warm), answered over and under 0.9,
  generic_page, and an error; no reflex, no served browser, a served browser that will not start; one retry when the served run
  is redirected too; the landing check removed from both loops as the mutant.

### Added — a step whose ref matches nothing is retried once, on the element reflex or a name match picks, browser 1.21.0

**Before:** a step whose `ref=` matched nothing failed with `ref=… matches nothing on this page`,
and the agent had to snapshot, read the refs and send the whole `act` again. Measured on a hotel
site: step 2, `click ref=button/Decline`, failed while the consent banner's button was on the page
under another accessible name. `5dive reflex pick-ref` could already pick a step's element off a
page tree, and nothing in the browser called it.

**Now:** a step whose ref matches nothing is retried once, on the element reflex picks at
confidence 0.9 or more, and the output says so:

```
  step 2: ref=button/Decline matched nothing; reflex picked ref=button/Decline all (conf 0.99); retried: ok
```

- `click`, `fill`, `type`, `select`, `press`, `wait_for` and `upload`, in both executors (a cold
  `act`/`run` and a served browser). pick-ref gets the page's interactive refs, the op (`fill` for
  a `type`), and what the step is for: a new optional step field, `"intent"`, or else the ref's
  role and name (`button named Decline`). A value goes as `{value}`: pick-ref never shows the model
  the value, and a command line is readable by every seat on the box.
- Reflex answering `none`, or under 0.9, is an answer: no retry, and the failure names it
  (`Reflex suggested ref=… at confidence 0.62, under 0.9, so it was not retried.`).
- Without reflex, or when reflex errors: the ONE element of the same role whose accessible name
  equals the ref's ignoring case and outer whitespace, contains it, or is contained in it
  (`name match picked ref=…`). Two such elements, or none, and the step fails exactly as before.
- A step that pays, posts, sends or deletes is never retargeted: read from the ref's own name, the
  picked element's live label and pick-ref's `review_required`. The owner's yes, and the policy
  that lets a kind through, cover the step as written. It fails as before and names the suggestion.
- One retry per step, and only for a `ref=` miss: a CSS selector that matches nothing still times
  out. A first-step miss that is not retried is still "nothing ran" (70).
- Reflex is reached as `propose` reaches it: `_reflex_cli` now looks for the verb's own grant,
  `sudo -n /usr/local/bin/5dive reflex pick-ref`, and uses the plain CLI without it. The standard
  seat sudoers of 5dive 0.54.0 grants no `5dive reflex` verb (not `login-marker` either), so on
  such a seat the root-only key is unreadable and the name match decides; the grant is 5dive's.
- Harness: T40 (reflex's pick retried, cold and warm; the four never retargeted by name, label,
  `review_required` and name match; under 0.9 and `none`; no pick-ref call without reflex; one
  retry; the name match with one, two and no candidates; the retry removed as the mutant).

### Added — a booking.com adapter (a login probe and two dated searches) and google.com's login probe, browser 1.20.0

**Before:** no booking.com adapter shipped, and the shipped google.com adapter had no `probe`.
`status booking.com` and `status google.com` read `UNKNOWN` whether the profile was logged in or
not, so `run` refused on both — `run google.com send` included, until someone wrote a probe into
the seat's `.adapters/` — and a dated hotel search meant writing an adapter by hand.

**Now:** `status booking.com` and `status google.com` read `session expired — human action
required` (exit 75) on a logged-out profile and `authenticated` on a logged-in one, so `run
google.com send` works on a logged-in box with nothing written by hand. booking.com also ships two
actions that search by date:

```bash
5dive browser serve booking.com
5dive browser run booking.com hotels --city=Lisbon --checkin=2026-10-14 --checkout=2026-10-15 \
                                     --adults=2 --rooms=1 --max_eur=120
# -> step 1 (goto) ok / step 2 (wait_for) ok, then NOT VERIFIED (exit 1, see below);
#    the result page lists the hotels, cheapest first
```

- `search`: every property type under `--max_eur` per stay, cheapest first. `hotels`: the same,
  hotels only (`ht_id=204`) rated 8+ (`review_score=80`). Both take `--city --checkin --checkout
  --adults --rooms --max_eur`, dates YYYY-MM-DD; `--city` is the name as a person types it, no
  dest_id needed.
- Run `5dive browser serve booking.com` first. A cold `act` or `run` of any results URL, even one
  copied from a real browser, is redirected to an undated city page; the same URL through the
  served browser returns the dated results. Measured 2026-09-26: `ss=Lisbon` alone, 477 properties
  found; `hotels` for Lisbon 14–15 Oct, 2 adults, at most 120: 25 hotels, the cheapest EUR 95.
- Expect NOT VERIFIED. The verify is a public fetch of the results URL, and Booking answers a
  public fetch with a different page, so it cannot re-read the results. Read the result page.
- Both probes were measured on both halves, and both markers are regexes (`grep -iE` cold,
  `RegExp` in the served browser):
  - booking.com probes `/` for `data-testid=["']?auth-link-in-view`: 1 match in each of two
    logged-out renders, 0 logged in. Not the Sign in link's href,
    `account.booking.com/auth/oauth2?client_id=`: as a regex `2?` is an optional 2, it matched 0
    logged-out renders, and every logged-out profile would have read `authenticated`.
  - google.com probes `https://accounts.google.com/signin/v2/identifier` for its title,
    `<title>Sign in - Google Accounts</title>`: 1 match logged out, 0 logged in. Not
    `myaccount.google.com`: logged out, that is a marketing page with 0 matches.
- A seat file of the same name in `.adapters/` still wins over the shipped one.
- Harness: T39 (both files, both markers as regexes against both halves, `status` through the real
  probe, the tree before this change as the mutant); T35g now runs the shipped google.com file on a
  logged-out profile.

### Added — a `type` step: key by key, for search boxes and autocompletes that open on keystrokes, browser 1.19.0

**Before:** `act` and `run` could only `fill` a text box, and `fill` puts the value in with one
input event and no key presses. A search box whose suggestion list opens on typed keys never
opened. Measured on a live hotel search with nothing connected, at 1.18.0: `fill` "Lisbon" and
then Search went to the results for an empty city ("0 properties found"); `fill` "Lisbo",
`press` "n" and a `wait_for` the suggestion timed out after 30 s.

**Now:** a `type` step clears the field, as `fill` does, and types the value one key at a time,
so the suggestion list opens and a `wait_for` and a `click` pick from it:

```bash
5dive browser act <url> --steps='[{"op":"type","selector":"ref=textbox/Where to?","value":"Lisbon"},
                                  {"op":"wait_for","selector":"text=Lisbon, Portugal"}]'
```

- Use `type` for search boxes and autocompletes that react to keystrokes, and `fill` for plain
  inputs.
- `{"op":"type","selector":…,"value":…}` takes an optional **`delay_ms`** between keys: whole
  milliseconds, default 50, at most 1000. Anything else is refused before the browser opens
  (69: nothing ran).
- `act` and adapter steps both take it: the vocabularies are now
  `goto fill type click wait_for select press` and, for an adapter,
  `goto fill type click wait_for select upload press`. Its value takes `{key}` arguments exactly
  as `fill` does, and a missing one is refused the same way.
- It is not one of the owner's four: typing runs without asking, under `careful` too. The click
  that sends is still the step that asks.
- A line break in a `type` value is refused before the browser opens (69: nothing ran), from a
  `{key}` argument too: typed, it is the Enter key, which sends the form without the owner's
  policy reading it. Press Enter as its own step.
- The step's bound is the step timeout plus the typing time, so a long value is not cut off
  half-typed.
- Both step loops (`driver-playwright`, `session-daemon`) run it through one function in
  `lib/aria.cjs` (`typeKeys`, `locator.pressSequentially`).
- Harness: T38 (a stub search box whose suggestions open only on keydown: `type` opens it and
  `fill` does not, cold and warm; `type` in `act`, on a ref, and in an adapter step; `{key}`;
  `delay_ms`; not one of the owner's four; a line break refused, cold and warm; a mutant that
  maps `type` to `page.fill` in both executors and goes red).

### Changed — approvals default to yolo: pay, publish, send and delete run and are logged; presets `yolo`/`careful`, a `mode` field (DIVE-5006), browser 1.18.0

**Before:** every pay, publish, send and delete step stopped in front of the button with exit 73
until the owner said yes. Measured on a box at 1.17.0: an owner with no dashboard and no shell
could not approve, could not relax the policy, and every send stopped dead.

**Now:** on a box with no policy file, all four run. Each step is still written down in the seat's
`allowed.jsonl` with its payload and the act's screenshot, as `allowed_by: "default"`, and the
agent's stderr says `ALLOWED (default yolo): <kind>, step N, …`. `run google.com send` sends and is
verified in Sent without an approval id.

- **`sudo 5dive browser approvals policy set careful`** puts the stop back for all four (exit 73,
  the ask, the owner's `approve`, exactly as before). **`set yolo`** makes all four allow again.
  **`set <kind>=ask|allow`** still changes one kind, on top of either preset.
- **`5dive browser approvals policy --json`** (and `FIVEDIVE_JSON_MODE=1`) adds `"mode"`: `yolo`
  (all four allow), `careful` (all four ask) or `custom`, computed from the four, never stored. The
  text form prints a `mode` line.
- Only the owner changes it: a seat's `set yolo`, `set careful` or `set <kind>=…` is refused (77)
  and writes nothing. A policy file the granting uid does not own is ignored and the default
  applies, so a seat can neither loosen nor tighten it. A kind the file leaves out, or gives any
  value other than `ask` or `allow`, is the default too.
- A policy file written by 1.17.0 keeps what it says: an owner who ran `set send=allow` there has a
  file with the other three at `ask`, and keeps them until they `set yolo`.
- A preset or `<kind>=…` without `set` is now a usage error (64) rather than a silent read.
- The step loops (`driver-playwright`, `session-daemon`) are unchanged: both already run whatever
  `allow_kinds` the front door sends, and the front door now sends all four by default.
- Harness: T37 (no-file default for `act` cold and warm and for `run google.com send`, `careful`,
  `mode`, the seat refusals, and a mutant that restores the `ask` default); the arms that grade
  the stop (T32e, T32h, T35, T36) now run under `careful`.

### Added — reflex drafts a login check, the owner approves it, drift flags one that decayed (DIVE-4997), browser 1.17.0

A site with no adapter cannot probe `authenticated`, so every page verb refused it until someone wrote
a marker by hand. DIVE-4931 measured `5dive reflex login-marker` on a real box and let it out of
shadow on three conditions: a signed-in render so both halves are verified, the owner sees every
candidate and not only the pick (confidence was 0.20 to 0.61), and challenge and no-candidate
refusals stay refusals. This release is those conditions, built into the browser for every agent.

- **`5dive browser propose <site> [--url=] [--spa]`** (the login's owner; a brokered seat is
  refused). It runs `capture`, refuses a challenge page on EITHER half and a profile that is not
  logged in (both renders the same page), then asks `5dive reflex login-marker --json`, retrying with
  `--spa` when the signed-out half has no candidates. The proposal and its renders are stored PENDING
  in the seat's `.adapters-pending/` (0700). Nothing reads adapters from there. A proposal with no
  candidate is never stored.
- **The probe starts one on its own.** When a login has no adapter (the status the dashboard reads
  after Connect, or a page verb's gate), a background `propose` runs (inline under `probe-all`, whose
  systemd unit would kill a background child when it exits), at most once per
  `FIVEDIVE_BROWSER_PROPOSE_RETRY_S` (6 hours) per site, never again for a site the owner rejected,
  and only when `reflex status --json` says `configured:true`. The status line then says a login
  check is waiting. `FIVEDIVE_BROWSER_AUTO_PROPOSE=0` turns it off.
- **`sudo 5dive browser adapters pending [--json]`** shows reflex's pick AND every candidate, with its
  counts on each half. **`adapters approve <site> [--marker=mN] [--signed-in=mN]`** takes the pick or
  any other candidate. It is refused with no signed-in render, or on a challenge render. It re-counts
  the chosen marker on the stored renders with the probe's own `grep -iE`, and never trusts the counts
  the file claims. Then it writes the seat's `.adapters/<site>.json`, AS the seat and never over an
  existing file. It never writes the package's `adapters/`. The `_comment` and `_reflex` record that
  reflex proposed it, who approved it, when, and the counts. The renders are deleted. **`adapters
  reject <site>`** deletes the proposal. Approve and reject are the box owner's: root, and not an
  agent seat's sudo (DIVE-4982's rule).
- **`5dive browser adapters drift [<site>] [--json]`** re-captures each of this seat's logins that
  has an adapter. It flags DRIFTED any marker that stopped classifying both halves, which is the
  case of the shipped Telegram marker that matched the static shell (DIVE-4931/4998). It writes
  `<seat>/.5dive-drift.json` and exits 1 on a drift. `probe-all` runs it at most once per
  `FIVEDIVE_BROWSER_DRIFT_EVERY_S` (a day) and prints a drift, never failing the timer for it.
  `FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0` turns that off.
- Harness: `tests/browser_reflex_propose_unit.sh`, a new CI step.

### Added — the agent asks, the owner taps Connect in Telegram, no dashboard (DIVE-4992), browser 1.16.0

An agent that needed the owner logged into a site had nothing it could send. The viewer link needs a
bind that only the dashboard's session could register, so the agent walked the owner through
Connected sites by hand. lodar's Booking.com run on 2026-09-25 hit exactly that.

- **`5dive browser connect-request <site> --reason=<why>`**: the agent's verb. It hands the request
  to root, which mints a one-time code, keeps only its sha256, and sends the seat's paired owner a
  Telegram message with a **Connect <site>** button carrying the code. The seat never holds the code
  before the tap. A request binds nothing.
- **`_connect` (root, `sudo -n 5dive browser _connect`, parameters NUL-separated on stdin)**: `tap`
  re-checks the code, that the tap came through the seat whose bot carried it, and that the tapper
  is that seat's paired owner. Then it does what the dashboard's Connect does, on the box: serve
  (auth first when there is no profile), a viewer with a fresh 128-bit bind, and the bind registered
  with shelld over loopback with the connectord token. It prints the one-time URL for the Telegram
  plugin to send as code, plus a Done code. `done` revokes the view, stops the browser, and probes.
  A refused tap (wrong person, wrong seat, made-up code) does not burn the owner's button. Every
  code is one-shot.
- The control plane is not involved, so zero standing access (DIVE-462) is untouched. The
  automation token is not used.
- **Limits of this release:** only Claude Code's Telegram bridge relays the tap. Any other runtime
  is refused up front instead of getting a dead button. A standard-tier seat has no grant for
  `_connect` yet and is told to use the dashboard. A root-all seat could do all of this without the
  owner, as it always could.

### Added — the approval ask shows the payload, the owner sets a policy per kind, and a seat cannot approve itself (DIVE-4982), browser 1.15.0

- **Before:** a Gmail send stopped with 73 and the ask read `"Send (Ctrl-Enter) Send". OK?`. That
  is the button, with U+202A/U+202C bidi marks round the shortcut, with no recipient, subject or text. The only way to say yes
  was `sudo 5dive browser approve <id>`, which an owner on Telegram cannot run. An agent seat ran it
  on its own ask and was granted (`approved_by: agent-…`), because a seat's `sudo 5dive` is root.
- **After:** the ask reads `I am about to send a message on <site>: to ann@…, bob@… · subject "Q3
  numbers" · "Hi both, figures attached". OK?`. When the 5dive CLI has `owner-ask`, the ask is
  handed to it and reaches the owner with Approve and Decline. A seat's `sudo … approve` is refused
  without the owner's proof. The owner can set `send=allow` once, and sends then run and are logged.

What changed, and the knobs:

- **`payload`** in the request (`send`: `to`, `subject`, `first_line`; `pay`: `payee`, `amount`;
  `publish`: `text`, 280 characters; `delete`: `item`), read from the live page before the step by
  `lib/aria.cjs` `stepRisk`, shared by both step loops, for `act` and a guarded `run` alike. Bidi (U+200E/F, U+202A–202E, U+2066–2069)
  and C0/C1 characters are stripped from it and from `label`. `approvals` and `approve` print it.
  An empty payload is said to be empty, never replaced by the label.
- **`approvals policy [--json]`** → `{"pay":"ask","publish":"ask","send":"ask","delete":"ask"}`. It
  is JSON on `--json` and on `FIVEDIVE_JSON_MODE=1`. **`sudo 5dive browser approvals policy set
  <kind>=ask|allow`** is the owner's only: a seat uid, or `sudo` by an `agent-*` user, is refused.
  The store is `<profile root>/.approval-policy.json`, root `0644` (override:
  `FIVEDIVE_BROWSER_APPROVAL_POLICY`), and a file the granting uid does not own is ignored. With
  `allow`, the step runs and one line goes to `allowed.jsonl` in the seat's approvals directory,
  with the payload and the act's `page.png`. A guarded `run` (`run google.com send`) reads the same
  policy.
- **`approve <id> [--deny] --human-proof=<nonce>`**: from `sudo` by an `agent-*` user, `approve`
  and `--deny` need a nonce whose sha256 is the request's `nonce_hash`, trusted only in a request
  the granting uid owns. A root login, sudo from the owner's account and the dashboard are unchanged.
- **`5dive owner-ask browser <request-file>`** is run, fail-soft, after the ask is written
  (`FIVEDIVE_BROWSER_CLI` names the CLI). A CLI without the verb leaves the ask as it was.

### Added — `run google.com send`: a Gmail message in one command, the owner's yes, read back in Sent (DIVE-4984), browser 1.14.0

- **Before:** there was no google.com adapter, so a mail meant an `act` with steps the agent wrote
  itself. And an adapter could not have verified one: `run` re-read `verify.url` with a cookieless
  `curl`, so `https://mail.google.com/mail/u/0/#sent` came back as the sign-in page and every Gmail
  send ended NOT VERIFIED (rc 1), sent or not. A subject with `&`, `#` or a space broke the compose
  URL, because `{key}` values were spliced into URLs raw.
- **After:** `5dive browser run google.com send --to=<addr> --subject=<s> --body=<b>` opens compose
  with To and Subject filled, types the body, and stops in front of Send with exit 73 and an
  approval id. The owner's `sudo 5dive browser approve <id>` now shows the `--to`, `--subject` and
  `--body` it is saying yes to. The same command with `--approved-id=<id>` sends, waits for Gmail's
  "Message sent", and re-reads the Sent folder in the same profile:
  `verified: send is live at https://mail.google.com/mail/u/0/#sent (re-read in this profile)`.

What changed, and the knobs:

- **`verify.in_session: true`** (adapter): the re-read goes through the executor that acted (the
  warm session, or the cold driver), in the same profile, under the same lease. It is a fresh load
  of `verify.url`, graded with `--expect`'s window (`FIVEDIVE_BROWSER_EXPECT_WAIT_MS`, 5000).
  **`verify.wait_for`** waits for the page first. **`verify.scope`** grades only the first element
  that matches, so for Gmail an older mail with the same subject further down Sent cannot pass. Either
  one without `in_session` is refused at load. Without `in_session`, the verify is the curl it was.
- **`"guard": true`** (adapter action): pay/publish/send/delete stop a `run` the way they stop an
  `act` (exit 73). **`--approved-id=<id>`** spends the owner's yes, which is bound to that action
  with those arguments, once, for 30 minutes. An action without `guard` behaves as before.
- **Arguments are encoded for where they go**: into a step's or the verify's `url`, URL-encoded (both
  step loops); into `verify.expect`, regex-escaped, so "Q3 (draft)" matches itself. `fill` values
  are typed as given.
- **Not shipped: the login check.** google.com's signed-out page was not measured, so the adapter has
  no `probe`. Until one is added, `status google.com` reads UNKNOWN and `run google.com send` refuses
  with 75 before a step. Measure it with `5dive browser capture google.com`, draft the marker with
  `5dive reflex login-marker`, and put the `probe` in the seat's `.adapters/google.com.json`.

### Added — the browser waits for the page, names a loading screen, and never hangs a read (DIVE-4983), browser 1.13.0

On a live web app the page an agent got was not the page it asked for. Measured on a Gmail inbox:

- **Before:** `snapshot <inbox> --interactive` printed `4 addressable node(s)` and exited 0. The four
  were the loading splash's help links and "Try reloading the page", and nothing said so. `read`
  never came back (killed by `timeout 200`, nothing written). `act … --expect='Message sent'` ran
  every step and printed NOT VERIFIED, while its own `page.png` showed the toast and the mail was
  in Sent. No single command gave the refs of a loaded inbox.
- **After:** `snapshot <inbox> --interactive --wait-for='[role=main]'` captures once the inbox is on
  screen and lists `button/Compose`. Without `--wait-for` the splash is named: `LOADING SCREEN` on
  stderr, `loading_screen: gmail` and `partial: true` in `page.meta.json` and `page.md`, exit
  **76**. `read` comes back within a wall-clock cap with what had loaded, marked `partial: true`.
  `act --expect` re-reads the page until the toast shows, and passes.

What changed, and the knobs:

- **`--wait-for=<target>` on `snapshot`, `read` and `act`**: a CSS selector, `ref=<role>/<name>`, or
  `text=<words>`, bounded by `FIVEDIVE_BROWSER_STEP_TIMEOUT` (30 s). One that never appears is exit
  76 with the capture shipped as `partial: true`. `read --wait-for` renders through the executor or
  the warm session (`capture: playwright` / `session-daemon`). Both step loops (the cold driver and
  the session daemon) wait through one function in `lib/aria.cjs`.
- **Known loading screens**: one table, `LOADING_SCREENS` in `bin/browser`, one line per screen
  (name, host, a sentence, a ceiling on interactive nodes). Gmail's splash is the first row.
  **Exit 76** is new: the page was not ready. It is not 75, so do not log in again, and do not re-run
  an act's steps.
- **`read`'s wall clock**: `FIVEDIVE_BROWSER_READ_CAP_MS` (default 30000). Chrome gets `--timeout`
  at the cap and dumps what loaded (`partial: true`). A Chrome that ignores it is killed a few
  seconds later, and `read` exits 76 rather than hanging.
- **`--expect`'s window**: `--expect-wait=<ms>` / `FIVEDIVE_BROWSER_EXPECT_WAIT_MS` (default 5000).
  It is matched against the document and the visible text, toasts and `aria-live` regions included,
  and the read that matched is the one that ships. `--expect-wait=0` is the old single read.
- **`act` leaves the snapshot triple**: `tree.json` (`--interactive` narrows it), `page.md` and
  `page.meta.json`, beside `page.html`, `page.png` and `after.json`.
- A browser served before this release runs the old session daemon, which ignores `--wait-for`.
  That is reported as not honoured (76), never as met. Restart the serve to pick up the new daemon.

### Added — a box's browser can go out through the customer's own proxy (DIVE-4951), browser 1.12.0

Some sites refuse a datacenter IP ("Request blocked by network security"), and a box is one.
Until now there was nowhere to plug a fix in: neither Playwright launch passed a proxy, and
Chrome's `--proxy-server` cannot carry the username and password every paid proxy uses.

- **`proxy set <scheme://user:pass@host:port>` / `proxy show` / `proxy clear`.** Per seat, one
  line, 0600, in the seat's own 0700 profile root. `show` masks the password; the value is in no
  log line, no refusal and no `status`. `proxy set -` reads it from stdin. SOCKS with a login is
  refused up front (Chrome under Playwright cannot authenticate to SOCKS).
- **Both launches use it** — the session daemon and the cold driver pass Playwright's
  `proxy: {server, username, password}` through one shared parser (`lib/proxy.cjs`). With
  nothing set there is no `proxy` key, so the launch is byte-for-byte what it was. A setting that
  is there and cannot be read or parsed refuses the launch rather than going out direct.
- **A running served browser is not restarted.** `set`/`clear` name the served browsers still on
  the old route and the command that moves one; a seat that is not the box seat is told that box
  logins follow the box seat's setting.
- **Still direct:** plain-Chrome launches (the scheduled login check on an unserved site, a cold
  `read`/`shot`/`capture`, `auth` with a display). README "Limits: sites that block datacenter
  IPs" says so.

### Added — the browser acts, on any website, with nothing connected (DIVE-4943), browser 1.11.0

lodar, 2026-09-24: *"all examples are read only — i want our browser show that agents can act"*
and *"can our agent just use browser even if Connected sites: 0?"*. Before this, no agent could
click or type anywhere (every shipped adapter had `actions: {}`), a box with zero connected
sites could not use the browser at all, and 10 of the 13 sites the dashboard offers connected but
could not be read.

- **`act <url> --steps=<json>`.** Click, fill, select and press on refs from `snapshot
  --interactive`, in one tab under one lease, through the same executors and step vocabulary as
  `run`. `--expect=<regex>` grades the page as the steps left it (re-read without reloading);
  `page.png`, `page.html` and `after.json` land in the artifact directory. With a served browser
  and no URL, `act` continues on the page it is holding. `upload` is not an act step.
- **A URL in place of `<site>`, and a public profile.** Every page verb (`read links shot snapshot
  tree act`) takes a URL and picks the profile: the host's one login, or `_public` (a per-seat
  profile with nothing logged in and no login probe) when there is none. `ls`, `served`,
  `status` and `probe-all` never list `_public`, so the dashboard's Connected sites stays logins.
- **A generic sign-in check for sites with no adapter.** A page verb's gate no longer refuses every
  no-adapter site as UNKNOWN. It refuses a page that is visibly a sign-in (a password field, a form
  posting to a login/session/auth path, a sign-in URL after redirects) or a challenge, and
  otherwise proceeds, saying every time that no adapter confirmed the login. `status` still says
  UNKNOWN for those sites; only the gate in front of a render reads the generic check.
- **Several accounts per site.** A profile is `<site>_<label>` (`github.com_work`). The adapter,
  probe URL and host scope key on the site; the lease and directory on the whole name. A URL
  with two logins for its host is refused, naming both, never guessed.
- **Paying, posting, sending and deleting wait for the owner.** The executor reads the live
  element's label before each click and each Enter (Ctrl/Cmd+Enter is always a send) and stops
  in front of one, exit 73, with the ask, a screenshot and an approval id. `sudo 5dive browser
  approve <id>` (root, i.e. the owner's surfaces) grants exactly those steps, once, for 30
  minutes; `--approved=<id>` spends it. Enforced in both step loops (the one-shot driver and the
  session daemon) from one shared function in `lib/aria.cjs`. It catches the literal buttons; a
  purchase behind a button labelled "Continue" is not caught, and the docs say so.
- **A `use-browser` skill that sends agents to the browser.** It fires on web tasks ("go to
  <site> and …", buy/book/fill/submit, anything a normal fetch cannot do) and teaches snapshot →
  act by ref → verify, plus the owner-approval stop. `connect-site` no longer tells agents to use a
  normal fetch for public pages; it points them at `use-browser`.

Tests: T32a–h (zero-site act and read, generic check, two accounts, the owner's four in both
executors), each with its mutant: no URL route → the zero-site box cannot act; no generic check →
the live no-adapter login is refused again; the executor's guard removed → the order is placed.
T2c7/8 and T15b were changed on purpose: `approve` joins root's verbs, and a no-adapter page with
no sign-in form now renders.

### Fixed — Connect opens the site, not a blank page, and the viewer's browser runs sandboxed (DIVE-4944), browser 1.10.6

lodar on old-clay, 2026-09-24: *"opens about:blank instead of website and also warning 'You are
using an unsupported command-line flag: --no-sandbox'"*. Both came from the warm session
(DIVE-4621, 2026-09-20), and both reached every site on every box.

- **The site opens.** The cold `serve` launched Chrome at the site's URL. The session daemon that
  replaced it launched Playwright's persistent context with no URL, so the first tab was
  `about:blank`. `serve` now hands the daemon that URL (`FIVEDIVE_BROWSER_START_URL`, the same
  `_site_url` as before). The daemon loads it without holding `ready` and only for http(s). A
  failure is noted in the daemon log and the session stays up.
- **The sandbox is on.** The daemon passed `--no-sandbox`, and Playwright added a second one. That
  put the warning bar on every viewer and ran the logged-in browser a person looks at without
  Chrome's renderer sandbox. It now launches sandboxed, except as root (where Chrome refuses) or
  with `FIVEDIVE_BROWSER_NO_SANDBOX=1`. If a sandboxed launch fails, it retries once without the
  sandbox and says why, rather than losing the session. The cold path never passed the flag, so
  this matches what `serve` ran before 09-20.
- **Not changed:** the headless probe, shot and read launches and `driver-playwright` still pass
  `--no-sandbox`. They show no bar; they are tracked with the any-site work (DIVE-4943).

Tests: T31a–d (start URL loaded, sandbox on for non-root, one-retry fallback, a `file://` start
URL refused). T25c now reads the step order from the run's own records.

### Added — `browser capture <site>`: both halves of a login check, on disk, in one command (DIVE-4929), browser 1.10.5

`5dive browser capture <site> [--url=<probe url>] [--out=<dir>]` saves the probe page twice signed
out (two throwaway profiles, the probe's own command) and once signed in (this login's profile, or
the served session through the daemon). The files are 0600 and go in a 0700 directory. The command
prints the `sudo 5dive reflex login-marker …` line that drafts the site's login check from them
(5dive CLI, DIVE-4928, shadow).

- **Owner only.** A brokered seat is refused with 77, because the signed-in render is the
  account's page, for a site no probe has cleared for reading.
- **It never overwrites a directory.**
- **It warns when both halves show the same page title.** That usually means the profile is not
  logged in. A byte comparison misses this, because sign-in pages carry per-render tokens.
- **It classifies nothing and writes no adapter.**

Tests: T30a–g, including a mutant (the broker refusal dropped → a brokered seat gets the file).
Released as 1.10.5 so a box can pull it: the both-halves measurement (DIVE-4931) runs on a box,
and a verb without a version of its own reaches none. The box converger's floor stays at 1.10.4,
because nothing a box needs depends on this verb. A box that runs the measurement upgrades by hand. On a box keyed to the
`browser@5dive-plugins` registry copy, that needs the registry mirror at 1.10.5 first.

### Fixed — a hired agent can use the box's logins: its lease is really held, and it waits out a status check instead of being refused (DIVE-4927), browser 1.10.4

Marcus on exact-swallow, 2026-09-24: a second seat's brokered `read` and `run` against the box's
github.com login were refused with *"whoever sent this did not hold [the lease]"*, while `lease
--status` read **free**. There were two defects.

**The brokered lease was dead on arrival.** A brokered seat cannot write inside the owner's 0700
profile, so the daemon spawns `_broker-lease` as the owner to take the lease for it. That child
became the lease's anchor pid, and it exits as soon as it prints the token. Even with a live anchor,
the owner's `kill -0` on another seat's process is EPERM, which read as "no such process". The
caller now sends its own pid as `anchor`, and the daemon accepts it only if `/proc` says it belongs
to the SO_PEERCRED uid (a foreign pid gets exit 77 and nothing is written). Holder liveness now reads
`/proc` instead of trusting `kill -0`.

**The daemon refused any request that overlapped another.** `status` probes run through the daemon
without a lease by design, so a leased caller that landed inside one was refused and blamed for it.
A request now waits a bounded time (`FIVEDIVE_BROWSER_BUSY_WAIT_MS`, default 60s). Past that, the
refusal names the op in flight, its seat and its age. Acting ops still re-read the lease before
every step.

**Reaching a box:** a site whose daemon is already running keeps the old code until that site's
`serve` restarts.

### Fixed — an admin agent can start the box login's browser itself, instead of handing a human a shell command (DIVE-4813), browser 1.10.3

lodar, on wavy-mesa 2026-09-22: an admin-tier agent asked to open Telegram Web — a site **this box
had already connected**, under the `claude` seat — and answered *"Blocked … as agent-claude-yak I'm
refused even through `sudo 5dive`"*, then printed `sudo -u claude 5dive browser serve
web.telegram.org` for a person to run. The site login is per BOX by design (DIVE-4662); the agent
could not reach it.

**The door that shut was not the 0700 profile and not the plugin's caller guard.** It was the
DIVE-4348 root-drop. A brokered seat can only act through a *running* daemon, and starting one is
the owner's act, so the agent's only lever was root via the admin sudoers class
(`/usr/local/bin/5dive *`). The drop spent that lever: on `sudo 5dive browser serve` it re-executed
unconditionally as `SUDO_USER` — the seat that cannot read the profile — and landed back in the same
refusal. The advice it printed then asked for `sudo -u claude`, a **runas the admin grant does not
contain**; 5dive-cli says so in `write_admin_sudoers`: *"neither an admin nor a standard agent can
`sudo -u claude`"*. So the one command offered was one no agent on the box could run.

Root now becomes the seat that **owns** the session for that one verb. `_root_drop_target` picks
`$BOX_SEAT` when, and only when, the caller owns no store for the site *and* the box has published
an `.offered` marker for it — both box state, never caller input; the target is a constant, so a
site named `root` steers nothing. The caller still never opens the profile directory: the daemon
runs as the owner and the caller acts over the socket exactly as before.

**No new grant and no new sudoers class.** Reaching euid 0 here already required the admin class,
which a standard agent's scoped drop-in does not contain — so **euid 0 is the tier check**, and
standard tier is unchanged: it does not read box-level sites, because an identity is never a grant.
`--stop` stays the owner's, for the reason `lease --release` already refuses a brokered caller —
tearing down a browser several seats and a human viewer share is not done on another seat's behalf.
The on-behalf drop also scrubs `FIVEDIVE_BROWSER_SEAT` (which would re-point the store this exists
to open) and sets `FIVEDIVE_BROWSER_ON_BEHALF_OF` itself, so the audit row naming who asked cannot
be forged by the caller.

Both refusals now name a verb the agent can run **from its own seat** — `sudo 5dive browser serve
<site>` — instead of one only a human could execute.

The decision is a function taking the calling seat as an argument, reached by a hidden read-only
`_drop-target` verb, because the drop itself is gated on `$EUID` and `$EUID` cannot be faked: an arm
written against the inline block would grade the real thing only where the runner happens to be
root, green-by-blankness elsewhere, with nothing in the output to tell the two apart.

### Added — `served` and `forget`: a running browser you can stop, and a site you can log the box out of (DIVE-4791, ported by DIVE-4797), browser 1.10.2

**This code landed in the frozen registry copy first** — `5dive-plugins@023a95cb`, browser 1.10.0,
merged 2026-09-21 — because that is the tree DIVE-4791 was built against. It reaches nobody there:
`_bs_plugin_add` tries THIS repo first, and the converger's floor is a `min()` over both copies, so
a capability released into one of them rolls out to zero boxes
(`community/wiki/a-forked-plugin-makes-the-converger-floor-a-min-over-both-copies.md`). The port is
the rollout.

**The version is 1.10.2, not 1.10.0.** This repo's `main` was already at 1.10.1 (DIVE-4794, the
probe wait) when the port was cut, and `plugin upgrade` compares the version number only — a second
1.10.0 with different bytes is never fetched, and 1.10.1 is a version the fleet can reach that does
NOT carry these verbs. Anything that gates on the capability must therefore ask for **1.10.2**, not
for the number written on the frozen copy.

`served` prints the seat's running browsers, one site per line and nothing else. It is a separate
verb rather than a column in `ls` because the dashboard PARSES `ls`'s `"<site>  <iso> <state>"`
line: a marker appended there would have made every served site read as never-probed on the API
already deployed. A box whose plugin predates the verb exits non-zero, which the dashboard reads as
"nothing is served" and offers no Stop control — fail closed.

`forget <site>` is the way out, and it is the delete: a profile IS the login, so stopping the
browser (`serve --stop`, `evict`) deliberately keeps it. It revokes the viewer, stops the browser
through the graceful daemon shutdown, withdraws the box offer, audits into the SEAT store — not
into the directory it is about to remove — and deletes the profile. It refuses while a person is in
the viewer or a caller holds the lease, which are evict's two refusals for evict's reason, except
that here the loss is unrecoverable.

### Fixed — a probe that read the static shell could not classify a single-page app, and a brokered `snapshot` could not write (DIVE-4794), browser 1.10.1

lodar connected Telegram Web on his box, the broker worked — the agent seat drove the
`claude`-held session through the rendezvous socket, audit rows and all — and the agent still
could not do anything with it, because **classifying** the session failed and every acting verb
is gated on `authenticated`.

**The page had not decided yet.** `https://web.telegram.org/k/` ships one static index for both
login states (`<body class="… has-auth-pages …">` in the bytes the server sends) and removes that
class in JavaScript once its own network init decides it is logged in. The probe dumped the DOM at
domcontentloaded plus a fixed 800 ms, which is before the decision — so at probe timing a LIVE
session and a DEAD one were identical in every field a marker could read (measured 2026-09-21: the
same profile that `snapshot` showed with `auth-pages` 0 and `chatlist` 9 when settled still carried
`auth-pages` under the probe). An adapter written against the shell therefore stamped `expired` on
a live login at 16:58Z and `snapshot`/`read` then refused "logged out"; the other marker choice —
the sign-in page's CONTENT — cannot false-alarm but reads `authenticated` on a cold expired
profile, which is fail-OPEN.

Two changes, and they only work as a pair:

- **`probe.logged_in_when_dom_matches`** — an adapter may name what a LOGGED-IN page looks like.
  `authenticated` stops being an inference from the logged-out marker's absence and becomes a
  match.
- **the probe WAITS** — where a positive marker exists, the warm (daemon) probe polls the live
  page and the cold probe looks again, up to `FIVEDIVE_BROWSER_PROBE_WAIT_MS` (default 8000),
  returning the instant either marker appears. A page that shows NEITHER inside the budget is
  `UNKNOWN`, never `authenticated` by elimination — `run` and `shot` stay refused, which is the
  fail-closed half.

An adapter with no positive marker is byte-for-byte unchanged: one look, classified on the
negative alone. The wait exists only where there is something to terminate it, so `github.com`,
`x.com` and `reddit.com` pay nothing for it. The daemon never classifies — the markers ride in the
request only so it knows when to stop waiting, and the verdict is still `bin/browser`'s grep, so
two regex engines can never disagree about a login.

**Ships `adapters/web.telegram.org.json`.** The positive marker is measured on both halves
(`class="…chatlist` — 9 on the settled live session, 0 on the shell and on a logged-out render).
The logged-out marker is half-measured and the file says so: it matched 0 on the live session, but
the K app never painted its sign-in page inside the probe's window on a fresh profile, so "it
matches a logged-out page" is unverified. That gap fails SAFE only because of the change above —
neither marker matching is `UNKNOWN`, which asks a person, not a login, which would lie.

**A brokered `snapshot` could not write its evidence.** `snapshot` staged artifacts in a directory
0700 to the CALLER and named that path in the request; the daemon runs as the profile's OWNER, so
it died with `EACCES: permission denied, open '/tmp/5dive-browser-read.XXXX/page.html'` — the verb
the skill tells an agent to reach for first, dark for every seat that does not own the login.
A brokered request now asks for the BYTES (`inline`), the same trade `shot` and `read` already
make over this socket, and the caller writes them in the directory it owns. The owner's own
`snapshot` keeps the cheap path-writing shape. Widening the staging directory to the box seat was
the other fix available and is the one DIVE-4662 refused: it is the holder of a live session
writing a caller-chosen path.

**And a brokered capture came back CUT.** `session-daemon call` wrote the payload to stdout and
then called `process.exit(rc)`. stdout is a pipe for every caller, a pipe write past the OS buffer
is queued rather than done, and `process.exit` drops what is queued — so a brokered `read` of a
real page surfaced as `jq: parse error: Unfinished string at EOF` on a capture that had actually
succeeded. The client sets the exit code and lets node flush. Graded with a two-megabyte payload,
because every arm whose payload fits in the buffer passes either way.

### Fixed — a ref `wait_for` never waited, and `run` looked at a page nobody let settle (DIVE-4674), browser 1.10.0

Two halves of the same experience: an adapter quoted the refs `tree` printed, and `run` then
said no such element was on the page at all.

**A ref `wait_for` waited for 0 ms.** Both step loops turned a selector into an element with a
ONE-SHOT walk before the switch, so `{"op":"wait_for","selector":"ref=textbox/Add a comment"}`
probed the page once and threw, while the identical step written as a CSS selector polled for
the whole 30-second step timeout inside `page.waitForSelector`. The instruction this plugin
tells agents to prefer was the one that could not wait. A ref `wait_for` now polls the page
until the step timeout, and when it does give up it raises the same message as before, naming
the refs that ARE on the page — the hint an operator reads, and the exit code (`70` on step
one, `1` after) that stops `run` re-reading an artifact nothing wrote to. `fill`, `click`,
`press`, `select` and `upload` deliberately keep the one-shot resolve: an adapter that needs to
wait says so with a `wait_for` step, and a `click` that hovered for thirty seconds would turn
"this is not the page `tree` described" into the same wrong answer half a minute later, inside
a live account.

**`run` had no settle at all.** `tree` and `snapshot` wait 1200 ms after `domcontentloaded`
before looking, because a live application is still assembling itself there; `run` went from
`goto` straight to the next step. Measured on a GitHub issue page, 2026-09-20: the default
`tree` returned 54 nodes and no textbox, `--settle=6000` returned 76 including
`textbox/Add a comment` and `button/Comment` — and `run` was resolving those refs about fifty
milliseconds after load. `run` now takes the same bounded settle after every `goto`
(`FIVEDIVE_BROWSER_RUN_SETTLE_MS`, falling back to `FIVEDIVE_BROWSER_TREE_SETTLE_MS`, default
1200). It is still never `waitUntil: 'networkidle'`: a web app that long-polls never idles, and
waiting for one is what made a `read` hang for 150 seconds on a real box.

**The knob is reachable now.** `tree` takes `--settle=<ms>` like `snapshot`; `run` takes
`--page-settle=<ms>`, spelled with a dash because every other `--key=value` on a `run` command
line is an adapter argument and a placeholder name is `[a-zA-Z0-9_]+`, so a dashed flag can
never eat one. All three carry the value INTO the warm session's request: the daemon is a
long-lived process that cannot see an environment variable set on this command line, which is
why `snapshot --settle` worked on a cold profile and was silently dropped on a served one.

A settle is a floor on when anyone looks, not a fix for a late element — raising it is paid on
every run, while a `wait_for` costs only what the page actually takes. Graded by the T28 family
in `tests/browser_plugin_unit.sh`, through a stub page that answers "not there" N times and then
"there"; the warm half is graded through a real `session-daemon`, and two mutant arms run in
their own copy of the package — one puts the one-shot resolve back and asserts the late ref
becomes a refusal again, the other deletes the asymmetry so every op polls and asserts the ref
`click` stops refusing. That second one is why the choice stated above is a graded claim and
not a comment: `fill`/`click`/`press`/`select`/`upload` keep the one-shot resolve and an arm
counts the looks, so an edit that let a `click` hover for the whole step timeout inside a live
account goes red.

### Fixed — `browser setup` refuses to mint a probe timer for an account the registry does not know (DIVE-4730), browser 1.9.2

`setup` mints `5dive-browser-probe@<seat>.timer`, a per-seat unit that **outlives the
account**. On box 10 (`5dive-exact-swallow`) one has fired every six hours since 2026-09-16
for `agent-mp` — a de-registered account whose unix user survived, one of nine orphans
`5dive doctor --category=registry` already names. It has failed on every fire (the account is
outside the shared group, so it cannot read the box plugin record either) into a journal
nobody reads, and nothing on the dashboard shows it, because the dashboard lists the
**registry**, not `/etc/passwd`.

`setup` now refuses **before the store is made** when the seat is an `agent-*` account the
registry has measured as absent, and names the reap rather than a workaround. The predicate
is narrow in both directions: `agent-*` only (`claude` and operator accounts are not registry
rows and never were), and a registry it could not read or parse **fails open** — a dev box is
not evidence that an account was de-registered. `FIVEDIVE_BROWSER_ALLOW_UNREGISTERED_SEAT=1`
is the documented one-off override.

This landed first as `5dive-ai/5dive-plugins` PR #101, against the copy of `bin/browser` that
DIVE-4691 froze and deprecated on 2026-09-21 — a tree no box upgrades from. The guard is the
same; the repo is the one that ships. #101 is closed as superseded.

### Added — a site login is per BOX and brokered: seats use the box's login (DIVE-4664), browser 1.9.1

Ported from `5dive-ai/5dive-plugins` (registry `browser` 1.9.0, PR #93) by DIVE-4719. This repo was
cut at 1.8.0 on 2026-09-20 and the registry copy kept receiving merges, so the repo the deprecation
notices point at was a strict SUBSET of the copy they deprecate — a box obeying "migrate" would have
removed 1.9.0 and installed 1.8.0. `bin/browser` here is now byte-identical to the registry copy and
the version is 1.9.1, one above it, so `plugin upgrade` can never walk a box backwards. The version
is the only intentional difference; `homepage` already named this repo.

Measured on one box 2026-09-20: the profile store held **fifteen seats and fourteen empty stores**.
Every agent seat was logged out of every site a human had connected through the dashboard, so each
seat that needed a site was another human login — and with one shared site across ~18 seats, up to
eighteen Chromes at ~300–500 MB each, which makes RAM (not the work) the thing that bounds how many
seats can hold a live session.

The store does **not** move and does **not** open up. Group-reading a profile directory is handing
out the credential — anything that can read it can replay the session — so the store stays 0700 to
the seat where every existing login already lives, and there is no migration. What moves is the
session daemon's unix socket: out of the 0700 directory and into a rendezvous
(`/var/lib/5dive/browser-sessions/<seat>/`, `0750` to the box's agent group) where other seats can
**connect to it**. They never open the profile; they ask the process that already holds it. Still
never a TCP port — a loopback debug port is reachable by every seat on the box and CDP is full
control of the browser holding the session.

`status`, `tree`, `run`, `shot` and `read` all work from a brokered seat, with no second login.
`shot` and `read` needed a **render op** the DIVE-4621 daemon did not have: the PNG and the DOM come
back over the socket as bytes from ONE page instant, never as a path for the daemon to write — a
request carrying `--out=` would be the owning seat writing a caller-chosen path, which is the test
rig DIVE-4662 built and explicitly did not ship.

Resolution is **own store first, then the box store**, so a seat that made its own private login for
a site keeps using it; per-seat survives as the opt-in it always was, with no per-site policy table.
Attribution comes from `SO_PEERCRED` on the connection, so the lease and every audit row carry
`holder=<owner> on_behalf_of=<the calling seat>` — the kernel's answer, with nowhere for a request
to sign somebody else's name. Where the caller cannot be named, the rendezvous socket is not opened
at all and the session stays one-seat: losing the broker is a lost convenience, an unattributable
caller driving a live login is not.

Two refusals that used to be one silence: a site the box has no login for still says "no profile —
log in", while a site it HAS a login for with nothing serving it names the owning seat and the
command to start it. Sandboxed seats are outside all of this by construction — `agent create` keeps
them out of the shared group on purpose, and that is their isolation working.

Also fixed while here: `_seat` now resolves from the **effective uid** rather than `SUDO_USER`, so
`sudo -u <seat> 5dive browser …` acts as `<seat>` instead of looking for the CALLER's store while
running as somebody else. The per-site memory claim ships with its rig,
`tests/browser_box_login_bench.sh`, which prints the per-site available-RAM delta and the chrome
process count before and after N brokered seats act on the same site.


### Added — one snapshot per decision: `browser snapshot` (DIVE-4653), browser 1.8.0

Before an agent acts on a page it reads the same three things: what it can click
(`tree`), what the page says (`read`) and what it looks like (`shot`). Each of those
is its own command, and each command is its own browser cycle — probe the session,
open a browser at the profile, load the URL, do one thing, close. Three cycles and
three loads of the same page, for one decision. `snapshot` is those three reads as
ONE cycle: one navigation, one page-side walk that returns the refs *and* the
document, and one screenshot of that same tab. On a served profile it runs inside
the warm browser — the render op the DIVE-4621 daemon did not have.

The second half is correctness, and a faster box does not fix it. Three cycles are
three different page instants: a ref `tree` printed can be gone from the DOM `read`
captured seconds later, and the PNG can show an overlay neither saw. Those files land
in one artifact directory looking like one observation and nothing in them says
otherwise. Here they come from one `page.evaluate` of one tab, so `page.meta.json`
hashes the very bytes the refs were walked out of.

The count is graded deterministically in the unit suite (one launch, one navigation,
one read, against a control that shows the three verbs taking three of each). The wall
clock comes from a rig that ships with the change — `tests/browser_snapshot_bench.sh`,
which anyone can re-run — on a local static page, one box, two iterations, 2026-09-20:
nothing served **6380 -> 3507 ms (1.8x)**, warm daemon **7687 -> 3006 ms (2.6x)**. The
warm three-verb arm is the *slowest* of the four because two of those three verbs stop
and restart the daemon to get the profile; `snapshot` never does. A local page makes
this an upper bound on the ratio for this task shape, not a constant — a real
application spends more time in the page and less in the launch, and the claim that
survives there is the cycle count.

`tree`, `read` and `shot` are unchanged and are still the right verb when one field is
all you want; `read`'s independent `--dump-dom` capture keeps its own provenance.


### Added — a warm browser session: `serve` holds one Chrome and commands attach to it (DIVE-4621), browser 1.7.0

`serve` was an Xvfb and an abandoned Chrome. Because Chrome allows one instance per
`--user-data-dir`, every command that needed the profile had to STOP it, launch a
probe, launch the driver's browser, and start it again — four launches for an
action that is three clicks.

It is now a daemon holding `launchPersistentContext(<the 0700 profile>)` on the
site's display, answering on a unix socket inside that same 0700 directory.
`run` and `tree` attach to it. Never a `--remote-debugging-port`, and the launch
refuses one: a loopback debug port is reachable by every seat on the box and CDP
is full control of the browser holding the session.

Measured by a rig that ships with the change — `tests/browser_session_bench.sh`,
which anyone can re-run — on one box, same task, `run` = goto + fill + click +
the out-of-band verify. A browser served with no daemon (the shape a customer is
in) against the same command warm: **3.1x-6.4x** across three runs. The spread
is box load, and it falls on one side only — the warm median was 1290-1381 ms in
every run, while the served-no-daemon median moved 4047 -> 8656 ms as the box got
busy. That is the point rather than a caveat: what the daemon removes is the
launch, and the launch is the part that costs more the more the box is doing.
Where nothing was being served at all it is 1.4x-2.7x. About 1.0 s of what is
left warm is the liveness probe, not a launch,
and the page is a local static file — a real web application spends more of its
time in the page, so this is an upper bound for this task shape rather than a
constant.

`status` can also read a SERVED profile for the first time: it used to answer
`UNKNOWN (served on :N)`, because probing a held profile needed CDP and CDP
needed a port. The daemon is a third shape — a process that outlives the command
— so the probe goes through it, in its own tab, which is then closed so nobody at
the viewer is navigated away. That command is now ~1.0 s instead of 78 ms of a
non-answer.

The lease is still re-read from disk before every step, by the daemon: it
outlives every caller and serves callers holding different tokens, so the token
travels in the request and the file is what is trusted. A box without the pinned
`playwright-core` still serves — `serve` falls back to launching Chrome directly
and says so in one line. Losing the speed must not lose the browser.
### Added — `5dive browser adblock`: turn ad filtering off for one site (DIVE-4516), browser 1.6.0

Agent Chrome profiles on a managed box now carry exactly one extension — uBlock
Origin Lite, pinned and force-installed by Chrome managed policy — and that same
policy blocks every other extension from being added, including by a human at the
one-time viewer. Some sites break under filtering, so there is a way to turn it off
for one host without turning it off everywhere.

- `5dive browser adblock status` / `sudo 5dive browser adblock off|on <site>`.
- Root, and not by preference: Chrome policy on Linux is machine-level only, with
  no per-user path, so the file belongs to root the way the profile store does.
  `adblock` joins `setup` as the second verb a root caller is NOT dropped out of.
- The mechanism is `ExtensionSettings.<id>.runtime_blocked_hosts`, measured on
  Chrome 153 before it was built on: uBOL Lite filters through declarativeNetRequest
  (the network stack), not through the content-script path that key is documented
  against, and it turned out to stop BOTH. It is total for that host.
- Both `*://host` and `*://*.host` are written. `*://*.example.com` does not match
  `example.com`, so a wildcard-only off switch reports success and leaves the apex —
  the host the seat actually typed — still filtered.
- `/var/lib/5dive/browser/ubol/adblock-off` is the source of truth, not the policy
  file: the nightly root converge re-renders that file, and a host living only there
  would be silently re-filtered at 03:00.
- Only fresh launches were measured, so `shot`/`read` pick a change up on their next
  render and the verb SAYS a live `serve` may need a restart rather than promising it.

### Fixed — a shared `XDG_CONFIG_HOME` made Chrome un-launchable for every seat but the first, and nothing said so (DIVE-4587), browser 1.6.1

Reported from a customer box with ~37 seats (teal-fox, 2026-09-16): every Chrome launch by every seat
but one aborted with `chrome_crashpad_handler: --database is required` and a core dump — rc 133, zero
bytes — so `serve`, `status`, `run`, `shot` and `read` were all dead. Chrome keeps its crashpad
database under `$XDG_CONFIG_HOME/google-chrome/Crash Reports` whatever `--user-data-dir` and
`--crash-dumps-dir` say, and creates it `0700`; 5dive boxes export one shared `XDG_CONFIG_HOME` to
every seat for `gh`/`gcloud`/`aws`, so the first seat to run Chrome owns that directory permanently.
`bin/browser` and `bin/driver-playwright` now drop the variable before launching anything, which gives
each seat its own crash directory under its own home. Dropping the shared export instead was not
available — about twenty other shared configs reach their state through it — and widening the
directory's mode breaks again at the next `0700` subdirectory Chrome creates.

The second half is why it survived for months: `status` printed a quiet `UNKNOWN (probe did not load)`
and exited **0**, the scheduled probe exited 0 without stamping anything, and `doctor` said nothing, so
the box read healthy while the plugin was entirely dead. A probe failure is now classified before it is
reported — the browser is asked for `about:blank` in a throwaway profile — and a browser that will not
start is a loud `BROKEN` state: non-zero from `status`, a refusal at `run` and `shot`, and the one
condition that fails the probe timer. A page that merely did not load stays quiet, as before: a network
blip must not page a person, but a box fault that no amount of re-probing will clear must.

### Fixed — the browser connect-site runbook now follows the shipped bound viewer flow (DIVE-4523), browser 1.5.3

The Claude skill and harness-neutral AGENTS block now carry one byte-identical fenced workflow. It
starts from the dashboard action that registers the relay bind and prefixes the box host, names the
relay's `claude` seat and the upgrade-safe seat-local adapter store, keeps one-time links
non-unfurling, and verifies a login only after revoke → stop → status. The old raw-CLI path could
produce a path with no live bind, target the wrong seat, and poll forever while Chromium held the
profile lock.

The handoff step states DIVE-4493's guard concretely rather than by reference — on Telegram, `reply`
with `format: 'markdownv2'` and the link in a MarkdownV2 code span; elsewhere that surface's
non-unfurling code formatting — and keeps the copy-paste warning and the rule against recording a
live link in a task body, PR, commit, log line or wiki page. `tests/browser_plugin_unit.sh` now
guards those strings in BOTH surfaces, so a rewrite cannot drop them while the bash harness stays
green; previously only `test/viewer-link-unfurl.test.ts` held them, and only for the skill.

`plugins/browser/README.md` no longer says the customer-facing flow ships dark and unlogged-into:
the dashboard tile went to production 2026-09-12 (DIVE-4355) and a human logged into real sites
through real one-time viewers on a managed box 2026-09-14 (DIVE-4464). The RELAY-mode caveat below
it is unchanged and still true.

### Fixed — Telegram previewers spent one-time browser viewer links before the human could use them (DIVE-4493), browser 1.3.1 · telegram 0.5.53 · grok/agy 0.5.21 · codex 0.5.14 · opencode 0.5.12 · pi 0.1.12

All six Telegram adapters now recognize the exact browser-viewer route at their Bot API
`sendMessage`/`editMessageText` boundary. Plain text is sent with a `code` entity, markup output gets
a code span, overlapping URL entities are removed, and previews are disabled. The transport also
adds copy-paste/do-not-return guidance; ordinary URLs and nonce lookalikes are unchanged. The shared
browser workflow carries the same rule for future chat adapters and records that a dashboard may
offer copy-only UI but must never prefetch the credential.

### Added — authenticated browser pages can be read as Markdown with a hash-bound evidence triple (DIVE-4515), browser 1.4.0

`5dive browser read <site> <url>` now reuses the `shot` authentication and profile boundary, then
captures one post-script DOM with Chrome `--dump-dom` and extracts the article through a vendored,
exactly pinned Defuddle 0.19.3 bundle. It writes private `page.md`, `page.html`, and
`page.meta.json` artifacts; the metadata binds the exact DOM bytes by SHA-256 and records URLs,
article fields, links, images, schema.org data, extractor version, Chrome version, and capture
method. `--json` returns metadata plus Markdown, while `browser links` uses the same capture and
prints only the extracted links. Logged-out, cross-site, live-viewer, and profile-directory output
attempts fail before producing evidence, and the read opens no CDP socket.

### Fixed — the dashboard's `browser ls` refused on every box, so the Connect-a-site tile could never list sites (DIVE-4348), browser 1.1.1

Two defects in `bin/browser`, both found on the first real box (exact-swallow, 2026-09-12):

1. **A root caller refused every verb but setup.** The dashboard reaches the plugin through shelld's
   whitelist, `sudo -n /usr/local/bin/5dive browser …` — root, with `SUDO_USER=claude`. `_seat`
   resolved that to `claude`, but `_audit` compared the store's owner to `id -u` (0), so `ls`,
   `status`, `serve`, `viewer` and `viewer-redeem` all exited 77 ("owned by uid 1000, not by you
   (uid 0)") and `GET /server/browser/sites` read every box as unavailable. Root now re-executes as
   the seat (`runuser -u $SUDO_USER`) before any store is touched; `setup` stays root's.
2. **Every seat store was created 2700, and the audit wants 700.** `/var/lib/5dive` is 2750 on every
   box, a directory made under it inherits setgid, and GNU `chmod 700` preserves that bit on a
   directory. `setup` now uses the 5-digit form (`chmod 00700` / `00711`), which clears it. An
   existing box heals on its next daily converge (`5dive-browser-stack-install` re-runs setup).


### Added — browser server mode and a one-time re-auth viewer, so a managed box needs no ssh, no apt and no display (DIVE-4118), browser 1.1.0

DIVE-4021 shipped `5dive browser auth` as "open a real Chromium, and REFUSE without a display". On a
managed 5dive VM there is no display and there never will be, so the only route through that refusal
was `ssh -X` plus `apt install chromium` plus a hand-written adapter JSON. lodar, 2026-09-09: *"thats
too difficult for customers. the point was to make it easy to use for our paid customers on our
managed vm"*.

Server mode is the shape 4021's own design named as the DEFAULT and did not ship. The profile's
Chrome now lives on a persistent Xvfb display owned by the seat, and a person reaches it — to log in
the first time, and again when the site kills the session — through a viewer handed out as a one-time
ticket:

```
5dive browser serve <site>                                   # persistent Chrome on its own Xvfb
5dive browser viewer <site> --bind=<session> [--ttl=600]     # mint a one-time link
5dive browser viewer-redeem <site> --nonce=- --session=<id>  # the relay's gate; consumes the link
5dive browser viewer-revoke <site>                           # kill the view, keep the login
```

`auth` on a display-less box no longer dead-ends: it starts server mode and tells you to ask for a
viewer link. The old refusal survives only where it is true — a box without the server-mode packages,
which now says *which* ones it lacks instead of half-starting. The manifest version moves with the
verbs (1.0.0 -> 1.1.0) because `plugin add` resolves a version-pinned cache path: a fix ships by being
installable, not by being merged.

#### The question 4021 left open: what protects the session WHILE the viewer is open

A viewer onto a logged-in profile is not a screenshot. It is the credential with a keyboard attached,
so the answer is five properties and every one of them fails closed.

1. **Nothing listens off-box.** `Xvfb -nolisten tcp`, `x11vnc -localhost -once`, the websocket bridge
   on `127.0.0.1`. Redemption hands the relay a loopback target; the customer arrives through the
   box's already-authenticated relay, never a port we opened.
2. **The ticket is a nonce we do not keep.** 32 bytes of urandom; the file stores only its SHA-256.
   The raw value exists exactly once, in the line we print.
3. **It is single-use, and the replay branch is a pure refusal.** The spent-state check runs *before*
   the nonce compare, so a dead ticket is not an oracle — and that branch touches nothing, so a replay
   carrying a garbage nonce cannot tear down the live viewer it was refused from.
4. **It is bound to the session that asked.** `--bind` is mandatory; `--bind=local` is the named
   escape for a hand-run. A wrong-session redemption is refused and does not spend the ticket for the
   rightful holder.
5. **The nonce never enters argv.** `/proc/<pid>/cmdline` is readable by other seats, so the nonce
   arrives on stdin and `--nonce=<value>` is refused rather than accepted and hoped about.

Killing the viewer does not kill the browser. The profile is the durable half; the view onto it is the
ephemeral half, which is what lets the TTL be minutes.

#### A link is never issued onto a bridge that is not accepting yet, and the ticket never outlives it

The mint starts `x11vnc` and `websockify` in the background, so "started" and "accepting" are two
different moments — and the product's whole shape is a one-time link handed to a relay that redeems it
at once. `viewer` now waits (bounded, `VIEWER_BRIDGE_WAIT_S=10`) for both loopback ports to be
accepting before it writes a ticket or prints a link, and on timeout reaps and refuses: no link at all
costs a retry, a live link onto a dead port costs the customer their single redemption. The readiness
probe READS `/proc/net/tcp` rather than connecting, because connecting would spend the `-once`
admission the customer was promised. The previous ticket is revoked up front, since a mint that dies
halfway has already killed the viewer that ticket pointed at.

Both windows are then measured from **one clock, stamped before `x11vnc` starts**. `-timeout` is a
length counted from launch; `expires_at` is an instant, and it used to be stamped *after* that wait —
so on a slow bridge the ticket advertised up to ten seconds of life the VNC server had never been
given, and the end of the advertised window was the dead-port failure again from the other end. The
alternative fix (padding `-timeout` by the wait) was rejected on purpose: it leaves a VNC server
accepting a client after its own ticket expired, which is a live credential with no authorization
behind it.

#### A profile directory that already exists is GRADED, not laundered

`auth` ran `mkdir -p; chmod 700; _audit`, so on a directory that already existed the `chmod` repaired
a group-readable profile a moment before the audit that exists to catch it — against the README's own
rule that commands never repair. `_ensure_profile_dir` chmods only what it just created.

#### Evidence

`tests/browser_plugin_unit.sh`: **193 arms, 0 failed**, graded by **23 of 23 mutants killed** rather
than by arm count. Every count below was re-derived in THIS repo at this head — the plugin changed
repositories in DIVE-4202, so carrying forward numbers measured in the old one would be a claim about
a tree that no longer exists.

| mutant, i.e. the way the keyboard reaches the wrong person | suite |
| --- | --- |
| the ticket file keeps the raw nonce (compare adjusted so redemption still works: this isolates "the secret is on disk" from "redemption breaks") | 2 failed |
| redemption does not consume the ticket (a leaked link replays) | 5 failed |
| the expiry check is dropped | 2 failed |
| the session binding is not checked (a pasted link works) | 3 failed |
| a nonce in argv is accepted instead of refused | 2 failed |
| an existing profile directory is chmod'ed instead of graded | 2 failed |
| the package precondition is deleted | 4 failed |
| `x11vnc` loses `-localhost` (it answers every seat on the box) | 1 failed |
| `websockify` binds `0.0.0.0` instead of `127.0.0.1` | 1 failed |
| `Xvfb` loses `-nolisten tcp` (the display becomes a remote keyboard) | 1 failed |
| `x11vnc -timeout` goes back to a constant shorter than the minimum TTL | 3 failed |
| `x11vnc -timeout` is a plausible constant (900) instead of derived from the TTL | 2 failed |
| redemption prints the target but withholds the VNC password | 4 failed |
| the nonce compare is moved AHEAD of the spent-state check (the oracle) | 3 failed |
| `serve --stop` leaves the ticket open (it redeems onto a dead port) | 1 failed |
| stopping the viewer leaves its password behind in the profile | 2 failed |
| the replay branch tears the viewer down (a wrong nonce + a wrong session kills a live view) | 2 failed |
| the ticket is consumed BEFORE the credential read that can refuse | 5 failed |
| the bridge-readiness wait is deleted (a link onto a port nothing is bound to) | 8 failed |
| the up-front revoke is dropped (a failed mint leaves the old link live onto a dead viewer) | 2 failed |
| **new:** `expires_at` stamped AFTER the wait (the ticket outlives its own VNC server) | 1 failed |
| **new:** `-timeout` padded by the bridge wait (the VNC server outlives its own ticket) | 3 failed |
| **new:** the manifest version stays at the one that shipped without these verbs | 1 failed |

There is no X server on a CI runner, so `Xvfb`/`x11vnc`/`websockify` are fakes on PATH — liveness is
still the real PID check, redemption is still the real SHA-256 compare, and the only override is the X
socket *directory*, a path, which cannot make a dead display read as live. The fakes RECORD their argv
and BIND the port they are handed: written the first way they `exec sleep 300` and discarded `"$@"`,
which silently deleted the surface carrying the property this design leads with. Captures are cleared
before the mint that should rewrite them and read through a bounded non-empty wait, and every
"does not contain" assertion over a capture is paired with a control that the capture is non-empty —
an empty file contains no mutant string either, which is how "the flag is absent" and "the file is
absent" rendered identically.

#### Not in this change, and owed

The packaging half is not here: `5dive-api scripts/install/apps.sh` does not yet preinstall
chromium/xvfb/x11vnc/websockify or run `5dive plugin add browser` + `browser setup` at provision time
(DIVE-4238), and the dashboard's Connect/Reconnect tile is not built (DIVE-4239). No real `x11vnc` has
been asked to honour these flags and no human has logged into a real site through a real viewer. Server
mode therefore ships **dark** — reachable by hand on a box that has the packages, not wired to a button.

