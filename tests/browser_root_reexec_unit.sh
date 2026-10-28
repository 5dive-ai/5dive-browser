#!/usr/bin/env bash
# DIVE-7183 — a box-wide browser change run without sudo re-runs itself through
# `sudo -n` when the seat holds the grant, and otherwise names the admin colleague
# who can (DIVE-7172's voice fix). A fake sudo (FIVEDIVE_SUDO) answers the
# `-n -l` probe from FAKE_GRANT and records what a real re-run would have run.
# FIVEDIVE_PLUGIN_DIR marks the copy the CLI dispatched, the only one that
# re-runs. Non-root arms; as root the check passes on its own.
#
#   bash tests/browser_root_reexec_unit.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BROWSER="$ROOT/browser/bin/browser"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
t() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL - %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
yn() { if grep -qF -- "$1"; then echo yes; else echo no; fi; }

if (( EUID == 0 )); then printf 'note: running as root — these arms need a non-root caller (CI runs as one)\n'; exit 0; fi

cat > "$TMP/sudo" <<'S'
#!/usr/bin/env bash
if [[ "$1" == -n && "$2" == -l ]]; then shift 2; printf 'PROBE %s\n' "$*" >>"$FAKE_LOG"; [[ "${FAKE_GRANT:-0}" == 1 ]]; exit; fi
if [[ "$1" == -n ]]; then shift; printf 'EXEC %s\n' "$*" >>"$FAKE_LOG"; echo REEXECED; exit 0; fi
exit 9
S
cat > "$TMP/cli" <<'S'
#!/usr/bin/env bash
[[ "$*" == "agent list --json" ]] || exit 3
printf '%s\n' "${FAKE_AGENTS:-{\"data\":[]}}"
S
chmod 755 "$TMP/sudo" "$TMP/cli"
AGENTS='{"data":[{"name":"a","active":"inactive","sudo":{"impliedIsolation":"admin"}},{"name":"b","active":"active","sudo":{"impliedIsolation":"standard"}},{"name":"c","active":"active","sudo":{"impliedIsolation":"admin"}},{"name":"d","active":"active","sudo":{"impliedIsolation":"beyond-admin"}}]}'

# run <grant> <plugin dir> <args...>
run() { local g="$1" pd="$2"; shift 2; : >"$TMP/log"
  ( export FAKE_LOG="$TMP/log" FAKE_GRANT="$g" FIVEDIVE_SUDO="$TMP/sudo" FIVEDIVE_BIN=/opt/5dive \
      FIVEDIVE_BROWSER_CLI="$TMP/cli" FAKE_AGENTS="${AGENTS_FOR:-}" HOME="$TMP" \
      FIVEDIVE_STATE_DIR="$TMP/state" FIVEDIVE_BROWSER_DRIVE_DEFAULT_FILE="$TMP/drive-default"
    [[ -n "$pd" ]] && export FIVEDIVE_PLUGIN_DIR="$pd"
    "$BROWSER" "$@" ) </dev/null >"$TMP/out" 2>"$TMP/err"; printf '%s' "$?"; }
PD="$ROOT/browser"

# E) granted: the same argv, through sudo -n, via the installed CLI
for argv in "config drive=input" "adblock off example.com" "login-link disable" "login-link enable --via=ip" "setup"; do
  # shellcheck disable=SC2086
  rc=$(run 1 "$PD" $argv)
  t "E: '$argv' granted -> exec sudo -n /opt/5dive browser $argv (rc 0)" \
    "0 yes yes" "$rc $(yn "PROBE /opt/5dive browser $argv" <"$TMP/log") $(yn "EXEC /opt/5dive browser $argv" <"$TMP/log")"
done
rc=$(FIVEDIVE_JSON_MODE=1 run 1 "$PD" config drive=cdp)
t "E: --json (forwarded by the CLI as FIVEDIVE_JSON_MODE) rides the re-run" yes "$(yn 'EXEC /opt/5dive --json browser config drive=cdp' <"$TMP/log")"

# B) a copy the CLI did not dispatch never probes or sudo-runs
rc=$(run 1 "" config drive=input)
t "B: run directly (no FIVEDIVE_PLUGIN_DIR) -> refused 77, no probe" "77 0" "$rc $(wc -l <"$TMP/log" | tr -d ' ')"
rc=$(run 1 "$TMP/elsewhere" config drive=input)
t "B: a plugin dir that is not this file's -> no probe" "77 0" "$rc $(wc -l <"$TMP/log" | tr -d ' ')"
t "B: and nothing was written" no "$([[ -e "$TMP/drive-default" ]] && echo yes || echo no)"

# N) no grant: who can, never the owner
rc=$(AGENTS_FOR="$AGENTS" run 0 "$PD" adblock on example.com)
e=$(cat "$TMP/err")
t "N: no grant -> rc 77, no re-run" "77 no" "$rc $(yn EXEC <"$TMP/log")"
t "N: names only RUNNING admin seats, the lead first" yes "$(yn 'who has it (d, c)' <<<"$e")"
t "N: with a ready agent send line" yes "$(yn '5dive agent send d "My owner asked for this and it needs root. Please run: sudo 5dive browser adblock on example.com"' <<<"$e")"
t "N: tells the agent not to hand its owner a command" yes "$(yn 'Do not ask your owner to run anything' <<<"$e")"
t "N: no 'Run: sudo' line" no "$(yn 'Run: sudo' <<<"$e")"
rc=$(run 0 "$PD" config drive=input)
t "N: no admin colleague -> says it cannot be done from this agent" "77 yes" "$rc $(yn 'cannot be done from this agent' <"$TMP/err")"

# L) never from a subshell: the exec would run the whole verb a second time
: >"$TMP/log"
o=$(FAKE_LOG="$TMP/log" FAKE_GRANT=1 FIVEDIVE_SUDO="$TMP/sudo" FIVEDIVE_PLUGIN_DIR="$PD" FIVEDIVE_BROWSER_CLI="$TMP/cli" \
    bash -c 'source <(sed -n "/^as_root() {/,/^}/p;/^no_root() {/,/^}/p" "$1"); PROG=x; E_PERM=77; _SELF_DIR="$2/bin"
             BROWSER_ARGV=(config drive=input); BROWSER_SUDO="$FIVEDIVE_SUDO"; BROWSER_ROOT_BIN=/opt/5dive
             x=$(as_root "it"); echo "RC=$?"' _ "$BROWSER" "$PD" 2>&1)
t "L: as_root inside \$(…) refuses instead of re-running" "yes no" "$(yn RC=77 <<<"$o") $(yn EXEC <"$TMP/log")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
