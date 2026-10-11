#!/usr/bin/env bash
# DIVE-6013 — profile GROUPS: sites in one group share one browser, so a sign-in
# made once (Google above all) carries to every site in it.
#
# lodar, 2026-10-11: "all signups hit fresh login by google flow". The plugin
# kept one Chrome profile per site, so Google signed in on google.com was not
# signed in for fireflies.ai, and every new site's "Continue with Google" was a
# fresh Google sign-in that Google often refuses under automation.
#
# Driven through the real bin/browser as a subprocess. `auth` with a DISPLAY set
# launches `google-chrome --user-data-dir=<profile> … <url>` itself, so a FAKE
# google-chrome first on PATH is the person at the window: with SIGNIN=1 it
# "signs in to Google" by writing a session into the profile it was handed;
# otherwise it reports whether the profile it was handed already has one.
#
#   G1  a new site joins the default group Main (a link to .group-main)
#   G2  ACCEPT: a second site in the same group sees the session signed in once
#   G3  ACCEPT: a site in another group does not
#   G4  ACCEPT: a per-site profile from before the upgrade resolves unchanged
#   G5  NEGATIVE CONTROL: per-site profiles (today's layout, `default --none`)
#       give the second site no session. With GROUPS_BASELINE_BIN=<old plugin>
#       the same two auths are also run through that build (G5b).
#   G6  a labelled account stays its own profile; one account per site per group
#   G7  move own -> group puts the profile aside; --own brings it back intact
#   G8  create --from keeps a profile's sign-in and its liveness stamp
#   G9  liveness is per site inside a shared group
#   G10 forget of a grouped site removes the site, never the group's browser
#   G11 a link the plugin did not make is refused (rc 77), not followed
#   G12 group ls --json, rename, default
#   G13 a group's browser serves its other sites over one socket (rendezvous
#       name per site), and a stop removes the names it left dangling
#   L   LIVE (CI: real Chrome + the pinned playwright-core): a real
#       accounts.google.com cookie set through site A's profile is in site B's
#       browser when both are in Main, and absent when B is in another group or
#       has its own profile.
set -uo pipefail
printf 'grading tree: %s @ %s\n' "$PWD" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >&2
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/browser/bin/browser"

TMP="$(mktemp -d)"
_KILL=()
trap 'rc=$?; for p in "${_KILL[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0; SKIP=0
arm() {  # arm <name> <expected> <got>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi
}
yn() { if "$@"; then echo yes; else echo no; fi; }

export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/profiles"
export FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/adapters"; mkdir -p "$FIVEDIVE_BROWSER_ADAPTER_DIR"
export FIVEDIVE_BROWSER_SESSION_ROOT="$TMP/no-rendezvous"
export FIVEDIVE_BROWSER_SESSION_DAEMON="$TMP/no-session-daemon"
export FIVEDIVE_BROWSER_CLI="$TMP/no-5dive-cli"
export FIVEDIVE_BROWSER_TMP_ROOT="$TMP/tmproot"
export FIVEDIVE_BROWSER_AUTO_PROPOSE=0 FIVEDIVE_BROWSER_DRIFT_ON_PROBE=0 FIVEDIVE_BROWSER_EVICT_ON_PROBE=0
export DISPLAY=:99
ME="$(id -un)"
SEAT="$FIVEDIVE_BROWSER_PROFILE_ROOT/$ME"
mkdir -p "$SEAT"; chmod 711 "$FIVEDIVE_BROWSER_PROFILE_ROOT"; chmod 700 "$SEAT"
SEEN="$TMP/seen"; export SEEN

# --- the fake chrome: the person at the auth window ---------------------------
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/google-chrome" <<'CHROME'
#!/usr/bin/env bash
[[ "${1:-}" == --version ]] && { echo 'Google Chrome 153.0.8010.36'; exit 0; }
dir=""
for a in "$@"; do case "$a" in --user-data-dir=*) dir="${a#--user-data-dir=}" ;; esac; done
[[ -n "$dir" ]] || exit 0
mkdir -p "$dir/Default"
if [[ "${SIGNIN:-}" == 1 ]]; then
  printf 'accounts.google.com SID=signed-in-once\n' > "$dir/Default/google-session"
fi
printf '%s session=%s\n' "$dir" "$([[ -f "$dir/Default/google-session" ]] && echo yes || echo no)" > "$SEEN"
CHROME
chmod +x "$FAKEBIN/google-chrome"
export PATH="$FAKEBIN:$PATH"

auth() { "$BROWSER" auth "$1" >/dev/null 2>"$TMP/auth.err"; }
session_of() { auth "$1" || { echo "auth-failed:$(tail -1 "$TMP/auth.err")"; return; }; sed -n 's/.* session=//p' "$SEEN"; }
dir_of() { auth "$1" >/dev/null; sed -n 's/ session=.*//p' "$SEEN"; }

# --- G4 setup: a profile made BEFORE the upgrade (today's layout) ------------
mkdir -m 700 "$SEAT/old.test"
printf '2026-10-10T10:00:00Z authenticated\n' > "$SEAT/old.test/.5dive-liveness"
mkdir -p "$SEAT/old.test/Default"; printf 'old-cookie\n' > "$SEAT/old.test/Default/old-marker"

# ================================================================ G1
"$BROWSER" auth a.test >/dev/null 2>"$TMP/a.err"
arm 'G1a a new site joins Main: <seat>/a.test is a link to .group-main' '.group-main' "$(readlink "$SEAT/a.test" 2>/dev/null)"
arm 'G1b the group is a real 0700 dir owned by this seat' "700 $ME" "$(stat -c '%a %U' "$SEAT/.group-main" 2>/dev/null)"
arm 'G1c auth says which group the site joined' 'yes' "$(yn grep -q 'joined the group Main' "$TMP/a.err")"

# ================================================================ G2 (accept)
SIGNIN=1 "$BROWSER" auth a.test >/dev/null 2>&1        # Google signed in ONCE, through a.test
arm 'G2a the sign-in landed in the group profile' 'yes' "$(yn test -f "$SEAT/.group-main/Default/google-session")"
arm 'G2b ACCEPT: b.test (same group) sees the Google session signed in once' 'yes' "$(session_of b.test)"
arm 'G2c b.test is the same browser profile as a.test' "$(readlink -f "$SEAT/a.test")" "$(readlink -f "$(dir_of b.test)")"

# ================================================================ G3 (accept)
out=$("$BROWSER" group create Work 2>&1); rc=$?
arm 'G3a group create Work (rc 0)' '0' "$rc"
"$BROWSER" group default work >/dev/null 2>&1
arm 'G3b ACCEPT: c.test, connected while Work is the default, has no Google session' 'no' "$(session_of c.test)"
arm 'G3c c.test is in Work' '.group-work' "$(readlink "$SEAT/c.test")"
"$BROWSER" group move b.test work >/dev/null 2>&1
arm 'G3d ACCEPT: b.test moved to Work no longer sees Main'"'"'s session' 'no' "$(session_of b.test)"
"$BROWSER" group move b.test main >/dev/null 2>&1
arm 'G3e and back in Main it does again' 'yes' "$(session_of b.test)"
"$BROWSER" group default main >/dev/null 2>&1

# ================================================================ G4 (accept)
arm 'G4a ACCEPT: the pre-upgrade old.test is still a real dir, not a link' 'dir' "$([[ -d "$SEAT/old.test" && ! -L "$SEAT/old.test" ]] && echo dir || echo changed)"
arm 'G4b auth old.test still opens <seat>/old.test' "$SEAT/old.test" "$(dir_of old.test)"
arm 'G4c its own cookies are still there, and it got no Google session from Main' 'old-cookie no' "$(cat "$SEAT/old.test/Default/old-marker") $(session_of old.test)"
arm 'G4d ls still prints its stamp unchanged' 'old.test 2026-10-10T10:00:00Z authenticated' "$("$BROWSER" ls 2>/dev/null | awk '$1=="old.test"{print $1, $2, $3}')"

# ================================================================ G5 (negative control)
"$BROWSER" group default --none >/dev/null 2>&1
SIGNIN=1 "$BROWSER" auth n1.test >/dev/null 2>&1
arm 'G5a NEGATIVE: per-site profiles (default --none) — n2.test sees no session from n1.test' 'no' "$(session_of n2.test)"
arm 'G5b with joining off, a new site is its own profile' 'dir' "$([[ -d "$SEAT/n2.test" && ! -L "$SEAT/n2.test" ]] && echo dir || echo link)"
"$BROWSER" group default main >/dev/null 2>&1
if [[ -n "${GROUPS_BASELINE_BIN:-}" && -x "${GROUPS_BASELINE_BIN}" ]]; then
  SIGNIN=1 "$GROUPS_BASELINE_BIN" auth base1.test >/dev/null 2>&1
  "$GROUPS_BASELINE_BIN" auth base2.test >/dev/null 2>&1
  arm 'G5c NEGATIVE (baseline build): base2.test sees no session from base1.test' 'no' "$(sed -n 's/.* session=//p' "$SEEN")"
else
  SKIP=$((SKIP+1)); echo 'SKIP: G5c baseline build — set GROUPS_BASELINE_BIN=<pre-6013 bin/browser>'
fi

# ================================================================ G6
"$BROWSER" auth a.test_work >/dev/null 2>&1
arm 'G6a a labelled account (a.test_work) gets its own profile' 'dir' "$([[ -d "$SEAT/a.test_work" && ! -L "$SEAT/a.test_work" ]] && echo dir || echo link)"
out=$("$BROWSER" group move a.test_work main 2>&1); rc=$?
arm 'G6b moving it into Main (which has a.test) is refused' '64' "$rc"
arm 'G6c the refusal names the account already there' 'yes' "$(yn grep -q 'already has a.test' <<<"$out")"
out=$("$BROWSER" group move a.test_work work 2>&1); rc=$?
arm 'G6d into Work (no a.test there) it moves' '0 .group-work' "$rc $(readlink "$SEAT/a.test_work")"

# ================================================================ G7
mkdir -m 700 "$SEAT/mine.test"; mkdir -p "$SEAT/mine.test/Default"; printf 'mine\n' > "$SEAT/mine.test/Default/m"
out=$("$BROWSER" group move mine.test main 2>&1); rc=$?
arm 'G7a own -> Main (rc 0, now a link)' '0 .group-main' "$rc $(readlink "$SEAT/mine.test")"
arm 'G7b its own profile is put aside, not merged or deleted' 'mine' "$(cat "$SEAT/.own-mine.test/Default/m" 2>/dev/null)"
arm 'G7c in Main it sees the group session' 'yes' "$(session_of mine.test)"
out=$("$BROWSER" group move mine.test --own 2>&1); rc=$?
arm 'G7d --own brings the old profile back' '0 dir mine' "$rc $([[ -d "$SEAT/mine.test" && ! -L "$SEAT/mine.test" ]] && echo dir || echo link) $(cat "$SEAT/mine.test/Default/m" 2>/dev/null)"
arm 'G7e nothing left aside' 'no' "$(yn test -e "$SEAT/.own-mine.test")"

# ================================================================ G8
mkdir -m 700 "$SEAT/google.test"; mkdir -p "$SEAT/google.test/Default"
printf 'accounts.google.com SID=already\n' > "$SEAT/google.test/Default/google-session"
printf '2026-10-11T01:00:00Z authenticated\n' > "$SEAT/google.test/.5dive-liveness"
out=$("$BROWSER" group create Personal --from=google.test 2>&1); rc=$?
arm 'G8a create --from=google.test (rc 0)' '0' "$rc"
arm 'G8b google.test is now a link to the new group' '.group-personal' "$(readlink "$SEAT/google.test")"
arm 'G8c its sign-in is the group'"'"'s' 'yes' "$(yn grep -q already "$SEAT/.group-personal/Default/google-session")"
arm 'G8d ls keeps its stamp' 'google.test 2026-10-11T01:00:00Z authenticated' "$("$BROWSER" ls 2>/dev/null | awk '$1=="google.test"{print $1, $2, $3}')"
"$BROWSER" group move n2.test personal >/dev/null 2>&1
arm 'G8e a site moved into it sees that sign-in at once' 'yes' "$(session_of n2.test)"

# ================================================================ G9
printf '2026-10-11T02:00:00Z authenticated\n' > "$SEAT/.group-main/.5dive-liveness.a.test"
lsout="$("$BROWSER" ls 2>/dev/null)"
arm 'G9a a.test shows its own stamp' 'authenticated' "$(awk '$1=="a.test"{print $3}' <<<"$lsout")"
arm 'G9b b.test (same group) does not inherit it' 'never probed' "$(awk '$1=="b.test"{print $2, $3}' <<<"$lsout")"

# ================================================================ G10
out=$("$BROWSER" forget b.test 2>&1); rc=$?
arm 'G10a forget b.test (rc 0)' '0' "$rc"
arm 'G10b b.test is gone' 'no' "$(yn test -e "$SEAT/b.test")"
arm 'G10c Main and a.test are untouched (still signed in)' 'yes yes' "$(yn test -L "$SEAT/a.test") $(yn test -f "$SEAT/.group-main/Default/google-session")"
arm 'G10d the message says the group keeps its other sign-ins' 'yes' "$(yn grep -q 'removed it from Main' <<<"$out")"

# ================================================================ G11
mkdir -m 700 "$TMP/elsewhere"
ln -s "$TMP/elsewhere" "$SEAT/evil.test"
out=$("$BROWSER" auth evil.test 2>&1); rc=$?
arm 'G11 a link the plugin did not make is refused (rc 77), never opened' '77' "$rc"
rm -f "$SEAT/evil.test"

# ================================================================ G12
j="$("$BROWSER" group ls --json 2>/dev/null)"
arm 'G12a json: default is main' 'main' "$(jq -r .default <<<"$j")"
arm 'G12b json: Main lists its sites' 'a.test' "$(jq -r '[.groups[]|select(.id=="main")|.sites[]]|join(",")' <<<"$j")"
arm 'G12c json: Work has c.test and a.test_work' 'a.test_work,c.test' "$(jq -r '[.groups[]|select(.id=="work")|.sites[]]|sort|join(",")' <<<"$j")"
arm 'G12d json: own profiles listed' 'yes' "$(jq -r '(.own|index("old.test"))!=null' <<<"$j" | sed 's/true/yes/')"
"$BROWSER" group rename work "Work stuff" >/dev/null 2>&1
arm 'G12e rename keeps the id, changes the name' 'Work stuff' "$("$BROWSER" group ls --json | jq -r '.groups[]|select(.id=="work")|.name')"
arm 'G12f a group is addressed by its name too' '0' "$("$BROWSER" group move c.test 'work stuff' >/dev/null 2>&1; echo $?)"

# ================================================================ G13
if command -v python3 >/dev/null 2>&1; then
  RV="$TMP/rv"; mkdir -p "$RV/$ME"; chmod 711 "$RV"; chmod 770 "$RV/$ME"
  python3 -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); time.sleep(600)' "$RV/$ME/a.test.sock" &
  _KILL+=($!); SOCKPID=$!
  sleep 300 & _KILL+=($!); XP=$!
  for _ in $(seq 50); do [[ -S "$RV/$ME/a.test.sock" ]] && break; sleep 0.1; done
  printf 'xvfb_pid=%s\ndaemon_pid=%s\ndisplay=77\nsock=%s\n' "$XP" "$SOCKPID" "$RV/$ME/a.test.sock" > "$SEAT/.group-main/.5dive-serve"
  "$BROWSER" group move c.test main >/dev/null 2>&1
  out=$(FIVEDIVE_BROWSER_SESSION_ROOT="$RV" "$BROWSER" serve c.test 2>&1); rc=$?
  arm 'G13a serve of another site in a served group: already serving (rc 0)' '0' "$rc"
  arm 'G13b its rendezvous name points at the group'"'"'s socket' 'a.test.sock' "$(readlink "$RV/$ME/c.test.sock" 2>/dev/null)"
  arm 'G13c and reaches it' 'yes' "$(yn test -S "$RV/$ME/c.test.sock")"
  FIVEDIVE_BROWSER_SESSION_ROOT="$RV" FIVEDIVE_BROWSER_STOP_GRACE=1 "$BROWSER" serve a.test --stop >/dev/null 2>&1
  arm 'G13d a stop removes the name it left dangling' 'no' "$(yn test -L "$RV/$ME/c.test.sock")"
else
  SKIP=$((SKIP+1)); echo 'SKIP: G13 — no python3 to hold a unix socket'
fi

# ================================================================ L  LIVE
NOFAKE="${PATH#"$FAKEBIN:"}"
REAL_CHROME="$(PATH="$NOFAKE" command -v google-chrome || PATH="$NOFAKE" command -v chromium || true)"
PW_OK=no; [[ -d "$ROOT/browser/node_modules/playwright-core" ]] && PW_OK=yes
if [[ -z "$REAL_CHROME" || "$PW_OK" != yes ]]; then
  if [[ -n "${CI:-}" ]]; then
    FAIL=$((FAIL+1)); printf 'FAIL: L live arms are owed in CI — chrome: %s, playwright-core: %s\n' "${REAL_CHROME:-none}" "$PW_OK"
  else
    SKIP=$((SKIP+1)); printf 'SKIP: L live arms — chrome: %s, playwright-core next to the plugin: %s (CI runs them)\n' "${REAL_CHROME:-none}" "$PW_OK"
  fi
else
  # The person at the window, for real: a Chrome on the profile `auth` handed
  # over. SIGNIN=1 signs in to Google the way a sign-in leaves it — a persistent
  # cookie on .google.com; otherwise it reports whether that browser has one.
  cat > "$TMP/live.cjs" <<'JS'
const { chromium } = require(process.argv[2]);
const [, , , exe, dir, out] = process.argv;
(async () => {
  const ctx = await chromium.launchPersistentContext(dir, { executablePath: exe, headless: true, args: ['--no-sandbox'] });
  if (process.env.SIGNIN === '1') {
    await ctx.addCookies([{ name: 'SID', value: 'signed-in-once', domain: '.google.com', path: '/',
      expires: Math.floor(Date.now() / 1000) + 86400, secure: true, httpOnly: true, sameSite: 'None' }]);
  }
  const has = (await ctx.cookies('https://accounts.google.com/')).some(c => c.name === 'SID' && c.value === 'signed-in-once');
  await ctx.close();
  require('fs').writeFileSync(out, has ? 'yes' : 'no');
})().catch(e => { require('fs').writeFileSync(out, 'error: ' + e.message); process.exit(1); });
JS
  LIVEBIN="$TMP/livebin"; mkdir -p "$LIVEBIN"
  cat > "$LIVEBIN/google-chrome" <<CHROME
#!/usr/bin/env bash
[[ "\${1:-}" == --version ]] && exec "$REAL_CHROME" --version
dir=""
for a in "\$@"; do case "\$a" in --user-data-dir=*) dir="\${a#--user-data-dir=}" ;; esac; done
exec node "$TMP/live.cjs" "$ROOT/browser/node_modules/playwright-core" "$REAL_CHROME" "\$dir" "$TMP/live.out"
CHROME
  chmod +x "$LIVEBIN/google-chrome"
  export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/live-profiles"
  LSEAT="$FIVEDIVE_BROWSER_PROFILE_ROOT/$ME"; mkdir -p "$LSEAT"; chmod 711 "$FIVEDIVE_BROWSER_PROFILE_ROOT"; chmod 700 "$LSEAT"
  live() { rm -f "$TMP/live.out"; PATH="$LIVEBIN:$NOFAKE" "$BROWSER" auth "$1" >/dev/null 2>"$TMP/live.err"; cat "$TMP/live.out" 2>/dev/null || echo "none: $(tail -2 "$TMP/live.err")"; }
  arm 'L1a real Chrome: Google signed in once through fireflies.test (Main)' 'yes' "$(SIGNIN=1 live fireflies.test)"
  arm 'L1b ACCEPT: fathom.test in Main has that Google cookie in its browser' 'yes' "$(live fathom.test)"
  PATH="$LIVEBIN:$NOFAKE" "$BROWSER" group create Second >/dev/null 2>&1
  PATH="$LIVEBIN:$NOFAKE" "$BROWSER" group default second >/dev/null 2>&1
  arm 'L2 ACCEPT: otter.test in another group does not' 'no' "$(live otter.test)"
  PATH="$LIVEBIN:$NOFAKE" "$BROWSER" group default --none >/dev/null 2>&1
  arm 'L3 NEGATIVE: grain.test with its own profile (the old layout) does not' 'no' "$(live grain.test)"
fi

printf '\n%d pass, %d fail, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
