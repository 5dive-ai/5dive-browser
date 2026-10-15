#!/usr/bin/env bash
# DIVE-6241 — lib/page-check.cjs: what the page SHOWS decides, not what its source mentions.
#
# Round 2 of the Claude in Chrome head-to-head (marketing/reddit/2026-10-14-cic-vs-5dive-browser.md,
# findings 4 and 6) stopped two sign-ups on guards that grepped the whole document:
#   - tally.so read as "presenting a security challenge": its front page carries
#     "login.two-factor-step.title" in script data, and the default marker matches "two-factor".
#   - pitch.com's Sign up lands on auth.pitch.com/login, refused as a sign-in page before
#     the agent could see its "Continue with Google".
# The fixtures in tests/fixtures/dive-6241/ are REAL captures (2026-10-14, the shared CI
# Chrome), trimmed: script bodies cut to the segments that carry a marker, styles and svg
# emptied, a Turnstile token elided. Each still matches the default marker, which is the
# point. The act-level arms, each red on the 1.39.0 tree, are T32m in browser_plugin_unit.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
LIB="$PWD/browser/lib/page-check.cjs"
FX="$PWD/tests/fixtures/dive-6241"
DEFAULT_MARKER='(g-recaptcha|hcaptcha|cf-challenge|/checkpoint/challenge|two-factor|verify-your-identity)'
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
t() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
# c <html> [url] -> true|false ; s <html> [url] -> "<verdict> <kind>"
c() { printf '%s' "$1" > "$TMP/p.html"; node "$LIB" challenge "$TMP/p.html" "${2:-}" | jq -r '.challenge'; }
s() { printf '%s' "$1" > "$TMP/p.html"; node "$LIB" signin "$TMP/p.html" "${2:-}" | jq -r '"\(.verdict) \(.kind)"'; }
cf() { node "$LIB" challenge "$1" "${2:-}" | jq -r '.challenge'; }
sf() { node "$LIB" signin "$1" "${2:-}" | jq -r '"\(.verdict) \(.kind)"'; }

# ---- fix 2: a challenge needs a page check -----------------------------------------
for f in tally-front tally-signup pitch-login; do
  t "P0 (fixture) $f still matches the default challenge marker" yes \
    "$(grep -qiE "$DEFAULT_MARKER" "$FX/$f.html" && echo yes || echo no)"
done
t 'P1 tally.so front page (round 2 AG2): not a challenge' false "$(cf "$FX/tally-front.html" https://tally.so/)"
t 'P1b tally.so/signup, its Turnstile already passed and 0 px high: not a challenge' false "$(cf "$FX/tally-signup.html" https://tally.so/signup)"
t 'P1c a feature list naming two-factor and hCaptcha in script data: not a challenge' false \
  "$(c '<html><head><title>Forms</title><script>var t={"two-factor":"Two-factor authentication","hcaptcha":"hCaptcha"}</script></head><body><h1>Forms</h1></body></html>')"
t 'P1d an invisible reCAPTCHA on a form: not a challenge' false \
  "$(c '<html><body><form><div class="g-recaptcha" data-size="invisible"></div><iframe src="https://www.google.com/recaptcha/api2/anchor?k=x&size=invisible"></iframe></form></body></html>')"
# what must still stop (the negative arms): a robot check, a code
t 'N2a a visible reCAPTCHA widget is a challenge' true "$(c '<html><body><form action="/login"></form><div class="g-recaptcha"></div></body></html>')"
t 'N2b a reCAPTCHA checkbox frame is a challenge' true \
  "$(c '<html><body><iframe title="reCAPTCHA" src="https://www.google.com/recaptcha/api2/anchor?k=x&size=normal"></iframe></body></html>')"
t 'N2c an hCaptcha widget is a challenge' true "$(c '<html><body><div class="h-captcha" data-sitekey="x"></div></body></html>')"
t 'N2d Cloudflare'"'"'s "Just a moment..." is a challenge' true \
  "$(c '<html><head><title>Just a moment...</title></head><body><div id="challenge-running">Checking your browser</div></body></html>')"
t 'N2e a two-factor page with a code box is a challenge' true \
  "$(c '<html><body><h1>Two-factor authentication</h1><form action="/sessions/two-factor"><input autocomplete="one-time-code" name="app_otp"></form></body></html>')"
t 'N2f a code box alone (no marker words) is a challenge' true \
  "$(c '<html><body><label>Code</label><input name="otp" inputmode="numeric"></body></html>')"
t 'N2g a challenge URL is a challenge' true "$(c '<html><body>x</body></html>' 'https://www.facebook.com/checkpoint/challenge/x')"
t 'N2h "verify you are human" on the screen is a challenge' true "$(c '<html><body><p>Verify you are human by completing the action below.</p></body></html>')"

# ---- fix 3: a sign-in page with "Continue with Google" -------------------------------
PL='https://auth.pitch.com/login?state=x&prompt=select_account'
t 'P3 auth.pitch.com/login (round 2 AG5): handed back for the Google button' 'offer google-button' "$(sf "$FX/pitch-login.html" "$PL")"
t 'P3b tally.so/signup offers it too' 'offer google-button' "$(sf "$FX/tally-signup.html" https://tally.so/signup)"
LOGIN='<html><body><form action="/login"><input type="email" id="e"></form><button>Continue with Google</button></body></html>'
t 'P3c a login form with an email box and "Continue with Google"' 'offer google-button' "$(s "$LOGIN" https://auth.x.test/login)"
t 'P3d "Sign up with Google" counts' 'offer google-button' "$(s '<html><body><a href="/g">Sign up with Google</a></body></html>')"
# what must still stop
t 'N3a ...plus a visible password box: stop' 'stop password' \
  "$(s "${LOGIN/<\/form>/<input type=\"password\" name=\"pw\"></form>}" https://auth.x.test/login)"
t 'N3b ...plus a code box: stop' 'stop challenge' "$(s "${LOGIN/<\/form>/<input autocomplete=\"one-time-code\" name=\"c\"></form>}")"
t 'N3c ...plus a robot check: stop' 'stop challenge' "$(s "${LOGIN/<\/body>/<div class=\"g-recaptcha\"></div></body>}")"
t 'N3d ...on a challenge title: stop' 'stop challenge' "$(s "${LOGIN/<body>/<head><title>Attention Required!</title></head><body>}")"
t 'N3e a sign-in page with no Google button: the refusal stands' 'none no-google' \
  "$(s '<html><body><form action="/login"><input type="email"><input type="password"></form></body></html>')"
t 'N3f a hidden password box (password managers) does not stop it' 'offer google-button' \
  "$(s "${LOGIN/<\/form>/<input type=\"password\" aria-hidden=\"true\" tabindex=\"-1\"></form>}")"

# --- DIVE-6247: a provider button that says just "Google" ------------------------
# coda.io's sign-up lands on id.superhuman.com: "Continue to Superhuman Docs" over
# buttons named Google, Microsoft, Apple (round 3 G4, g-artifacts/coda.io.8nNtxfyZ).
SH="$PWD/tests/fixtures/dive-6247/superhuman-signin.html"
SHU='https://id.superhuman.com/signin?oauth_client_type=MEDIATED_WEB&client_id=superhumanDocs'
t 'P4 id.superhuman.com (round 3 G4): handed back for its "Google" button (1.40.0: none)' 'offer google-button' "$(sf "$SH" "$SHU")"
t 'P4b a link whose text is just Google, its logo beside it, counts' 'offer google-button' \
  "$(s '<html><body><h1>Log in</h1><a href="/g"><svg><path d="M0"></path></svg> Google </a><a href="/m">Microsoft</a></body></html>')"
t 'N4a NEGATIVE: "Google" inside a longer button (a privacy notice link) is not a sign-in button' 'none no-google' \
  "$(s '<html><body><h1>Log in</h1><a href="/p">Google Privacy Policy</a><input type="email"></body></html>')"
t 'N4b NEGATIVE: the Superhuman page with a password box stops' 'stop password' \
  "$(s "$(sed 's|</form>|<input type="password" name="pw"></form>|' "$SH")" "$SHU")"
t 'N4c NEGATIVE: ...with a robot check, stops' 'stop challenge' \
  "$(s "$(sed 's|</body>|<div class="g-recaptcha"></div></body>|' "$SH")" "$SHU")"
t 'N4d NEGATIVE: Whimsical'"'"'s sign-up page (a password box beside "Sign up with Google") still stops' 'stop password' \
  "$(sf "$PWD/tests/fixtures/dive-6247/whimsical-signup.html" https://whimsical.com/signup)"

# --- DIVE-6317: the site's own terms step of a sign-up ----------------------------
# Round 5 G5/G5r: after Google's consent, pitch.com lands a new account on
# login.pitch.com/consent-and-privacy, one "I agree to the Terms" box and Continue.
# Its "login." host made the generic URL guard refuse it as a sign-in, twice.
# The fixture is RECONSTRUCTED from the node list round 5 walked (see its header).
PT="$PWD/tests/fixtures/dive-6317/pitch-terms.html"
PTU='https://login.pitch.com/consent-and-privacy?t=auth.pitch.com&email=atorn864%40gmail.com&state=x'
t 'P5 (fixture) the Pitch terms URL is one the generic sign-in URL guard catches' yes \
  "$(grep -qiE "$(sed -n "s/^GENERIC_SIGNIN_URL='\(.*\)'$/\1/p" browser/bin/browser)" <<<"$PTU" && echo yes || echo no)"
t 'P5a login.pitch.com/consent-and-privacy (round 5 G5): handed back as the terms step (1.41.0: none)' 'offer terms' "$(sf "$PT" "$PTU")"
t 'P5b "I accept the Terms of Service" with a role=checkbox counts' 'offer terms' \
  "$(s '<html><body><div role="checkbox" aria-checked="false"></div><span>I accept the Terms of Service</span><button>Next</button></body></html>')"
t 'N5a NEGATIVE: terms words with no box to tick (a footer) are not a terms step' 'none no-google' \
  "$(s '<html><body><form action="/login"><input type="email"></form><p>By continuing, I agree to the Terms of Use.</p></body></html>')"
t 'N5b NEGATIVE: a box for a newsletter only is not a terms step' 'none no-google' \
  "$(s '<html><body><label><input type="checkbox"> Send me product news</label><button>Continue</button></body></html>')"
t 'N5c NEGATIVE: the terms page with a password box stops' 'stop password' \
  "$(s "$(sed 's|<button type="submit">|<input type="password" name="pw"><button type="submit">|' "$PT")" "$PTU")"
t 'N5d NEGATIVE: ...with a robot check, stops' 'stop challenge' \
  "$(s "$(sed 's|</form>|<div class="g-recaptcha"></div></form>|' "$PT")" "$PTU")"
t 'N5e NEGATIVE: ...with a code box, stops' 'stop challenge' \
  "$(s "$(sed 's|</form>|<input autocomplete="one-time-code" name="otp"></form>|' "$PT")" "$PTU")"

printf 'page-check: %d pass, %d fail\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
