#!/usr/bin/env bash
# DIVE-7164 — going to the pay page is not paying, and one owner yes is enough.
#
# On the Dropshipping trial's rerun (DIVE-6902) the owner said yes to "fill the
# order to the pay button", and the browser stopped anyway on Shopify's "Secure
# Checkout" link, as a pay, with $2.99 off the cart as its amount. Then only a
# shell user could give the second yes.
#
#   P1-P3  Checkout, Check out, Proceed to checkout/payment and Secure Checkout
#          are not pay; Pay now, Place order, Complete purchase, Buy and the
#          verbs that finish one (Complete/Confirm/Finish checkout) still are.
#   P4     the same through stepRisk on a page: the click on "Secure Checkout"
#          runs, the click on "Pay now" stops with the Total, not the Subtotal.
#   P5     PRE-FIX: the 1.59.0 table (git show a64e495) stops "Secure Checkout".
#   F1-F7  DIVE-7670: a click INTO a text field only focuses it, so the field's
#          typed value is never its label (Shopify's email Subject box held
#          "Complete your order" and stopped as a pay). A submit input's value
#          and a button's text still stop; Enter still reads the form's submit.
#   F8-F9  MUTANTS: with both halves deleted F1 stops again; with the text-entry
#          check alone deleted, the textarea holding "Buy now" stops again.
#   H1-H2  a stop that reached no chat names the one gate whose yes approves it
#          (task need --browser-ask=<id>); a stop sent on Telegram does not.
#   C1-C9  DIVE-9502: a menu card is classified by its title, not its description.
#          "Automation builder" over "Accept payments, sell with Pay, upgrade any
#          time" does not stop, by selector or by its snapshot ref (whose name is the
#          whole card on one line); a card titled "Buy now" still stops; a ref that
#          names something else (Send) is still read whole. PRE-FIX (330d4ee) and
#          mutants with either cut reverted stop the card.
#   H3     the stop says the owner approves by tapping the card, a typed yes does
#          not, and how to cite a chat answer so the buttons are sent again.
#
# Run: bash tests/browser_pay_checkout_unit.sh (node, no browser, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"; ARIA="$ROOT/browser/lib/aria.cjs"; BROWSER="$ROOT/browser/bin/browser"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); echo "ok   - $1"; else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); echo "ok   - $1"; else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }
tn() { if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); echo "ok   - $1"; else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected NOT to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }

cls() { node -e 'const a=require(process.argv[1]); console.log(process.argv.slice(2).map(x=>String(a.classifyLabel(x))).join(" "))' "$1" "${@:2}"; }

t 'P1 the way to the pay page is not a payment' 'null null null null null null' \
  "$(cls "$ARIA" 'Secure Checkout' 'Checkout' 'Check out' 'Proceed to checkout' 'Proceed to payment' 'Continue to payment')"
t 'P2 the button that charges still stops' 'pay pay pay pay pay pay pay pay pay pay pay pay' \
  "$(cls "$ARIA" 'Pay now' 'Place order' 'Place your order' 'Complete purchase' 'Buy it now' 'Pay $60.64' 'Complete checkout' 'Confirm checkout' 'Finish checkout' 'Submit order' 'Complete your checkout' 'Confirm my order')"
t 'P3 the rest of the table is as it was' 'null publish send delete' "$(cls "$ARIA" 'Add to cart' 'Post' 'Send' 'Delete repository')"

# P4: stepRisk on a page, as act calls it before a click.
cat > "$TMP/page.js" <<'JS'
const aria = require(process.argv[2]);
const els = {
  '#co':  { innerText: 'Secure Checkout', getAttribute: () => null, closest: () => null },
  '#pay': { innerText: 'Pay now', getAttribute: () => null, closest: () => null },
};
global.document = { querySelector: (s) => els[s] || null, querySelectorAll: () => [],
  innerText: 'Subtotal $55.00\nTotal USD 60.64', location: { hostname: 'shop.example' } };
const page = { evaluate: async (fn, arg) => fn(arg) };
(async () => {
  const a = await aria.stepRisk(page, { op: 'click', selector: '#co' }, '#co');
  const b = await aria.stepRisk(page, { op: 'click', selector: '#pay' }, '#pay');
  console.log(JSON.stringify(a), b && b.cls, b && b.payload.amount);
})();
JS
t 'P4 on a page: Secure Checkout runs, Pay now stops with the Total (not the Subtotal)' 'null pay USD 60.64' "$(node "$TMP/page.js" "$ARIA")"

# P5: the table before this change, from the commit it shipped in.
if git cat-file -e a64e495:browser/lib/aria.cjs 2>/dev/null || git fetch -q --depth=1 origin a64e495 2>/dev/null; then
  git show a64e495:browser/lib/aria.cjs > "$TMP/aria-1.59.0.cjs"
  t 'P5 PRE-FIX: 1.59.0 stopped "Secure Checkout" as a payment' 'pay pay' "$(cls "$TMP/aria-1.59.0.cjs" 'Secure Checkout' 'Proceed to checkout')"
else
  echo "SKIP P5: a64e495 is not reachable from this checkout"
fi

# F: DIVE-7670 — clicking into a field is not paying. A small DOM shim: tagName,
# type, value, innerText, aria-label, contenteditable and role, as the page has them.
cat > "$TMP/field.js" <<'JS'
const aria = require(process.argv[2]);
const mk = (tag, attrs, extra) => Object.assign({ tagName: tag.toUpperCase(),
  getAttribute: (k) => (k in attrs ? attrs[k] : null), closest: () => null,
  matches: (q) => q.split(',').some((p) => { const m = p.match(/^\[([a-z-]+)(?:=(?:"([^"]*)"|([^\]]*)))?\]$/);
    return m ? (m[1] in attrs && (m[2] === undefined && m[3] === undefined ? true : String(attrs[m[1]]) === (m[2] !== undefined ? m[2] : m[3]))) : p === tag; }),
}, extra);
const form = { querySelector: () => els['#po'], getAttribute: () => null };
const els = {
  '#subj': mk('input', { 'aria-label': 'Subject' }, { type: 'text', value: 'Complete your order', innerText: '' }),
  '#ta':   mk('textarea', {}, { value: 'Buy now', innerText: 'Buy now' }),
  '#ce':   mk('div', { contenteditable: 'true' }, { isContentEditable: true, innerText: 'Post this and delete that' }),
  '#rt':   mk('div', { role: 'textbox', 'aria-label': 'Reply' }, { innerText: 'Send now' }),
  '#po':   mk('input', { type: 'submit' }, { type: 'submit', value: 'Place order', innerText: '' }),
  '#btn':  mk('button', {}, { innerText: 'Complete your order' }),
  '#cb':   mk('input', { type: 'checkbox', 'aria-label': 'Subscribe to news' }, { type: 'checkbox', value: 'on', innerText: '' }),
  '#mail': mk('input', { 'aria-label': 'Email' }, { type: 'email', value: 'buy@x.test', innerText: '', form }),
};
global.document = { querySelector: (s) => els[s] || null, querySelectorAll: () => [],
  innerText: 'Total USD 60.64', location: { hostname: 'admin.shop.example' } };
const page = { evaluate: async (fn, arg) => fn(arg) };
const r = async (sel, op, extra) => { const x = await aria.stepRisk(page, Object.assign({ op, selector: sel }, extra || {}), '#' + sel.replace(/^.*#/, '').replace(/^ref=.*/, 'subj'));
  return x ? x.cls : 'null'; };
(async () => {
  const out = [];
  for (const id of ['subj', 'ta', 'ce', 'rt']) out.push(await r('#' + id, 'click'));
  out.push(await r('ref=textbox/Subject', 'click'));
  for (const id of ['po', 'btn', 'cb']) out.push(await r('#' + id, 'click'));
  out.push(await r('#mail', 'press', { key: 'Enter' }));
  console.log(out.join(' '));
})();
JS
F=$(node "$TMP/field.js" "$ARIA")
read -r f1 f2 f3 f4 f5 f6 f7 f8 f9 <<<"$F"
t 'F1 a click into the Subject box holding "Complete your order" does not stop' null "$f1"
t 'F2 ...nor into a textarea holding "Buy now", a contenteditable, or a role=textbox' 'null null null' "$f2 $f3 $f4"
t 'F3 ...nor a ref click on a textbox, whatever the page says' null "$f5"
t 'F4 a submit input whose value is "Place order" still stops as pay' pay "$f6"
t 'F5 a button "Complete your order" still stops as pay' pay "$f7"
t 'F6 a checkbox is not a text field: "Subscribe to news" still stops' pay "$f8"
t 'F7 Enter in a field still reads its form'"'"'s submit button ("Place order")' pay "$f9"

# F8 MUTANT: delete the text-entry check (and put value back in the label) — F1 must stop again.
sed -e 's/if (entry) return null;/if (false) return null;/' -e "s/if (TEXT_ENTRY_ROLES.test(role)) return null;//" \
    -e 's/btnValue(n) ? n.value : '"''"'/n.value/' "$ARIA" > "$TMP/aria-mutant.cjs"
t 'F8 (precondition) the mutant differs from the shipped lib' yes "$(cmp -s "$ARIA" "$TMP/aria-mutant.cjs" && echo no || echo yes)"
M=$(node "$TMP/field.js" "$TMP/aria-mutant.cjs")
t 'F8 MUTANT: without the fix the Subject box stops as pay again' pay "${M%% *}"
# F9 MUTANT: fix 1 alone reverted (value still left out): a textarea holding "Buy now" stops again.
sed -e 's/if (entry) return null;/if (false) return null;/' -e "s/if (TEXT_ENTRY_ROLES.test(role)) return null;//" "$ARIA" > "$TMP/aria-mutant1.cjs"
M1=$(node "$TMP/field.js" "$TMP/aria-mutant1.cjs"); read -r _ m2 _ <<<"$M1"
t 'F9 MUTANT: without the text-entry check, the textarea holding "Buy now" stops as pay' pay "$m2"

# H: the stop's last lines, from the function act and run call (_owner_ask_deliver).
fn=$(sed -n '/^_owner_ask_deliver() {/,/^}/p' "$BROWSER")
tc 'H0 (precondition) the function is in bin/browser' '_owner_ask_deliver()' "$fn"
cat > "$TMP/cli-none" <<'SH'
#!/bin/sh
echo "not sent to the owner: seat clicker has no paired Telegram channel (no bot token or access.json)"
SH
cat > "$TMP/cli-tg" <<'SH'
#!/bin/sh
echo "sent to the owner on Telegram with Approve / Decline (1234567890) — their tap answers it; nothing runs before then."
SH
chmod +x "$TMP/cli-none" "$TMP/cli-tg"
out=$(FIVEDIVE_BROWSER_CLI="$TMP/cli-none" bash -c "$fn"$'\n''_owner_ask_deliver "$1"' _ /x/agent-clicker-1870435d65c7.json 2>&1)
tc 'H1 no chat reached the owner: the stop names the one gate whose yes approves it' \
  'task need <your row> --type=approval --browser-ask=agent-clicker-1870435d65c7' "$out"
out=$(FIVEDIVE_BROWSER_CLI="$TMP/cli-tg" bash -c "$fn"$'\n''_owner_ask_deliver "$1"' _ /x/agent-clicker-1870435d65c7.json 2>&1)
tn 'H2 sent on Telegram with a button: no second way is offered' '--browser-ask' "$out"
tc 'H2 ...and the Telegram line is still shown' 'sent to the owner on Telegram' "$out"

tc 'H3 the stop says a tap on the card approves and a typed yes does not' \
  'A typed yes in chat does not approve.' "$out"
tc 'H3 ...and how to cite a chat answer so the buttons are sent again' \
  '5dive task answer <row> yes --channel-msg=<message_id> --channel-proof=<chat_id>' "$out"

# C: DIVE-9502 — a menu card is named by its title. The card's innerText is its
# title and its description, one per line; the description sits in a <p>.
cat > "$TMP/card.js" <<'JS'
const aria = require(process.argv[2]);
const DESC = 'Accept payments, sell with Pay, upgrade any time';
const p = (t) => ({ innerText: t });
const mk = (title, desc, attrs, inline) => ({ tagName: 'DIV', innerText: inline ? title + ' ' + desc : (title ? title + '\n' : '') + desc,
  getAttribute: (k) => ((attrs || {})[k] ?? null), closest: () => null, matches: () => false,
  querySelectorAll: (q) => (q === 'p' ? [p(desc)] : []) });
const els = {
  '#ab':  mk('Automation builder', DESC),
  '#abi': mk('Automation builder', DESC, {}, true),           // title and <p> on one line
  '#lb':  mk('', DESC, { 'aria-labelledby': 'h1' }),         // named by a heading elsewhere
  '#buy': mk('Buy now', 'Ships in two days, free returns'),
  '#msg': mk('Messages', 'Your inbox'),
};
global.document = { querySelector: (s) => els[s] || null, querySelectorAll: () => [],
  getElementById: (id) => (id === 'h1' ? { innerText: 'Automation builder' } : null),
  innerText: '', location: { hostname: 'builder.example' } };
const page = { evaluate: async (fn, arg) => fn(arg) };
const r = async (selector, sel) => { const x = await aria.stepRisk(page, { op: 'click', selector }, sel); return x ? x.cls : 'null'; };
(async () => {
  const out = [];
  out.push(await r('#ab', '#ab'));
  out.push(await r('ref=menuitem/Automation builder ' + DESC, '#ab'));
  out.push(await r('#abi', '#abi'));
  out.push(await r('#lb', '#lb'));
  out.push(await r('#buy', '#buy'));
  out.push(await r('ref=menuitem/Buy now Ships in two days, free returns', '#buy'));
  out.push(await r('ref=button/Send', '#msg'));
  console.log(out.join(' '));
})();
JS
C=$(node "$TMP/card.js" "$ARIA")
read -r c1 c2 c3 c4 c5 c6 c7 <<<"$C"
t 'C1 a click on the "Automation builder" card, description "…sell with Pay, upgrade…", is not a payment' null "$c1"
t 'C2 ...nor through its snapshot ref, whose name is the whole card on one line' null "$c2"
t 'C3 ...nor when the title and the <p> description share one line' null "$c3"
t 'C4 ...nor a card named by aria-labelledby' null "$c4"
t 'C5 a card titled "Buy now" with a harmless description still stops as pay (by selector and by ref)' 'pay pay' "$c5 $c6"
t 'C6 a ref that names something else ("Send") is still read whole' send "$c7"
# PRE-FIX: the lib before this change, from origin/main 330d4ee.
if git cat-file -e 330d4ee:browser/lib/aria.cjs 2>/dev/null || git fetch -q --depth=1 origin 330d4ee 2>/dev/null; then
  git show 330d4ee:browser/lib/aria.cjs > "$TMP/aria-1.97.6.cjs"
  t 'C7 PRE-FIX: 1.97.6 stopped the builder card as a payment (selector and ref)' 'pay pay' "$(node "$TMP/card.js" "$TMP/aria-1.97.6.cjs" | cut -d' ' -f1-2)"
else
  echo "SKIP C7: 330d4ee is not reachable from this checkout"
fi
# MUTANT: the card cut reverted (said() reads the whole innerText) — C1 stops again.
sed -e 's/return first(t) || first(all);/return all;/' "$ARIA" > "$TMP/aria-mutant-card.cjs"
t 'C8 (precondition) the card mutant differs from the shipped lib' yes "$(cmp -s "$ARIA" "$TMP/aria-mutant-card.cjs" && echo no || echo yes)"
t 'C8 MUTANT: without the title cut the builder card stops as pay again' pay "$(node "$TMP/card.js" "$TMP/aria-mutant-card.cjs" | cut -d' ' -f1)"
# MUTANT: the ref-name cut reverted — the ref's whole-card name brings the description back.
sed -e "s/norm(refName).startsWith(norm(live) + ' ')) ? '' : refName;/false) ? '' : refName;/" "$ARIA" > "$TMP/aria-mutant-ref.cjs"
t 'C9 (precondition) the ref mutant differs from the shipped lib' yes "$(cmp -s "$ARIA" "$TMP/aria-mutant-ref.cjs" && echo no || echo yes)"
t 'C9 MUTANT: without the ref-name cut the builder card stops as pay by ref' pay "$(node "$TMP/card.js" "$TMP/aria-mutant-ref.cjs" | cut -d' ' -f2)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
