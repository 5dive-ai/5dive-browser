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

# --- DIVE-6241: judge only the scopes Google lists --------------------------------
# Round 2 refused Allow on two consents that ask for profile + email + openid only
# (shots A-coda.io-last-page, AG3-whimsical-consent-basic-profile; the text below is
# transcribed from them, in Google's "This will allow <app> to:" layout). Coda's app
# is named "Superhuman Docs", and "docs" is a Drive word. Whimsical's page HTML was
# not kept, so its trigger is not recoverable; G15b grades the one the screen does
# not show (a hidden info box nested inside a hidden block).
legacy() {  # legacy <app> <scope lines as <li>…</li>> [extra markup before the footer]
  printf '%s' "<html><head><title>Sign in - Google Accounts</title></head><body><div>Google</div><h1><a href=\"#\">$1</a> wants to access your Google Account</h1><div>atorn864@gmail.com</div><div>This will allow <a href=\"#\">$1</a> to:</div><ul>$2</ul>${3:-}<div>By clicking Allow, you allow this app and Google to use your information in accordance with their respective terms of service and privacy policies. You can change this and other Account Permissions at any time.</div><button>Deny</button><button>Allow</button></body></html>"; }
BASIC3="<li><div>See your personal info, including any personal info you've made publicly available</div><div role=\"button\" aria-label=\"More info\"></div></li><li><div>See your primary Google Account email address</div></li><li><div>Associate you with your personal info on Google</div></li>"
LC="$AC/signin/oauth/legacy/consent?authuser=0&part=x"
t 'G14 Coda ("Superhuman Docs") asking profile, email and openid only is allowed' 'allow basic-consent' "$(g "$LC" "$(legacy 'Superhuman Docs' "$BASIC3")")"
t 'G14b ...on the OAuth URL that names exactly those scopes too' 'allow basic-consent' \
  "$(g "$AC/o/oauth2/auth?client_id=1&scope=openid%20email%20profile" "$(legacy 'Superhuman Docs' "$BASIC3")")"
t 'G14c an app name full of wide words, asking basic only, is allowed' 'allow basic-consent' \
  "$(g "$LC" "$(legacy 'Drive Calendar Contacts Photos' "$BASIC3")")"
t 'G15 Whimsical asking basic only is allowed' 'allow basic-consent' "$(g "$LC" "$(legacy 'Whimsical' "$BASIC3")")"
HIDDENINFO='<div aria-hidden="true"><div class="info"><div>About this access</div></div><div>Whimsical will see the files and calendars you share</div></div>'
t 'G15b a hidden info box, nested, is not on the screen' 'allow basic-consent' "$(g "$LC" "$(legacy 'Whimsical' "$BASIC3" "$HIDDENINFO")")"
t 'G15c ...and neither is a box to tick inside a hidden block' 'allow basic-consent' \
  "$(g "$LC" "$(legacy 'Whimsical' "$BASIC3" '<div hidden><div><input type="checkbox" name="s"></div></div>')")"
# what must still ask (the negative arms)
CAL="<li><div>See, edit, share, and permanently delete all the calendars you can access using Google Calendar</div></li>$BASIC3"
t 'G16 Calendly asking for every calendar still asks (round 2 AG6, the correct ask)' 'ask wide-consent' "$(g "$LC" "$(legacy 'Calendly' "$CAL")")"
t 'G16b "Superhuman Docs" asking for Drive files asks' 'ask wide-consent' \
  "$(g "$LC" "$(legacy 'Superhuman Docs' "<li><div>See, edit, create, and delete only the specific Google Drive files you use with this app</div></li>$BASIC3")")"
t 'G16c a contacts scope asks, whatever the app is called' 'ask wide-consent' \
  "$(g "$LC" "$(legacy 'Whimsical' "<li><div>See and download your contacts</div></li>$BASIC3")")"
t 'G16d a visible box to tick per permission asks' 'ask wide-consent' \
  "$(g "$LC" "$(legacy 'Whimsical' "$BASIC3<li><input type=\"checkbox\" name=\"s\"><div>Manage your tasks</div></li>")")"
t 'G16e a calendar scope in the URL asks even on a basic-looking screen' 'ask wide-consent' \
  "$(g "$AC/o/oauth2/auth?client_id=1&scope=openid%20email%20https://www.googleapis.com/auth/calendar" "$(legacy 'Whimsical' "$BASIC3")")"
t 'G16g an app NAMED like a wide scope line does not erase that line' 'ask wide-consent' \
  "$(g "$LC" "$(legacy 'See your Google Drive files' "<li><div>See your Google Drive files</div></li>$BASIC3")")"
t 'G16h "Superhuman Docs will be able to" inside the list is the name, not Drive' 'allow basic-consent' \
  "$(g "$LC" "$(legacy 'Superhuman Docs' "<li>Superhuman Docs will be able to:</li>$BASIC3")")"
t 'G16f a hidden block that never closes is kept on the screen (the stricter reading)' 'ask wide-consent' \
  "$(g "$LC" "$(legacy 'Whimsical' "<li><div aria-hidden=\"true\">x</li><li>See your Google Drive files</li>")")"

# --- DIVE-6247: round 3's stop pages, real captures (trimmed to what a person sees) --
# tests/fixtures/dive-6247/ is visibleMarkup() of the round-3 page.html each arm
# names (marketing/reddit/2026-10-14-r3-shots/g-artifacts/), links and hidden values
# blanked. Each arm also names what 1.40.0 said on the same page.
FX="$PWD/tests/fixtures/dive-6247"
gf() { node "$LIB" "$FX/$2" "$1" | jq -r '"\(.verdict) \(.kind)"'; }
t 'G17 Pitch: basic consent with the profile detail list ("See your gender") is allowed (1.40.0: ask)' \
  'allow basic-consent' "$(gf "$LC" pitch-consent.html)"
t 'G17b Tally: the same consent, allowed (1.40.0: ask)' 'allow basic-consent' "$(gf "$LC" tally-consent.html)"
t 'G17c NEGATIVE: Calendly, calendar scope on top of the same detail lists, still asks' 'ask wide-consent' \
  "$(gf "$LC" calendly-consent.html)"
t 'G17d ...naming the calendar, not a word from a detail list' 'yes' \
  "$(node "$LIB" "$FX/calendly-consent.html" "$LC" | jq -r '.why' | grep -q '"calendars"' && echo yes || echo no)"
DETAIL='<div><div>See your personal info</div><div><a></a><div><p>This app wants permission to:</p><li>See your gender</li><li>See your preferred languages</li></div></div></div>'
t 'G17e a detail list is dropped with everything in it' 'allow basic-consent' "$(g "$LC" "$(legacy 'Whimsical' "<li>$DETAIL</li>")")"
t 'G17f NEGATIVE: "See your gender" as a TOP-LEVEL line still asks' 'ask wide-consent' \
  "$(g "$LC" "$(legacy 'Whimsical' "<li><div>See your gender</div></li>$BASIC3")")"
t 'G17g NEGATIVE: a detail block that never closes is kept (the stricter reading)' 'ask wide-consent' \
  "$(g "$LC" "$(legacy 'Whimsical' "<li><div><p>This app wants permission to:</p><li>See your gender</li>")")"
t 'G17h NEGATIVE: a Drive line beside the detail lists still asks' 'ask wide-consent' \
  "$(g "$LC" "$(legacy 'Whimsical' "<li>$DETAIL</li><li><div>See and download all your Google Drive files</div></li>")")"
CH="$AC/v3/signin/accountchooser?access_type=online&client_id=945160079396&prompt=select_account&redirect_uri=https%3A%2F%2Fwhimsical.com%2Flogin-google%2F&scope=profile+email&continue=https%3A%2F%2Faccounts.google.com%2Fsignin%2Foauth%2Flegacy%2Fconsent"
t 'G18 Whimsical: the chooser round 3 saw ("alex torn") is allowed' 'allow chooser' "$(gf "$CH" whimsical-chooser.html)"
t 'G18b Coda: its chooser is allowed' 'allow chooser' "$(gf "$CH" coda-chooser.html)"
t 'G18c Google'"'"'s 400 at the bare chooser path is an error, not "no saved account" (1.40.0: stop add-account)' \
  'stop error' "$(gf "$AC/v3/signin/accountchooser" chooser-400.html)"
t 'G18d NEGATIVE: Google'"'"'s email box still stops as adding an account' 'stop add-account' \
  "$(gf "$AC/v3/signin/identifier?flowName=GeneralOAuthFlow" add-account.html)"
t 'G18e NEGATIVE: a chooser with only "Use another account" still stops' 'stop add-account' \
  "$(g "$CH" '<html><body><h1>Choose an account</h1><div>Use another account</div></body></html>')"
t 'G18f NEGATIVE: an error page carrying a password box still stops at the password' 'stop password' \
  "$(g "$AC/v3/signin/accountchooser" '<html><body>400. That'"'"'s an error.<input type="password" name="Passwd"></body></html>')"
t 'G18g NEGATIVE: a robot check outranks an error page' 'stop robot' \
  "$(g "$AC/v3/signin/accountchooser" '<html><body>400. That'"'"'s an error. Our systems have detected unusual traffic</body></html>')"

# samePage: the page a browser is on, asked for again with its query cut (DIVE-6247)
sp() { node "$LIB" --same-page "$1" "$2" && echo same || echo different; }
t 'G19 the chooser asked for with its whole query gone is the same page' same "$(sp "$CH" "$AC/v3/signin/accountchooser")"
t 'G19b ...with the query cut mid-parameter' same "$(sp "$CH" "${CH:0:150}")"
t 'G19c ...with parameters dropped from the middle' same "$(sp "$CH" "$AC/v3/signin/accountchooser?client_id=945160079396&scope=profile+email")"
t 'G19d NEGATIVE: another Google page is not the same page' different "$(sp "$CH" "$LC")"
t 'G19e NEGATIVE: a parameter with another value is not the same page' different "$(sp "$CH" "$AC/v3/signin/accountchooser?client_id=1")"
t 'G19f NEGATIVE: a parameter the page does not have is not the same page' different "$(sp "$CH" "$AC/v3/signin/accountchooser?hl=fr")"
t 'G19g NEGATIVE: another host is not the same page' different "$(sp "$CH" "https://accounts.example.com/v3/signin/accountchooser")"
t 'G19h a site'"'"'s own sign-in page, its query cut, is the same page' same \
  "$(sp 'https://id.superhuman.com/signin?oauth_client_type=MEDIATED_WEB&client_id=superhumanDocs' 'https://id.superhuman.com/signin')"
t 'G19i NEGATIVE: an ordinary page needs the exact URL (page 2 of a search is not page 1)' different \
  "$(sp 'https://shop.test/search?q=shoes&page=2' 'https://shop.test/search?q=shoes')"
t 'G19j the exact URL is always the same page' same "$(sp 'https://shop.test/search?q=shoes' 'https://shop.test/search?q=shoes')"

printf 'google-signin: %d pass, %d fail\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
