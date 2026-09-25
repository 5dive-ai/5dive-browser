# 5dive browser — changelog

One plugin, one repo, one changelog. Entries before 2026-09-20 were carried over from
`5dive-ai/5dive-plugins/CHANGES.md`, which browser shared with telegram, dashboard, buzz and
voice — every two PRs to that file collided trivially, and splitting it is the reason this repo
exists (DIVE-4661). Only the sections that named a `browser <version>` came across; the rest of
that file stays where it is.

## Unreleased

## Released

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

