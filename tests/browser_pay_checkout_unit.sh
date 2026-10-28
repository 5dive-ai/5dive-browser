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
#   H1-H2  a stop that reached no chat names the one gate whose yes approves it
#          (task need --browser-ask=<id>); a stop sent on Telegram does not.
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
