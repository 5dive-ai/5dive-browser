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
# DIVE-8206 — a person's run that leaves the stack short shows what apt said,
# ends "browser NOT ready: missing …" and exits 69 (root and seat alike). It used
# to exit 0, and the app's Finish setup looped on a box with no Chrome.
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
[[ "$1" == --audit ]] && { cat "$BOX_DIR/.dpkg-audit" 2>/dev/null; exit 0; }
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
# APT_UPDATE_FAIL: the sources cannot be read, so update AND every install refuse
# with APT_STDERR, as a Signed-By conflict makes real apt do.
[[ -n "${APT_UPDATE_FAIL:-}" && ( "$sub" == update || "$sub" == install ) ]] && { printf '%b\n' "$APT_STDERR" >&2; exit 100; }
[[ "$sub" == install ]] || exit 0
rc=0
for p in "${pk[@]}"; do
  [[ " ${APT_FAIL:-} " == *" $p "* ]] && { rc=100; [[ -n "${APT_STDERR:-}" ]] && printf '%b\n' "$APT_STDERR" >&2; continue; }
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
    NODE_VER="${NODE_VER:-22.11.0}" APT_FAIL="${APT_FAIL:-}" APT_STDERR="${APT_STDERR:-}" APT_UPDATE_FAIL="${APT_UPDATE_FAIL:-}" \
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
t  'T5 no apt, a person'"'"'s run: exits 69, the browser is not ready (DIVE-8206)' 69 "$RC"
tc 'T5 ...refuses to install, naming every missing piece' 'missing Xvfb (xvfb), chrome (google-chrome-stable), x11vnc, websockify (novnc), Node.js >= 20 (none), playwright-core' "$ERR"
tc 'T5 ...and why'                                     'it has no apt-get, so setup installs nothing' "$ERR"
t  'T5 ...nothing was fetched or run'                  '' "$LOG"
tc 'T5 ...the store is still made'                     'profile store ready' "$OUT"
tc 'T5 ...and the last line says NOT ready, naming what' 'browser NOT ready: missing Xvfb (xvfb), chrome (google-chrome-stable)' "$(tail -n1 <<<"$ERR")"

# --- T6 an apt failure is named, never fatal ----------------------------------
fresh_box; APT_FAIL="x11vnc google-chrome-stable chromium" setup_go
t  'T6 apt fails for some: a person'"'"'s setup exits 69 (DIVE-8206)' 69 "$RC"
tc 'T6 ...names the X package it could not install'    'could not install x11vnc' "$ERR"
tc 'T6 ...tries chromium only after Google'"'"'s chrome failed' 'install chromium' "$LOG"
tc 'T6 ...and names the chrome failure'                'could not install a chrome' "$ERR"
tc 'T6 ...the closing line lists what is still missing' 'still missing after install: chrome (google-chrome-stable), x11vnc' "$ERR"
tc 'T6 ...what did install is still said'              'installed xvfb' "$OUT"
tc 'T6 ...the store is still made'                     'profile store ready' "$OUT"
t  'T6 ...and ends on NOT ready, naming what is missing' 'browser NOT ready: missing chrome (google-chrome-stable), x11vnc. The lines above say why. Fix that, then re-run: sudo 5dive browser setup' "$(tail -n1 <<<"$ERR")"
tn 'T6 ...never the ready line'                         'browser ready:' "$OUT"

# --- T7 npm exits 0 at the wrong version: graded on the box, not the exit -----
fresh_box; full_box; rm -rf "$TMP/pkg/node_modules"; NPM_VERSION=1.0.0 setup_go
t  'T7 wrong version: a person'"'"'s setup exits 69'     69 "$RC"
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
t  'T8c root, chrome fails: exits 69 (DIVE-8206; it used to say 0)' 69 "$RC"
tc 'T8c ...the failure is a named line'                'could not install a chrome' "$ERR"
tc 'T8c ...and the box is NOT called ready'            'browser NOT ready: missing chrome (google-chrome-stable)' "$(tail -n1 <<<"$ERR")"
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

# --- T17 DIVE-8206: apt's own words under the failure, NOT ready, exit 69 -----
# wry-rune (report 886): both Chrome installs failed and setup printed only
# "could not install a chrome", then exited 0. apt said why; setup threw it away.
NOSPACE='Reading package lists...\nUnpacking google-chrome-stable (131.0.6778.85-1) ...\ndpkg: error processing archive /var/cache/apt/archives/google-chrome-stable_131_amd64.deb (--unpack):\n cannot copy extracted data for ./opt/google/chrome/chrome to /opt/google/chrome/chrome.dpkg-new: failed to write (No space left on device)\nErrors were encountered while processing:\n /var/cache/apt/archives/google-chrome-stable_131_amd64.deb\nE: Sub-process /usr/bin/dpkg returned an error code (1)'
nospace_box() { fresh_box; full_box; rm -f "$BOX/google-chrome-stable"; }
nospace_box; APT_FAIL="google-chrome-stable chromium" APT_STDERR="$NOSPACE" setup_go
t  'T17a no space, a person: exits 69'                   69 "$RC"
tc 'T17a ...names the chrome failure'                   'could not install a chrome' "$ERR"
tc 'T17a ...and under it, what apt said'                 'apt-get install google-chrome-stable said:' "$ERR"
tc 'T17a ...apt'"'"'s own reason, word for word'         'failed to write (No space left on device)' "$ERR"
tc 'T17a ...its last line too'                           '    E: Sub-process /usr/bin/dpkg returned an error code (1)' "$ERR"
tn 'T17a ...only the tail (5 lines), not the whole run'  'Reading package lists' "$ERR"
t  'T17a ...chromium said the same, so it is shown once' 1 "$(grep -c 'No space left on device' <<<"$ERR")"
t  'T17a ...the last line: NOT ready, naming chrome'     'browser NOT ready: missing chrome (google-chrome-stable). The lines above say why. Fix that, then re-run: sudo 5dive browser setup' "$(tail -n1 <<<"$ERR")"
tc 'T17a ...the store is still made'                     'profile store ready' "$OUT"
tn 'T17a ...never the ready line'                        'browser ready:' "$OUT"

nospace_box; APT_FAIL="google-chrome-stable chromium" APT_STDERR="$NOSPACE" AS=root setup_go
t  'T17b the same box, root: exits 69'                   69 "$RC"
tc 'T17b ...apt'"'"'s reason is shown'                   'No space left on device' "$ERR"
tc 'T17b ...ends NOT ready'                              'browser NOT ready: missing chrome (google-chrome-stable)' "$(tail -n1 <<<"$ERR")"

# A hire never installs, so it never reaches apt: on a hosted box it stays exit 0.
nospace_box; : > "$TMP/hosted-converger"
APT_FAIL="google-chrome-stable chromium" APT_STDERR="$NOSPACE" AS=hire setup_go; rm -f "$TMP/hosted-converger"
t  'T17c the same box, a hire (hosted): exits 0, as before' 0 "$RC"
t  'T17c ...apt is never called'                         '' "$LOG"
tn 'T17c ...and no NOT ready line'                       'NOT ready' "$ERR"

SIGNEDBY='E: Conflicting values set for option Signed-By regarding source https://dl.google.com/linux/chrome/deb/ stable: /usr/share/keyrings/google-chrome.gpg != /usr/share/keyrings/google-chrome-keyring.gpg\nE: The list of sources could not be read.'
nospace_box; APT_UPDATE_FAIL=1 APT_STDERR="$SIGNEDBY" setup_go
t  'T17d Signed-By conflict, a person: exits 69'         69 "$RC"
tc 'T17d ...names the cause in plain words'              'two apt sources for the same repo name different signing keys (Signed-By)' "$ERR"
t  'T17d ...once, however many apt runs hit it'          1 "$(grep -c 'different signing keys' <<<"$ERR")"
tc 'T17d ...with apt'"'"'s line, naming both keys'       'google-chrome.gpg != /usr/share/keyrings/google-chrome-keyring.gpg' "$ERR"
tc 'T17d ...ends NOT ready'                              'browser NOT ready: missing chrome (google-chrome-stable)' "$(tail -n1 <<<"$ERR")"

# --- T18 the two box faults named BEFORE the installs (DIVE-8206) -------------
mk_df() {  # mk_df <free-kb-on-/> <free-kb-on-/var>
  cat > "$BOX/df" <<DF
#!/usr/bin/env bash
echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'
echo "/dev/sda1 40000000 39000000 $1 98% /"
echo "/dev/sdb1 40000000 39000000 $2 98% /var"
DF
  chmod +x "$BOX/df"
}
nospace_box; mk_df 307200 50000000; setup_go
tc 'T18a / under 1 GB: named before the installs'        'low disk: / (300 MB free). Chrome needs about 1 GB free' "$ERR"
tn 'T18a .../var with room is not named'                 '/var (' "$ERR"
t  'T18a ...and it comes before Step 2'                  yes "$( [[ "$(grep -n 'low disk' "$TMP/.e" | cut -d: -f1)" ]] && grep -q 'Step 2/4' "$TMP/.o" && echo yes)"
nospace_box; mk_df 50000000 50000000; setup_go
tn 'T18b plenty of room: no disk line'                   'low disk' "$ERR"
t  'T18b ...and a box that installs fine stays exit 0'   0 "$RC"
t  'T18b ...with nothing on stderr'                      '' "$ERR"
nospace_box; printf 'The following packages are only half configured:\n google-chrome-stable\n' > "$BOX/.dpkg-audit"; setup_go
tc 'T18c dpkg left half-done: named, with the fix'       'dpkg has an unfinished install, so apt will refuse new ones. Finish it first: sudo dpkg --configure -a' "$ERR"
tc 'T18c ...quoting dpkg --audit'                        'only half configured' "$ERR"
fresh_box; full_box; printf 'half configured\n' > "$BOX/.dpkg-audit"; mk_df 1 1; setup_go
t  'T18d a box with the whole stack never runs the checks' '' "$ERR"

# --- T19 Ubuntu without snapd: the chromium fallback says why it will fail ----
nospace_box; mkdir -p "$TMP/aproot/etc"; printf 'NAME="Ubuntu"\nID=ubuntu\n' > "$TMP/aproot/etc/os-release"
APT_FAIL="google-chrome-stable chromium" setup_go
tc 'T19 Ubuntu, no snap: the fallback line says so'      'on Ubuntu it is a snap and this box has no snapd' "$OUT"
nospace_box; APT_FAIL="google-chrome-stable chromium" setup_go
tn 'T19b not Ubuntu: no snap sentence'                   'snapd' "$OUT"

# --- T20 MUTANTS: the stderr capture and the seat-path exit, each reverted ----
MUT4="$TMP/mutant4"; rm -rf "$MUT4"; cp -r "$ROOT/browser" "$MUT4"
perl -pi -e 's/>\/dev\/null 2>"\$\{f:-\/dev\/null\}"$/>\/dev\/null 2>\/dev\/null # MUTANT-DROP/' "$MUT4/bin/browser"
t  'T20 (anchor) the capture revert landed'               1 "$(grep -c 'MUTANT-DROP' "$MUT4/bin/browser")"
nospace_box; APT_FAIL="google-chrome-stable chromium" APT_STDERR="$NOSPACE" setup_go "$MUT4/bin/browser"
tn 'T20 MUTANT capture off: apt'"'"'s reason is gone (T17a red)' 'No space left on device' "$ERR"
tn 'T20 MUTANT capture off: ...and no "apt-get said"'     'said:' "$ERR"
MUT5="$TMP/mutant5"; rm -rf "$MUT5"; cp -r "$ROOT/browser" "$MUT5"
perl -pi -e 's/^  if ! _setup_is_hire && \(\( ! stack_ok \)\); then /  if false; then : MUTANT-EXIT0; /' "$MUT5/bin/browser"
t  'T20 (anchor) the exit revert landed'                  1 "$(grep -c 'MUTANT-EXIT0' "$MUT5/bin/browser")"
nospace_box; APT_FAIL="google-chrome-stable chromium" APT_STDERR="$NOSPACE" setup_go "$MUT5/bin/browser"
t  'T20 MUTANT exit reverted: the seat path is back to 0 (T17a red)' 0 "$RC"

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
