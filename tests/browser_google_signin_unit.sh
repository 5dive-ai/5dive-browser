#!/usr/bin/env bash
# DIVE-6228 — lib/google-signin.cjs: one answer per Google sign-in page.
#
# Round 1 of the Claude in Chrome head-to-head (DIVE-6214) stopped 5dive-browser
# one click short on every "Sign up with Google": the generic sign-in guard read
# Google's account chooser as a sign-in form, and only sometimes (it runs only
# when the site's own front page left the login unconfirmed). These arms grade
# the classifier the guard now asks first, page by page. The act-level arms,
# each red on the pre-fix tree, are T32g in browser_plugin_unit.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
LIB="$PWD/browser/lib/google-signin.cjs"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
t() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
# g <url> <html> -> "<verdict> <kind>", or "none" when it is not Google's page
g() { printf '%s' "$2" > "$TMP/p.html"; local v; v=$(node "$LIB" "$TMP/p.html" "$1")
      [[ -n "$v" ]] && jq -r '"\(.verdict) \(.kind)"' <<<"$v" || echo none; }

AC='https://accounts.google.com'
CHOOSER='<html><head><title>Sign in - Google Accounts</title><script>load("https://www.google.com/recaptcha/enterprise.js?render=x")</script></head><body><h1>Choose an account</h1><div>to continue to Tactiq</div><ul><li><div data-identifier="alex.test@gmail.com" data-authuser="0">Alex Test alex.test@gmail.com</div></li><li><div>Use another account</div></li></ul><input type="password" name="hiddenPassword" aria-hidden="true" tabindex="-1"></body></html>'
t 'G1 the chooser with a saved, signed-in account is allowed' 'allow chooser' "$(g "$AC/v3/signin/accountchooser?client_id=1&continue=x" "$CHOOSER")"
t 'G1b ...and the same page gets the same answer every time' 'allow chooser allow chooser' \
  "$(g "$AC/v3/signin/accountchooser?client_id=1" "$CHOOSER") $(g "$AC/v3/signin/accountchooser?client_id=1" "$CHOOSER")"
t 'G1c the OAuth chooser URL is the chooser too' 'allow chooser' "$(g "$AC/o/oauth2/auth/oauthchooseaccount?client_id=1" "$CHOOSER")"
OUT='<html><body><h1>Choose an account</h1><div data-identifier="alex.test@gmail.com">Alex alex.test@gmail.com <div>Signed out</div></div><div>Use another account</div></body></html>'
t 'G2 a chooser whose only account is signed out stops (it leads to a password)' 'stop add-account' "$(g "$AC/v3/signin/accountchooser?x=1" "$OUT")"
t 'G2b a chooser with no account on it stops' 'stop add-account' \
  "$(g "$AC/v3/signin/accountchooser?x=1" '<html><body><h1>Choose an account</h1><div>Use another account</div></body></html>')"
PW='<html><body><h1>Welcome</h1><div>alex.test@gmail.com</div><input type="password" name="Passwd" autocomplete="current-password"><span>Show password</span></body></html>'
t 'G3 the password page stops' 'stop password' "$(g "$AC/v3/signin/challenge/pwd?TL=1" "$PW")"
t 'G3b a visible password box stops on any Google URL' 'stop password' "$(g "$AC/signin/oauth/id?x=1" "$PW")"
t 'G4 a 2-step prompt stops' 'stop code' "$(g "$AC/v3/signin/challenge/ipp?TL=1" '<html><body><h1>2-Step Verification</h1><div>Enter the code</div></body></html>')"
t 'G4b a verification-code page with no challenge URL stops' 'stop code' "$(g "$AC/signin/v2/sl/x" '<html><body>Get a verification code sent to your phone</body></html>')"
ROBOT='<html><body><iframe src="https://www.google.com/recaptcha/api2/anchor?k=x&size=normal"></iframe><div>Confirm you are not a robot</div></body></html>'
t 'G5 a robot check stops' 'stop robot' "$(g "$AC/v3/signin/challenge/recaptcha?TL=1" "$ROBOT")"
t 'G5b google.com/sorry is a robot check' 'stop robot' "$(g 'https://www.google.com/sorry/index?continue=x' '<html><body>Our systems have detected unusual traffic</body></html>')"
t 'G5c an invisible reCAPTCHA loader on a chooser is not a robot check' 'allow chooser' \
  "$(g "$AC/v3/signin/accountchooser?x=1" "${CHOOSER/<\/body>/<iframe src=\"https://www.google.com/recaptcha/enterprise/anchor?k=x&size=invisible\"></iframe></body>}")"
IDENT='<html><body><h1>Sign in</h1><input type="email" id="identifierId" name="identifier"><input type="password" name="hiddenPassword" aria-hidden="true" tabindex="-1"></body></html>'
t 'G6 the email box (adding an account) stops' 'stop add-account' "$(g "$AC/v3/signin/identifier?flowName=x" "$IDENT")"
t 'G6b ...and on an OAuth URL, by its email box' 'stop add-account' "$(g "$AC/signin/oauth/x?y=1" "$IDENT")"
t 'G6c a hidden password box alone is not a password prompt' 'stop add-account' "$(g "$AC/v3/signin/identifier?x=1" "$IDENT")"
WIDE='<html><body><h1>Jamie wants to access your Google Account</h1><div>alex.test@gmail.com</div><ul><li>See and download your contacts</li><li>View events on all your calendars</li><li>See your primary Google Account email address</li></ul><button>Allow</button><button>Cancel</button></body></html>'
t 'G7 a consent screen asking for calendar and contacts asks the owner' 'ask wide-consent' "$(g "$AC/signin/oauth/v2/consentsummary?authuser=0&part=x" "$WIDE")"
BASIC='<html><body><h1>Krisp wants to access your Google Account</h1><ul><li>Associate you with your personal info on Google</li><li>See your personal info, including any personal info you have made publicly available</li><li>See your primary Google Account email address</li></ul><div>Make sure you trust Krisp. Learn about the risks. You can see or remove access in your Google Account.</div><button>Continue</button></body></html>'
t 'G8 a consent screen for basic profile and email only is allowed' 'allow basic-consent' "$(g "$AC/signin/oauth/v2/consentsummary?authuser=0" "$BASIC")"
t 'G8b ...unless its URL names a wider scope' 'ask wide-consent' \
  "$(g "$AC/signin/oauth/consent?scope=openid%20email%20https://www.googleapis.com/auth/calendar" "$BASIC")"
t 'G8c ...or it has a box to tick per extra permission' 'ask wide-consent' \
  "$(g "$AC/signin/oauth/v2/consentsummary?x=1" "${BASIC/<button>/<input type=\"checkbox\" name=\"scope\"><button>}")"
CONT='<html><body><h1>Sign in to Jamie with Google</h1><div>alex.test@gmail.com</div><div>By continuing, Google will share your name, email address, language preference, and profile picture with Jamie.</div><button>Continue</button></body></html>'
t 'G9 the "Sign in to <app> with Google / Continue" confirm is allowed' 'allow continue' "$(g "$AC/signin/oauth/id?authuser=0&part=x" "$CONT")"
t 'G9b "Continue as Alex" is allowed' 'allow continue' "$(g "$AC/v3/signin/x" '<html><body><button>Continue as Alex</button></body></html>')"
t 'G10 an unverified-app warning asks' 'ask unverified' "$(g "$AC/signin/oauth/warning?x=1" '<html><body>Google hasn'"'"'t verified this app</body></html>')"
t 'G11 an unrecognised Google page stops (fail closed)' 'stop unknown' "$(g "$AC/o/oauth2/v2/auth?client_id=1" '<html><body>Error 400: redirect_uri_mismatch</body></html>')"
t 'G12 a page that is not Google is not this file'"'"'s' 'none' "$(g 'https://app.tactiq.io/signup' "$PW")"
t 'G12b nor is the rest of google.com' 'none' "$(g 'https://mail.google.com/mail/u/0/' "$PW")"
t 'G13 Google refusing the browser stops' 'stop rejected' "$(g "$AC/v3/signin/rejected?x=1" '<html><body>Couldn'"'"'t sign you in. This browser or app may not be secure.</body></html>')"

printf 'google-signin: %d pass, %d fail\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
