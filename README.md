# 5dive browser

Persistent human-authenticated browser sessions for Claude Code and the 5dive CLI. You log into a
site **once, by hand**; the agent is granted the session and never the credentials, and
deterministic adapters decide where to click. A security challenge is a hard stop that asks for a
person — the plugin never solves one.

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
