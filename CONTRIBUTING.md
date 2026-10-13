# Contributing

Bug reports, site checks and fixes are welcome.

## Report a bug

Open an issue with:

- what you ran (`5dive browser …`) and the full output, including the exit code
- the site, and whether it was signed in or public
- your OS, `google-chrome --version` and the plugin version (`browser/.claude-plugin/plugin.json`)

Never paste a session cookie, a VNC password, a one-time link or a screenshot of a signed-in page
with your details on it.

A robot check or captcha on a site is not a bug. The plugin stops and asks a person on purpose and
will not solve one.

## Make a change

1. Fork, branch from `main`, keep the change to one thing.
2. Run the graded suite. It is plain bash, with a fake Chrome first on `PATH`, so it needs no
   browser and no server:

   ```sh
   bash tests/browser_plugin_unit.sh
   ```

   CI runs that plus the other `tests/*_unit.sh` harnesses on every pull request. Some
   input-mode arms drive a real Xvfb and Chrome, which the CI runner has. The `*_bench.sh` files
   are benchmarks, not gates.
3. A change in behaviour gets a test that fails without it, and an entry under `## Unreleased` in
   `CHANGES.md` that says what a user sees now.
4. Open the pull request against `main` and say what you ran.

## Rules the code keeps

- The agent gets the session, never the password.
- A security challenge is a hard stop for a person, never something to get around.
- Paying asks the owner by default. A step that pays, posts, sends or deletes must say so, and
  that is never left off to get past an ask.
- Nothing listens on the internet. The viewer and its bridge bind to `127.0.0.1`.

A pull request that weakens one of these will not be merged.

## License

By contributing you agree your work is licensed under Apache 2.0, the same as the rest of the repo
(see `LICENSE`).
