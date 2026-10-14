# 5dive browser

**Your agent needs your logged-in accounts. It should never have your passwords.**

5dive browser gives agents on Claude Code and the 5dive CLI persistent, human-authenticated browser
sessions. You sign in to a site once, by hand, in a real Chrome on your own server. Your agent gets
that session and never the password. A robot check (a CAPTCHA, an "unusual activity" page) is a hard
stop that hands the window to you, and before a step that pays, the agent asks you first.

```
 1. You sign in once, by hand     Chrome on your server, reached over VNC through SSH.
                                  The session is saved in a profile on the box.
          │
          ▼
 2. Your agent uses the session   "check my GitHub notifications": it opens the page
                                  signed in as you. It never sees the password.
          │
          ├─ a robot check?       Hard stop. You get the steps to its live window.
          ├─ about to pay?        It asks you first, with a screenshot.
          ▼
 3. The next run                  Still signed in. No new sign-in, no password.
```

## Try it on your own server

Tested on fresh Ubuntu 24.04 (2 vCPU / 4 GB) at OVH and Hetzner. You need a sudo user and your own
Claude or OpenAI subscription or API key.

**1. Install.** Four lines. `browser setup` installs whatever the box is missing, one numbered
step at a time, each install named as it runs (apt boxes only: Debian, Ubuntu). Agents you hire
after it get a browser.

```sh
curl -fsSL https://install.5dive.ai | sudo bash
sudo 5dive plugin add 5dive-ai/5dive-browser
sudo 5dive browser setup   # installs Chrome, a virtual screen, VNC and Node 22
sudo 5dive init            # your first agent; run it AFTER setup so the agent gets a browser
```

**2. Sign in to a site once, by hand.** Chrome runs on the box's virtual screen, and you reach it
over VNC through SSH:

```sh
cd /tmp
A=agent-myagent   # your agent's Linux user: agent-<the name you gave it>
S=github.com      # the site
sudo -u $A 5dive browser auth $S                 # starts Chrome for a person to sign in
sudo -u $A 5dive browser viewer $S --bind=local  # VNC on the box's 127.0.0.1:5900, one connection
sudo cat /var/lib/5dive/browser-profiles/$A/$S/.5dive-viewer.pw   # its one-time password
```

On your laptop, run `ssh -N -L 5900:127.0.0.1:5900 you@your-box`, open `vnc://localhost:5900`
(Screen Sharing on a Mac, or any VNC client), and sign in. Wait about 30 seconds after you are
signed in, then close the window.

When an agent needs you in the middle of a job (a sign-in, a robot check), `5dive browser handoff`
sends you these same steps for its live window, already filled in, on Telegram if the agent is
paired. Otherwise it prints them.

**Optional: a login link instead of SSH.** If you would rather tap a link on your phone, turn on
login links. They are off until you do, and the command lists the choices with their trade-offs:

```sh
sudo 5dive browser login-link                   # the choices
sudo 5dive browser login-link enable --via=ip   # recommended: a free certificate for the box's own IP
```

| `--via` | What it is | Trade-off |
|---|---|---|
| `ip` (recommended) | A Let's Encrypt certificate for the box's own IP address | No third party sees the login. Needs a public IPv4 address and ports 80 and 443 open |
| `domain --host=<name>` | Your own domain, pointed at the box | You trust only your own DNS. Needs ports 80 and 443 open |
| `sslip` | `<ip>.sslip.io`, a free name service | The service's operator could redirect the name and read what you type, and its shared certificate quota fails at random. Use it only if `ip` does not work |
| `proxy --host=<name>` | Your own HTTPS front, e.g. Tailscale Funnel (works behind NAT) | Forward `/browser/viewer/` to `http://127.0.0.1:3111`. Nothing is installed on 80 or 443 |

A Cloudflare quick tunnel is not offered: Cloudflare would see every keystroke. Once a login link is
on, an agent's `connect-request` and `handoff` send you a one-time link for the live window, and
port 443 answers only `/browser/viewer/*` (everything else is a 404). `sudo 5dive browser
login-link disable` turns it off. A box 5dive hosts already has its own domain and does not need
any of this.

**3. Let the agent use it.**

```sh
sudo -u $A 5dive browser serve $S --stop                             # saves the session
sudo -u $A 5dive browser snapshot https://github.com/notifications   # what the agent runs
```

From then on the agent opens pages through that session itself. Nothing listens on the internet:
the VNC server and its bridge bind to `127.0.0.1`, and the only way in is your SSH tunnel (or,
if you turned it on, a one-time login link).

- A read that says "logged out": sign in again and wait longer before `--stop`. A site that signs
  you out when the browser closes will not stay signed in; tick "remember me".
- An agent created before the plugin has no browser yet. Give it one, as root:
  `SUDO_USER=agent-myagent 5dive browser setup`.
- github.com, reddit.com, x.com, google.com, booking.com, tiktok.com and web.telegram.org ship a
  sign-in check. Other sites are checked at their home page, so a home page that always shows a
  login form reads as logged out.

**4. Ask it something only your account can see.** Message your agent (on Telegram, if you paired
it in `init`):

> Check my GitHub notifications and tell me which ones need a reply from me.

What you should notice:

- It answers from **your** notifications, signed in as you. You typed your password into Chrome,
  never into a chat, a config file or a prompt.
- Ask again tomorrow and it does not ask you to sign in again. The session stays on the box
  across runs for as long as the site keeps you signed in.
- Ask it to buy something and it stops before paying and asks you, with a screenshot of what it is
  about to pay.

## Good at

Jobs a sandboxed browser cannot do, because they need **your** account:

- Reading what is waiting for you: GitHub notifications, an inbox, the messages on a site with no
  API, and telling you what needs you.
- Posting a reply, an issue or a comment under your account. It runs and is logged; set the
  `careful` policy (below) and the agent asks you before each one.
- Filling in a form behind a login: a supplier portal, an admin panel, a booking.
- Getting an export out of a dashboard you are signed in to: a click on Download hands the agent
  the file.
- Filling a cart and stopping at the payment for your yes.
- Doing the same job every day: record the steps once, and later runs replay them without
  re-reading every page.

## How it compares

| | 5dive browser | Playwright MCP | Claude in Chrome | browser-use | Browserbase |
|---|---|---|---|---|---|
| Signed-in sessions persist across runs | Yes | Yes, a persistent profile by default | Yes, it is your own Chrome | Yes, if you reuse a profile | Yes, with a persisted Context |
| You sign in by hand; the model never sees the password | Yes | Yes, in the headed browser | Yes | Yes, by reusing a profile | Yes, through live view |
| A robot check stops and hands off to a person | Yes, it is never solved | Not documented | Yes, it pauses for you | Not documented | No, it solves CAPTCHAs by default (can be turned off) |
| Asks you before paying, by default | Yes, with a screenshot | Not documented | Partly: asks before financial sites | Not documented | Not documented |
| Runs on your own server | Yes (Debian, Ubuntu) | Yes | No, it needs your desktop Chrome | Yes | No, a hosted cloud |

The second row is a tie, and that is the point: every tool here can keep the password away from
the model. What differs is what happens around the session: who handles a robot check, whether
paying waits for you, and whether it runs on a box you own while your laptop is closed.

Checked against each project's own docs on 2026-10-14
([Playwright MCP](https://github.com/microsoft/playwright-mcp),
[Claude in Chrome](https://code.claude.com/docs/en/chrome),
[browser-use](https://docs.browser-use.com/customize/examples/sensitive-data),
[Browserbase](https://docs.browserbase.com/platform/identity/captcha-solving)). If a cell is out
of date, open an issue and we will fix it.

## What your agent gets

Two skills come with the plugin, and the agent picks them up on its own:

- **use-browser**: "go to <site> and …" work in a real Chrome on the box. It clicks, types, fills
  forms and checks pages, signed in or not.
- **connect-site**: when a job needs your own account on a site, it asks you to sign in once, then
  uses that session.

Before a step that pays, the agent stops and asks you, with a screenshot and what it is about to
pay. On a paired agent the ask comes to Telegram with Approve and Decline. An ask nobody answers
expires after 30 minutes, and a yes covers exactly those steps, once. Posting, sending and deleting
run without asking and are logged. To be asked before those too:

```sh
sudo 5dive browser approvals policy set careful   # ask before paying, posting, sending and deleting
```

Want an agent built for this? [Clicker](https://github.com/5dive-ai/5dive-marketplace/tree/main/packs/clicker)
is the ready-made browser operator in the 5dive marketplace, and she starts with lessons from her own
browser jobs: `5dive agent import clicker --as=<name>`.

## Install

```sh
5dive plugin add 5dive-ai/5dive-browser
```

**Use the qualified `<owner>/<repo>` name, not a bare `browser`.** A bare plugin name is resolved
per marketplace, and a box that knows two marketplaces offering that name refuses the add (`exists
in N marketplaces`) — most boxes in the fleet still carry the bundled `5dive` marketplace next to
`5dive-plugins`, so the bare form is already ambiguous there.

**A box that already has `browser@5dive-plugins` must remove or disable it first.** The CLI refuses
two plugins claiming the same verb (`_plugin_verb_install_check`, rc=3) and the refusal is
symmetric, so the migration is explicit and two commands:

```sh
sudo 5dive plugin remove browser@5dive-plugins
sudo 5dive plugin add 5dive-ai/5dive-browser
```

A fresh box has no claim and installs in the one command above.

**The migration is a forward step, and that is checked rather than assumed.** `plugin add
<owner>/<repo>` is a fresh add with no version comparison, and the remove above has to come
first, so nothing in the mechanism would stop a migration from installing something OLDER than
what it removed. This repo is kept strictly ahead of `browser@5dive-plugins` for exactly that
reason — 1.9.1 here against the registry's 1.9.0 — with `bin/browser` byte-identical to the
registry copy (DIVE-4719).

## The plugin is only half of the browser capability

| half | what it is | where it lives | who installs it |
|---|---|---|---|
| **plugin** (this repo) | `browser/bin/browser`, the adapters, the `connect-site` skill, the `browser-profiles` grant | `5dive-ai/5dive-browser` | `5dive plugin add`, **per seat** |
| **stack** | Chrome, the viewer, the ticket store | `scripts/inc/browser-stack.sh` in `5dive-api` | `install.sh`, **as root, per box** |

The stack did **not** move here and must not: it is installed at provision time by the box
installer, and taking it with the plugin re-opens DIVE-4347 (*"no box in the fleet has the 5dive
browser verb"*) on every new box. After installing the plugin, a box still needs:

```sh
sudo 5dive browser setup
```

On a **self-hosted** box, which never runs `browser-stack.sh`, that same command also installs
the stack when it is missing (DIVE-6089, DIVE-6112): Google Chrome, a virtual screen and VNC,
Node.js 22 when node is missing or older than 20, and the pinned playwright-core, in four numbered
steps, each install named, apt boxes only, nothing touched that is already there. It is the only
place the stack is installed: `agent create` runs `setup` for each new seat and installs nothing,
and on a box without the stack it says to run `sudo 5dive browser setup`.

## Layout

```
.claude-plugin/marketplace.json   one-entry marketplace — this repo IS the marketplace
browser/                          the plugin; `source: "./browser"` points here
browser/.claude-plugin/plugin.json
browser/bin/browser               the verb
tests/browser_plugin_unit.sh      the harness CI runs on every PR
```

The plugin lives in its own subdirectory rather than at the repo root on purpose. Contract §1
requires the manifest `name` to equal its **folder** name, and `"source": "./"` resolves to the
marketplace root — whose name is derived from the *repo* name. A root-level plugin here would be
asked to be called `5dive-browser` and would fail `rc=3` before anything was fetched. The
subdirectory shape installs whatever the repo is called.

## Development

```sh
bash tests/browser_plugin_unit.sh      # the graded suite; needs no Chrome and no box
```

`tests/browser_session_bench.sh` and `tests/browser_snapshot_bench.sh` are benchmarks, not gates —
they want a real Chrome and are not run by CI.

To report a bug or send a change, see [CONTRIBUTING.md](CONTRIBUTING.md).

## History

Extracted from `5dive-ai/5dive-plugins` (`plugins/browser`) on 2026-09-20 with its commit history
intact (DIVE-4661). The registry keeps a deprecation entry so `plugin add browser` keeps resolving
for boxes installed before the move.

Apache 2.0 licensed (see LICENSE). Part of [5dive](https://5dive.ai).
