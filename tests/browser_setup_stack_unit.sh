#!/usr/bin/env bash
# DIVE-6089 — `sudo 5dive browser setup` installs the box stack a self-hosted box
# lacks (chrome, Xvfb, x11vnc, websockify, Node >= 20, the pinned playwright-core),
# and touches nothing on a box that already has it (every hosted VM).
#
# DIVE-6112 — only a PERSON installs. setup is driven as its three callers:
#   root   `sudo 5dive browser setup` with no SUDO_USER: the box, exits 0, no store
#   person the same line from a sudo user (SUDO_USER = that seat): stack + its store
#   hire   agent create/import (FIVEDIVE_BROWSER_SEAT set): installs nothing, names it
#
# Driven through the real bin/browser as a subprocess. Nothing real is installed:
# apt-get, curl, gpg, dpkg and npm are fakes on a SANDBOX PATH that holds only the
# core tools setup needs — a CI runner ships its own chrome, Xvfb and node, and a
# PATH that could see them would grade the runner instead of setup. The fake
# apt-get "installs" a package by dropping its binary into the sandbox, so every
# predicate setup re-checks after an install reads the box it would really see.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }
tn() { if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected NOT to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }
SEAT="$(id -un)"
PIN=$(sed -n 's/.*"playwright-core"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' browser/package.json)
t 'T0 the package pins a playwright-core (anchor)' yes "$([[ "$PIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo yes || echo no)"

# --- the sandbox -------------------------------------------------------------
CORE="$TMP/core"; mkdir -p "$CORE"
REALID="$(command -v id)"
for c in bash env sed head tail paste mkdir chmod chown cat rm cp mv ln stat grep awk timeout \
         tr sort date mktemp dirname basename readlink realpath uname wc cut tee touch sleep \
         jq getent printf ls find xargs flock pgrep sha256sum; do
  p=$(command -v "$c" 2>/dev/null) && [[ "$p" == /* ]] && ln -sf "$p" "$CORE/$c"
done
cat > "$CORE/id" <<ID
#!$(command -v bash)
[[ "\$*" == "-u" ]] && { echo 0; exit 0; }
[[ "\$*" == "-un" && -n "\${FAKE_UN:-}" ]] && { echo "\$FAKE_UN"; exit 0; }
exec "$REALID" "\$@"
ID
for c in systemctl visudo 5dive; do printf '#!%s\nexit 0\n' "$(command -v bash)" > "$CORE/$c"; done
cat > "$CORE/dpkg" <<'DPKG'
#!/usr/bin/env bash
# --print-architecture, and `-s libnode-dev` answered from a marker in the box.
[[ "$1" == --print-architecture ]] && { echo amd64; exit 0; }
[[ "$1" == -s && "$2" == libnode-dev && -e "$BOX_DIR/.libnode-dev" ]] && exit 0
exit 1
DPKG
printf '#!%s\necho "curl $*" >> "$STACK_LOG"; echo FAKEKEY\n' "$(command -v bash)" > "$CORE/curl"
cat > "$CORE/gpg" <<'GPG'
#!/usr/bin/env bash
o=""; while (($#)); do [[ "$1" == -o ]] && { o="$2"; shift; }; shift; done
cat > "${o:-/dev/null}"
GPG
chmod +x "$CORE/id" "$CORE/systemctl" "$CORE/visudo" "$CORE/5dive" "$CORE/dpkg" "$CORE/curl" "$CORE/gpg"

# The fake apt-get. `install <pkg>...` drops each package's binaries into $BOX
# unless APT_FAIL names it. NODE_VER is what the installed nodejs answers.
mk_node() {  # mk_node <version> — a node (and npm) on the sandbox PATH
  printf '#!%s\necho v%s\n' "$(command -v bash)" "$1" > "$BOX/node"; chmod +x "$BOX/node"
  cat > "$BOX/npm" <<'NPM'
#!/usr/bin/env bash
echo "npm $*" >> "$STACK_LOG"
d=""; a=("$@"); for ((i=0;i<${#a[@]};i++)); do [[ "${a[i]}" == --prefix ]] && d="${a[i+1]}"; done
[[ -n "$d" && "$1" == install ]] || exit 1
mkdir -p "$d/node_modules/playwright-core"
printf '{\n  "name": "playwright-core",\n  "version": "%s"\n}\n' "${NPM_VERSION:?}" > "$d/node_modules/playwright-core/package.json"
exit "${NPM_RC:-0}"
NPM
  chmod +x "$BOX/npm"
}
cat > "$CORE/apt-get.real" <<'APT'
#!/usr/bin/env bash
echo "apt-get $*" >> "$STACK_LOG"
BOX="$BOX_DIR"; sub=""; pk=()
for a in "$@"; do case "$a" in -*|DPkg::*) ;; update|install|remove) sub="$a" ;; *) [[ -n "$sub" ]] && pk+=("$a") ;; esac; done
# Ubuntu's libnode-dev blocks NodeSource's nodejs (dpkg overwrite); remove clears it.
[[ "$sub" == remove ]] && { for p in "${pk[@]}"; do [[ "$p" == libnode-dev ]] && rm -f "$BOX/.libnode-dev"; done; exit 0; }
[[ "$sub" == install ]] || exit 0
rc=0
for p in "${pk[@]}"; do
  [[ " ${APT_FAIL:-} " == *" $p "* ]] && { rc=100; continue; }
  [[ "$p" == nodejs && -e "$BOX/.libnode-dev" ]] && { rc=100; continue; }
  case "$p" in
    xvfb) b=(Xvfb) ;; google-chrome-stable) b=(google-chrome-stable) ;; nodejs) b=() ;;
    *) b=("$p") ;;
  esac
  for x in "${b[@]}"; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BOX/$x"; chmod +x "$BOX/$x"; done
  [[ "$p" == nodejs ]] && { "$MK_NODE" "${NODE_VER:-22.11.0}"; }
done
exit "$rc"
APT
chmod +x "$CORE/apt-get.real"
MK_NODE="$TMP/mk_node"
{ printf '#!%s\nBOX=%q\n' "$(command -v bash)" ""; declare -f mk_node; printf 'BOX="$BOX_DIR"; mk_node "$1"\n'; } > "$MK_NODE"; chmod +x "$MK_NODE"
export MK_NODE

# fresh_box [with-apt] — a new sandbox: package copy, empty BOX, empty logs.
fresh_box() {
  rm -rf "$TMP/box" "$TMP/pkg" "$TMP/state" "$TMP/aproot"
  BOX="$TMP/box"; mkdir -p "$BOX" "$TMP/state" "$TMP/aproot"
  # The box seat's store is there, as setup now makes it (DIVE-7156, pinned in
  # browser_setup_backfill_unit.sh B6): a runner with a `claude` account would
  # otherwise get it made on the first run only and fail the byte-identical arms.
  mkdir -p "$TMP/state/browser-profiles/claude"
  cp -r "$ROOT/browser" "$TMP/pkg"; rm -rf "$TMP/pkg/node_modules"
  [[ "${1:-apt}" == apt ]] && ln -s "$CORE/apt-get.real" "$BOX/apt-get"
  export BOX_DIR="$BOX" STACK_LOG="$TMP/stack.log"; : > "$STACK_LOG"
}
full_box() {  # everything a hosted VM has
  for x in Xvfb google-chrome-stable x11vnc websockify; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BOX/$x"; chmod +x "$BOX/$x"; done
  mk_node 22.11.0
  mkdir -p "$TMP/pkg/node_modules/playwright-core"
  printf '{\n  "name": "playwright-core",\n  "version": "%s"\n}\n' "$PIN" > "$TMP/pkg/node_modules/playwright-core/package.json"
}
setup_go() {  # setup_go [bin] — run setup in the sandbox; AS=root|person (default)|hire
  local bin="${1:-$TMP/pkg/bin/browser}" o="$TMP/.o" e="$TMP/.e" who=()
  case "${AS:-person}" in
    root)   who=(FAKE_UN=root) ;;                      # no SUDO_USER, no seat named
    person) ;;                                         # id -un names the seat, as SUDO_USER would
    hire)   who=(FIVEDIVE_BROWSER_SEAT="$SEAT") ;;      # what seed_browser_store_for_seat passes
  esac
  env -i HOME="$TMP" PATH="$BOX:$CORE" STATE_DIR="$TMP/state" "${who[@]}" \
    FIVEDIVE_BROWSER_AGENT_GROUP="$(id -gn)" FIVEDIVE_BROWSER_HOSTED_CONVERGER="$TMP/hosted-converger" \
    FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/state/browser-profiles" \
    FIVEDIVE_BROWSER_SYSTEMD_DIR="$TMP/systemd" FIVEDIVE_BROWSER_SYSTEMCTL=systemctl \
    FIVEDIVE_BROWSER_SUDOERS_DIR="$TMP/sudoers" FIVEDIVE_BROWSER_VISUDO="$CORE/visudo" \
    FIVEDIVE_BROWSER_STACK_ROOT="$TMP/aproot" ${STACK_ENV:+FIVEDIVE_BROWSER_STACK=$STACK_ENV} \
    STACK_LOG="$STACK_LOG" BOX_DIR="$BOX" MK_NODE="$MK_NODE" NPM_VERSION="${NPM_VERSION:-$PIN}" \
    NODE_VER="${NODE_VER:-22.11.0}" APT_FAIL="${APT_FAIL:-}" \
    "$bin" setup >"$o" 2>"$e"
  RC=$?; OUT=$(cat "$o"); ERR=$(cat "$e"); LOG=$(cat "$STACK_LOG")
}
mkdir -p "$TMP/systemd" "$TMP/sudoers"
pin_have() { sed -n 's/.*"version": "\(.*\)".*/\1/p' "$TMP/pkg/node_modules/playwright-core/package.json" 2>/dev/null; }

# --- T1 a fresh Ubuntu box: nothing there, apt present -------------------------
fresh_box; setup_go
t  'T1 fresh box: setup exits 0'                       0 "$RC"
tc 'T1 ...names what it is about to install'           'installing what the browser needs and this box lacks: Xvfb (xvfb), chrome (google-chrome-stable), x11vnc, websockify (novnc), Node.js >= 20 (none), playwright-core' "$OUT"
tc 'T1 ...apt installs exactly the three X packages'   'install xvfb x11vnc websockify' "$LOG"
tc 'T1 ...chrome is Google'"'"'s deb, not the chromium snap shim' 'install google-chrome-stable' "$LOG"
tn 'T1 ...and the fallback is never asked for'         'install chromium' "$LOG"
tc 'T1 ...Google'"'"'s repo is signed and amd64'       'deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main' "$(cat "$TMP/aproot/etc/apt/sources.list.d/google-chrome.list" 2>/dev/null)"
tc 'T1 ...Node comes from NodeSource 22'               'deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main' "$(cat "$TMP/aproot/etc/apt/sources.list.d/nodesource.list" 2>/dev/null)"
tc 'T1 ...apt installs nodejs'                         'install nodejs' "$LOG"
tc 'T1 ...npm: the hosted converger'"'"'s exact flags, into the package' "npm install --prefix $TMP/pkg --omit=dev --ignore-scripts --no-audit --no-fund --no-package-lock --loglevel=error" "$LOG"
t  'T1 ...playwright-core lands at the pin'            "$PIN" "$(pin_have)"
for w in 'installed xvfb' 'installed x11vnc' 'installed websockify' 'installed google-chrome-stable' 'installed Node.js v22.11.0 (NodeSource 22)' "installed playwright-core $PIN" 'browser stack ready'; do
  tc "T1 ...says: $w" "$w" "$OUT"
done
tc 'T1 ...and still makes the store'                   'profile store ready' "$OUT"
for w in 'Step 1/4 — virtual screen and VNC (xvfb, x11vnc, websockify)' 'Step 2/4 — Google Chrome' 'Step 3/4 — Node.js 22' "Step 4/4 — playwright-core $PIN" \
         'installing xvfb x11vnc websockify (apt)...' "installing google-chrome-stable (Google's apt repo)..." 'installing Node.js 22 (NodeSource)...' "installing playwright-core $PIN (npm"; do
  tc "T1 ...numbered, named: $w" "$w" "$OUT"
done
tc 'T1 ...a person from a seat ends on the ready line'  'browser ready: agents you hire get a browser' "$(tail -n1 <<<"$OUT")"
t  'T1 ...nothing on stderr'                           '' "$ERR"
t  'T1 ...apt-get update ran once per new source, not per package' 3 "$(grep -c '^apt-get .* update' "$STACK_LOG")"

# --- T2 a hosted box: everything present --------------------------------------
fresh_box; full_box; STACK_ENV=off setup_go; OFF_OUT="$OUT"
: > "$STACK_LOG"; setup_go
t  'T2 hosted box: setup exits 0'                      0 "$RC"
t  'T2 ...apt, curl and npm are never called'          '' "$LOG"
t  'T2 ...stdout is byte-identical to a setup with the stack step off' "$OFF_OUT" "$OUT"
t  'T2 ...nothing on stderr'                           '' "$ERR"
t  'T2 ...no apt source written'                       0 "$(find "$TMP/aproot" -type f | wc -l)"

# --- T3 Node 18 (Ubuntu 24.04's apt nodejs) ends at >= 20, pin installed ------
fresh_box; full_box; mk_node 18.19.1; rm -rf "$TMP/pkg/node_modules"
setup_go
t  'T3 node 18: setup exits 0'                         0 "$RC"
tc 'T3 ...names the old node'                          'Node.js >= 20 (found 18)' "$OUT"
tc 'T3 ...installs nodejs'                             'install nodejs' "$LOG"
tc 'T3 ...and says from what'                          'installed Node.js v22.11.0 (NodeSource 22, was 18)' "$OUT"
t  'T3 ...node on PATH is now 22'                      'v22.11.0' "$("$BOX/node" --version)"
t  'T3 ...playwright-core at the pin'                  "$PIN" "$(pin_have)"
tn 'T3 ...the present X packages are not reinstalled'  'xvfb' "$LOG"
tn 'T3 ...nor chrome'                                  'chrome' "$LOG"

# --- T3b Node 18 + Ubuntu's npm (libnode-dev): the dpkg overwrite is cleared once
fresh_box; full_box; mk_node 18.19.1; rm -rf "$TMP/pkg/node_modules"; : > "$BOX/.libnode-dev"
setup_go
t  'T3b node 18 + libnode-dev: setup exits 0'          0 "$RC"
tc 'T3b ...says it removes libnode-dev, and why'       "removing Ubuntu's libnode-dev" "$OUT"
tc 'T3b ...removes exactly that package'               'remove libnode-dev' "$LOG"
t  'T3b ...and installs nodejs twice (fail, then retry)' 2 "$(grep -c 'install nodejs' "$STACK_LOG")"
t  'T3b ...node on PATH is now 22'                     'v22.11.0' "$("$BOX/node" --version)"
t  'T3b ...playwright-core at the pin'                 "$PIN" "$(pin_have)"
fresh_box; full_box; mk_node 18.19.1; rm -rf "$TMP/pkg/node_modules"
setup_go
tn 'T3c node 18 without libnode-dev: nothing is removed' 'remove' "$LOG"

# --- T4 Node 22 already there: never touched -----------------------------------
fresh_box; full_box; mk_node 22.3.0; rm -rf "$TMP/pkg/node_modules"
SUM=$(sha256sum "$BOX/node")
setup_go
t  'T4 node 22: setup exits 0'                         0 "$RC"
tn 'T4 ...nodejs is never asked for'                   'nodejs' "$LOG"
tn 'T4 ...NodeSource is never fetched'                 'nodesource' "$LOG"
t  'T4 ...node is byte-identical'                      "$SUM" "$(sha256sum "$BOX/node")"
t  'T4 ...and still answers 22.3.0'                    'v22.3.0' "$("$BOX/node" --version)"
t  'T4 ...the pin is installed'                        "$PIN" "$(pin_have)"
t  'T4 ...apt is never called at all'                  0 "$(grep -c '^apt-get' "$STACK_LOG")"

# --- T5 no apt-get: the named list, nothing installed, the store still made ---
fresh_box noapt; setup_go
t  'T5 no apt: setup still exits 0 (agent create must not fail on it)' 0 "$RC"
tc 'T5 ...refuses to install, naming every missing piece' 'missing Xvfb (xvfb), chrome (google-chrome-stable), x11vnc, websockify (novnc), Node.js >= 20 (none), playwright-core' "$ERR"
tc 'T5 ...and why'                                     'it has no apt-get, so setup installs nothing' "$ERR"
t  'T5 ...nothing was fetched or run'                  '' "$LOG"
tc 'T5 ...the store is still made'                     'profile store ready' "$OUT"

# --- T6 an apt failure is named, never fatal ----------------------------------
fresh_box; APT_FAIL="x11vnc google-chrome-stable chromium" setup_go
t  'T6 apt fails for some: setup exits 0'              0 "$RC"
tc 'T6 ...names the X package it could not install'    'could not install x11vnc' "$ERR"
tc 'T6 ...tries chromium only after Google'"'"'s chrome failed' 'install chromium' "$LOG"
tc 'T6 ...and names the chrome failure'                'could not install a chrome' "$ERR"
tc 'T6 ...the closing line lists what is still missing' 'still missing after install: chrome (google-chrome-stable), x11vnc' "$ERR"
tc 'T6 ...what did install is still said'              'installed xvfb' "$OUT"
tc 'T6 ...the store is still made'                     'profile store ready' "$OUT"

# --- T7 npm exits 0 at the wrong version: graded on the box, not the exit -----
fresh_box; full_box; rm -rf "$TMP/pkg/node_modules"; NPM_VERSION=1.0.0 setup_go
t  'T7 wrong version: setup exits 0'                   0 "$RC"
tc 'T7 ...says npm left the wrong version'             "playwright-core reads '1.0.0' in $TMP/pkg where the pin is $PIN" "$ERR"
tn 'T7 ...and never claims it installed'               'installed playwright-core' "$OUT"

# --- T8 root, no seat: the README's line on a fresh box (DIVE-6112 NEGATIVE CONTROL)
# EUID 0, no SUDO_USER. It installs, names each install, and EXITS 0 — it used to
# install and then die "refusing to make root a browser seat", exit 64.
root_arms() {  # root_arms <label> — the arms a revert of DIVE-6112 item 1 turns red
  t  "$1 root: setup exits 0"                          0 "$RC"
  for w in 'Step 1/4 — virtual screen and VNC' 'Step 2/4 — Google Chrome' 'Step 3/4 — Node.js 22' 'Step 4/4 — playwright-core' \
           'installing xvfb x11vnc websockify' 'installed xvfb' "installing google-chrome-stable" 'installed google-chrome-stable' \
           'installing Node.js 22' 'installed Node.js v22.11.0' 'installing playwright-core' "installed playwright-core $PIN"; do
    tc "$1 ...stdout names: $w" "$w" "$OUT"
  done
  t  "$1 ...and ends on the ready line"                'browser ready: agents you hire get a browser' "$(tail -n1 <<<"$OUT")"
  t  "$1 ...nothing on stderr"                         '' "$ERR"
}
fresh_box; AS=root setup_go; root_arms T8
tn 'T8 ...no refusal'                                  'refusing to make root' "$ERR"
t  'T8 ...no store is made for root'                   no "$([[ -e "$TMP/state/browser-profiles/root" ]] && echo yes || echo no)"
t  'T8 ...nor a seat-shaped store line'                '' "$(grep 'profile store ready' <<<"$OUT")"

fresh_box; full_box; AS=root setup_go
t  'T8b root, box has everything: exits 0'             0 "$RC"
t  'T8b ...apt, curl and npm never called'             '' "$LOG"
t  'T8b ...says only that it is ready'                 'browser ready: agents you hire get a browser' "$OUT"

fresh_box; APT_FAIL="google-chrome-stable chromium" AS=root setup_go
t  'T8c root, chrome fails: still exits 0 (never fatal)' 0 "$RC"
tc 'T8c ...the failure is a named line'                'could not install a chrome' "$ERR"
tc 'T8c ...and the box is NOT called ready'            'browser NOT ready' "$ERR"
tn 'T8c ...no ready line on stdout'                    'browser ready:' "$OUT"
tc 'T8c ...what did install is still said'             'installed Node.js v22.11.0' "$OUT"

# --- T9 MUTANT: setup without the converge call is T1-red ---------------------
MUT="$TMP/mutant"; rm -rf "$MUT"; cp -r "$ROOT/browser" "$MUT"
perl -pi -e 's/^    _stack_converge \|\| stack_ok=0$/    : # MUTANT (DIVE-6089)/' "$MUT/bin/browser"
t  'T9 (anchor) the mutation landed'                   1 "$(grep -c 'MUTANT (DIVE-6089)' "$MUT/bin/browser")"
fresh_box; setup_go "$MUT/bin/browser"
t  'T9 MUTANT: nothing is installed — T1 would be red' '' "$LOG"
tn 'T9 MUTANT: ...and no install line'                 'installing what the browser needs' "$OUT"

# --- T10 the stack step can be turned off (the other suite's arms use it) ------
fresh_box; STACK_ENV=off setup_go
t  'T10 FIVEDIVE_BROWSER_STACK=off: nothing called'    '' "$LOG"
t  'T10 ...setup exits 0'                              0 "$RC"
fresh_box; STACK_ENV=off AS=root setup_go
t  'T10b off, as root: nothing called, exits 0'        "0 " "$RC $LOG"

# --- T11 a HIRE on a self-hosted box without the stack: installs nothing ------
# agent create/import passes FIVEDIVE_BROWSER_SEAT and shows only a FAILED
# setup's last line. So: no apt, no npm, the store still made, exit 69, and the
# last line is the command to run.
fresh_box; AS=hire setup_go
t  'T11 hire, no stack: apt, curl and npm are never called' '' "$LOG"
t  'T11 ...exits 69 so the hire shows the line'        69 "$RC"
tc 'T11 ...the store is still made'                    'profile store ready' "$OUT"
tn 'T11 ...nothing claims to install'                  'installing' "$OUT"
tc 'T11 ...the last line names what is missing'        'this box has no browser stack yet (missing Xvfb (xvfb), chrome (google-chrome-stable)' "$(tail -n1 <<<"$ERR")"
tc 'T11 ...and the one command'                        'A hire installs nothing; run once, as root: sudo 5dive browser setup' "$(tail -n1 <<<"$ERR")"

# --- T12 a hire on a HOSTED box missing the stack: as before DIVE-6089 --------
fresh_box; : > "$TMP/hosted-converger"; AS=hire setup_go; rm -f "$TMP/hosted-converger"
t  'T12 hire, hosted box: exits 0'                     0 "$RC"
t  'T12 ...nothing called'                             '' "$LOG"
t  'T12 ...nothing on stderr (its converger owns the stack)' '' "$ERR"

# --- T13 a hire on a box with everything: exit 0, byte-identical to off -------
fresh_box; full_box; STACK_ENV=off AS=hire setup_go; OFF_OUT="$OUT"
: > "$STACK_LOG"; AS=hire setup_go
t  'T13 hire, full box: exits 0'                       0 "$RC"
t  'T13 ...nothing called'                             '' "$LOG"
t  'T13 ...stdout byte-identical to the step off'      "$OFF_OUT" "$OUT"
t  'T13 ...nothing on stderr'                          '' "$ERR"
fresh_box; STACK_ENV=off AS=hire setup_go
t  'T13b hire, no stack, FIVEDIVE_BROWSER_STACK=off: exits 0, silent' "0|" "$RC|$ERR"

# --- T14 MUTANT: the install lines hidden — the T8 arms must go red -----------
MUT2="$TMP/mutant2"; rm -rf "$MUT2"; cp -r "$ROOT/browser" "$MUT2"
perl -pi -e 's/^(_stack_say\(\) \{ printf .*?);( \})$/$1 >\/dev\/null;$2 # MUTANT-HIDE/; s/^(_stack_step\(\) \{ printf .*?);( \})$/$1 >\/dev\/null;$2 # MUTANT-HIDE/' "$MUT2/bin/browser"
t  'T14 (anchor) both mutations landed'                2 "$(grep -c 'MUTANT-HIDE' "$MUT2/bin/browser")"
fresh_box; AS=root setup_go "$MUT2/bin/browser"
P0=$PASS F0=$FAIL; root_arms T14m >/dev/null; MUT_RED=$((FAIL-F0)); PASS=$P0; FAIL=$F0
t  'T14 MUTANT: the T8 root arms go red (>= 12 of them)' yes "$( (( MUT_RED >= 12 )) && echo yes || echo no)"
t  'T14 MUTANT: ...yet the stack still went in (the arms grade the LINES)' "yes $PIN" "$([[ -x "$BOX/google-chrome-stable" ]] && echo yes) $(sed -n 's/.*"version": "\(.*\)".*/\1/p' "$MUT2/node_modules/playwright-core/package.json" 2>/dev/null)"

# --- T15 MUTANT: item 1 reverted (root refused as a seat) — T8 goes red -------
MUT3="$TMP/mutant3"; rm -rf "$MUT3"; cp -r "$ROOT/browser" "$MUT3"
perl -pi -e 's/^    if \[\[ "\$seat" == root \]\]; then$/    if false; then # MUTANT-REVERT/' "$MUT3/bin/browser"
t  'T15 (anchor) the mutation landed'                  1 "$(grep -c 'MUTANT-REVERT' "$MUT3/bin/browser")"
fresh_box; AS=root setup_go "$MUT3/bin/browser"
t  'T15 MUTANT: root exits non-zero again (T8 red)'   64 "$RC"
tc 'T15 MUTANT: ...with the old refusal'               'refusing to make root a browser seat' "$ERR"

# --- T16 plugin.json: voice's `setup` shape, pointing at this command ---------
# `plugin add` prints this block and runs nothing (5dive-cli cmd_plugin_add);
# voice/.claude-plugin/plugin.json is {hint, command} and so is this one.
MJ="$ROOT/browser/.claude-plugin/plugin.json"
t  'T16 setup block is exactly {hint, command}'         '["command","hint"]' "$(jq -c '.fivedive.setup | keys' "$MJ")"
t  'T16 ...command is the box setup line'                'sudo 5dive browser setup' "$(jq -r '.fivedive.setup.command' "$MJ")"
tc 'T16 ...hint names what it installs'                  'Google Chrome, a virtual screen, VNC and Node.js 22' "$(jq -r '.fivedive.setup.hint' "$MJ")"
tn 'T16 ...and no hand npm line'                         'npm install' "$(jq -r '.fivedive.setup.hint' "$MJ")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
