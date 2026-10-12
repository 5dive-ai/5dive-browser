# 5dive browser

Persistent human-authenticated browser sessions for Claude Code and the 5dive CLI. You log into a
site **once, by hand**; the agent is granted the session and never the credentials, and
deterministic adapters decide where to click. A security challenge is a hard stop that asks for a
person — the plugin never solves one.

## Run it on your own server

Tested on fresh Ubuntu 24.04 (2 vCPU / 4 GB) at OVH and Hetzner. You need a sudo user and your own
Claude or OpenAI subscription or API key.

**1. Install.** Three lines. The first agent's `browser setup` (which `init` runs for it) installs
whatever the box is missing: Google Chrome, a virtual screen, VNC, Node.js 22 and the plugin's
browser library. Each install is named as it runs, and on apt boxes only (Debian, Ubuntu).

```sh
curl -fsSL https://install.5dive.ai | sudo bash
sudo 5dive plugin add 5dive-ai/5dive-browser
sudo 5dive init     # your first agent; run it AFTER the plugin so the agent gets a browser
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

**3. Let the agent use it.**

```sh
sudo -u $A 5dive browser serve $S --stop                             # saves the session
sudo -u $A 5dive browser snapshot https://github.com/notifications   # what the agent runs
```

From then on the agent opens pages through that session itself. Nothing listens on the internet:
the VNC server and its bridge bind to `127.0.0.1`, and the only way in is your SSH tunnel.

- A read that says "logged out": sign in again and wait longer before `--stop`. A site that signs
  you out when the browser closes will not stay signed in; tick "remember me".
- An agent created before the plugin has no browser yet. Give it one, as root:
  `SUDO_USER=agent-myagent 5dive browser setup`.
- github.com, reddit.com, x.com, google.com, booking.com, tiktok.com and web.telegram.org ship a
  sign-in check. Other sites are checked at their home page, so a home page that always shows a
  login form reads as logged out.

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
the stack when it is missing (DIVE-6089): Google Chrome, `xvfb x11vnc websockify`, Node.js 22 from
NodeSource when node is missing or older than 20, and the pinned playwright-core — apt boxes only,
each install named, nothing touched that is already there. `agent create` runs `setup` for each
new seat, so on a box where the plugin is added before `5dive init` it happens with no extra line.

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

## History

Extracted from `5dive-ai/5dive-plugins` (`plugins/browser`) on 2026-09-20 with its commit history
intact (DIVE-4661). The registry keeps a deprecation entry so `plugin add browser` keeps resolving
for boxes installed before the move.

MIT licensed. Part of [5dive](https://5dive.ai).
