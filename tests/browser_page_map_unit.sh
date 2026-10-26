#!/usr/bin/env bash
# DIVE-6965 — the ref walk lists what a person can click, not only what ARIA names.
#
# On bench v3 OpenClaw passed 14 tasks 5dive failed. On 4 of them the control was on
# the page and `snapshot --interactive` did not list it: WebMD's calendar arrow and day
# cells (role-less divs drawn with a pointer), FedEx's Usercentrics cookie banner (its
# buttons in a shadow root, so every later click hit the banner), Adopt-a-Pet's custom
# breed box. Table: bench/matrix-6848-2026-10-25/causes-6965.md.
#
# DIVE-7007 adds Shopify admin's new-product form (Polaris web components): its
# Description is a TinyMCE <body contenteditable> with no role, and each Status option
# draws its label and its small print through two <slot>s, so the map offered the
# small print and not "Draft". M15-M19 and X4-X7 grade that.
#
# Graded against a DOM shim (the T23a pattern in browser_plugin_unit.sh: this suite
# needs no Chrome and no jsdom). The shim implements the surface pageWalk touches,
# including an INHERITED cursor, so the "outermost pointer only" rule is really tested.
set -uo pipefail
cd "$(dirname "$0")/.."
ARIA="$PWD/browser/lib/aria.cjs"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }
tn() { if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected NOT to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }

cat > "$TMP/map.js" <<'MAP'
const { pageWalk, INTERACTIVE } = require(process.env.ARIA);
const docs = [];
class Root {   // the document, or a shadow root: what querySelectorAll('*') walks
  constructor(kids, host = null) { this.kids = kids; this.host = host; this.nodeType = 11;
    kids.forEach(k => { k.parent = null; k.root = this; }); }
  get childNodes() { return this.kids; }
  flat() { const out = []; const go = (e) => { out.push(e); e.kids.forEach(go); }; this.kids.forEach(go); return out; }
  querySelectorAll() { return this.flat(); }
  getElementById(id) { return this.flat().find(e => e.id === id) || null; }
  querySelector(sel) { const m = /^label\[for="(.*)"\]$/.exec(sel);
    return m ? this.flat().find(e => e.tagName === 'LABEL' && e.getAttribute('for') === m[1]) || null : null; }
}
class El {
  // css: { cursor, display } own declarations; a cursor is inherited, display is not
  constructor(tag, attrs = {}, text = '', kids = [], css = {}) {
    this.tagName = tag.toUpperCase(); this._a = attrs; this._t = text; this.kids = kids; this.css = css;
    kids.forEach(k => { k.parent = this; });
  }
  get parentElement() { return this.parent || null; }
  get nodeType() { return 1; }
  // the element's own text is one text node before its children, as textContent reads it
  get childNodes() { if (!this._tn) this._tn = { nodeType: 3, nodeValue: this._t }; return (this._t ? [this._tn] : []).concat(this.kids); }
  assignedNodes() { return this.assigned || []; }   // a <slot>'s; set where the fixture slots something
  get isContentEditable() { const v = this.getAttribute('contenteditable');
    if (v === 'true' || v === '') return true; if (v === 'false') return false; return !!(this.parent && this.parent.isContentEditable); }
  get id() { return this._a.id || ''; }
  getAttribute(n) { return Object.prototype.hasOwnProperty.call(this._a, n) ? this._a[n] : null; }
  hasAttribute(n) { return Object.prototype.hasOwnProperty.call(this._a, n); }
  setAttribute(n, v) { this._a[n] = v; }
  get textContent() { return this._t + this.kids.map(k => k.textContent).join(''); }
  closest(sel) { let n = this; const tag = sel.toUpperCase();
    while (n) { if (n.tagName === tag) return n; n = n.parent; } return null; }
  getRootNode() { let n = this; while (n.parent) n = n.parent; return n.root; }
  get ownerDocument() { return DOC; }
  getClientRects() { return [{}]; }
  // the CONTROL selector pageWalk uses: tags and the [role=x] / a[href] forms
  querySelector(sel) {
    const want = sel.split(',').map(s => s.trim());
    const hit = (e) => want.some(w => {
      let m;
      if ((m = /^\[role=(\w+)\]$/.exec(w))) return e.getAttribute('role') === m[1];
      if (w === 'a[href]') return e.tagName === 'A' && e.hasAttribute('href');
      return e.tagName === w.toUpperCase();
    });
    const go = (e) => { for (const k of e.kids) { if (hit(k)) return k; const r = go(k); if (r) return r; } return null; };
    return go(this);
  }
}
// inherited along the tree the page DRAWS: a slotted child from its slot, a shadow root's top from its host
const cursorOf = (e) => e ? (e.css.cursor || cursorOf(e.assignedSlot || e.parent || (e.root && e.root.host))) : 'auto';
const DOC = {
  defaultView: { getComputedStyle: (e) => ({ display: e.css.display || 'block', visibility: 'visible', cursor: cursorOf(e) }) },
};
const P = { cursor: 'pointer' };

// ---- the page --------------------------------------------------------------
const banner = new El('aside', { id: 'usercentrics-cmp-ui' });
banner.shadowRoot = new Root([
  new El('button', {}, 'Accept All'),
  new El('button', {}, 'Deny'),
  new El('label', { for: 'pref' }, 'Remember me'),
  new El('input', { id: 'pref', type: 'checkbox' }),
]);
// Shopify's Status picker option: a custom element whose shadow root draws a pointer
// div holding two slots, the label (the host's own text) and the small print
// (a <span slot=details>), in that order. textContent reads the host's light DOM only.
const options = [];
function option(label, details) {
  const small = new El('span', { slot: 'details' }, details);
  const host = new El('s-internal-picker-option', {}, label, [small]);
  const sLabel = new El('slot'), sDetails = new El('slot', { name: 'details' });
  host.shadowRoot = new Root([new El('div', {}, '', [sLabel, sDetails], P)], host);
  sLabel.assigned = [host.childNodes[0]]; sDetails.assigned = [small]; small.assignedSlot = sDetails;
  options.push(host.shadowRoot);
  return host;
}
const body = new El('body', {}, '', [
  // Shopify's Description: a rich-text editor's editing host, a paragraph inside it
  new El('div', { contenteditable: 'true', 'aria-label': 'Rich Text Area' }, '', [new El('p', {}, 'Ceremonial grade')]),
  // a contenteditable that names its own role keeps it
  new El('div', { contenteditable: 'true', role: 'searchbox', 'aria-label': 'Find' }),
  new El('div', { class: 'picker' }, '', [
    option('Active', 'Sell via selected sales channels and markets'),
    option('Draft', 'Not visible on selected sales channels or markets'),
  ]),
  new El('a', { href: '/inbox' }, 'Inbox'),
  // a calendar: the arrow has no text, the day cells are divs, spans inside inherit the cursor
  new El('div', { class: 'cal' }, '', [
    new El('div', { class: 'cal-prev' }, '', [], P),
    new El('div', { class: 'cal-title' }, 'October 2026'),
    new El('div', { class: 'day' }, '', [new El('span', {}, '1')], P),
    new El('div', { class: 'day' }, '', [new El('span', {}, '2')], P),
  ]),
  // a card drawn with a pointer that wraps a real link: the link answers for it
  new El('div', { class: 'card' }, '', [new El('a', { href: '/p' }, 'Product page')], P),
  // a span inside a button: the button answers for it
  new El('button', {}, '', [new El('span', {}, 'Search')], P),
  // a cell with a handler and no pointer
  new El('td', { onclick: 'pick()' }, 'Tuesday'),
  // an accordion heading drawn with a pointer
  new El('h3', {}, 'Shipping options', [], P),
  // a pointer div the page hides
  new El('div', {}, 'Hidden pick', [], { cursor: 'pointer', display: 'none' }),
  // plain text, no pointer
  new El('span', {}, 'just text'),
  banner,
]);
const page = new Root([body]);
global.document = page;
global.CSS = { escape: (s) => s };
const mode = process.argv[2];
const r = pageWalk({ interactiveOnly: mode === 'interactive', interactiveRoles: INTERACTIVE, mark: process.argv[3] || null });
const shadows = [banner.shadowRoot, ...options];
const stamped = [...page.flat(), ...shadows.flatMap(s => s.flat())].filter(e => e.getAttribute('data-5dive-ref'));
console.log(JSON.stringify({ refs: r.nodes.map(n => n.ref), marker: r.marker,
  marked: stamped.map(e => e.tagName.toLowerCase() + (shadows.includes(e.getRootNode()) ? '@shadow' : '')) }));
MAP

REFS="$(ARIA="$ARIA" node "$TMP/map.js" interactive | jq -r '.refs|join(" ")')"
t  'M0 (control) the walk runs on the shim' 'yes' "$([[ -n "$REFS" ]] && echo yes || echo no)"
tc 'M0 (control) a real link is still a link' 'link/Inbox' "$REFS"

# a calendar a person clicks
tc 'M1 a role-less div drawn with a pointer is offered (calendar arrow, no text: an empty name)' ' clickable/ ' " $REFS "
tc 'M1b a day cell is offered by its text' 'clickable/1' "$REFS"
tc 'M1c ...and the next one' 'clickable/2' "$REFS"
tn 'M2 a span that only INHERITS the pointer is not offered on its own' 'clickable/1#' "$REFS"
tn 'M2b the calendar title, no pointer, is not offered' 'October 2026' "$REFS"

# a wrapper answers for nothing its control answers for
tc 'M3 (control) the link inside a pointer card is offered' 'link/Product page' "$REFS"
tn 'M3b ...and the card around it is not' 'clickable/Product page' "$REFS"
tc 'M4 (control) a button is offered as a button' 'button/Search' "$REFS"
tn 'M4b ...and its span is not a second, clickable copy' 'clickable/Search' "$REFS"

tc 'M5 a cell with an onclick and no pointer is offered' 'clickable/Tuesday' "$REFS"
tc 'M6 a heading drawn with a pointer is offered as clickable' 'clickable/Shipping options' "$REFS"
tn 'M7 a pointer element the page hides is not offered' 'Hidden pick' "$REFS"
tn 'M8 plain text is not offered' 'just text' "$REFS"

# a shadow root
tc 'M9 a button inside a shadow root is offered (Usercentrics)' 'button/Accept All' "$REFS"
tc 'M9b ...the other one too' 'button/Deny' "$REFS"
tc 'M10 a label[for] inside a shadow root names its field' 'checkbox/Remember me' "$REFS"

# ONE WALK: mark mode stamps the element tree printed, inside the shadow root too
MK="$(ARIA="$ARIA" node "$TMP/map.js" all 'button/Deny')"
t  'M11 marking a shadow-root ref stamps exactly that element, in the shadow root' 'button@shadow' "$(jq -r '.marked|join(" ")' <<<"$MK")"
t  'M11b ...and reports the marker the step selector is built from' 'yes' "$(jq -r '.marker' <<<"$MK" | grep -q '^r[0-9]' && echo yes || echo no)"
MK2="$(ARIA="$ARIA" node "$TMP/map.js" all 'clickable/2')"
t  'M12 marking a clickable stamps its div, not the span inside' 'div' "$(jq -r '.marked|join(" ")' <<<"$MK2")"
ALLREFS="$(ARIA="$ARIA" node "$TMP/map.js" all | jq -r '.refs|join(" ")')"
tc 'M13 the full tree lists the same clickables as --interactive' 'clickable/1 clickable/2' "$ALLREFS"
t  'M14 clickable is an interactive role (look.cjs and the loading-screen count read the list)' 'yes' \
   "$(node -e 'process.stdout.write(require(process.argv[1]).INTERACTIVE.includes("clickable")?"yes":"no")' "$ARIA")"

# Shopify's new-product form (DIVE-7007)
tc 'M15 a rich-text editor with no role is a text field, by its label (Description)' 'textbox/Rich Text Area' "$REFS"
tn 'M15b ...once: what is inside the editor is not a second field' 'textbox/Ceremonial' "$REFS"
tc 'M15c (control) a contenteditable that names its role keeps it' 'searchbox/Find' "$REFS"
tc 'M16 a picker option is named by what it draws, label then small print (Status: Draft)' \
   'clickable/Draft Not visible on selected sales channels or markets' "$REFS"
tc 'M16b ...the other option too' 'clickable/Active Sell via selected sales channels and markets' "$REFS"
tn 'M17 the small print slotted into an option is not a second clickable' ' clickable/Not visible' " $REFS"
tn 'M17b ...nor the other one' ' clickable/Sell via' " $REFS"
MK3="$(ARIA="$ARIA" node "$TMP/map.js" interactive 'clickable/Draft Not visible on selected sales channels or markets')"
t  'M18 marking the Draft option stamps its drawn div, in its shadow root' 'div@shadow' "$(jq -r '.marked|join(" ")' <<<"$MK3")"
MK4="$(ARIA="$ARIA" node "$TMP/map.js" interactive 'textbox/Rich Text Area')"
t  'M18b marking the editor stamps the editing host' 'div' "$(jq -r '.marked|join(" ")' <<<"$MK4")"
t  'M18c (control) M0-M14 refs are unchanged by the drawn-text read' 'link/Inbox clickable/ clickable/1 clickable/2' \
   "$(tr ' ' '\n' <<<"$REFS" | grep -E '^(link/Inbox|clickable/|clickable/[12])$' | paste -sd' ')"

# --wait-for=<css> looks into open shadow roots, as the step's own selector does
cat > "$TMP/vis.js" <<'VIS'
const { _visibleIn } = require(process.env.ARIA);
const doc = { defaultView: { getComputedStyle: () => ({ display: 'block', visibility: 'visible' }) } };
const el = (m, kids = []) => ({ m, kids, getClientRects: () => [{}], ownerDocument: doc });
const root = (kids) => ({ querySelectorAll: (s) => { const all = []; const go = (e) => { all.push(e); (e.kids || []).forEach(go); }; kids.forEach(go);
  return s === '*' ? all : all.filter(e => e.m === s); } });
const field = el('s-internal-text-field'); field.shadowRoot = root([el('input[name=title]')]);
global.document = Object.assign(root([el('main', [field])]), { body: { innerText: 'Add product' } });
console.log([_visibleIn({ target: 'input[name=title]', mode: 'auto' }), _visibleIn({ target: 'input[name=price]', mode: 'auto' })].join(' '));
VIS
t  'M19 --wait-for=<css> finds a field drawn in a shadow root; an absent one stays absent' 'true false' \
   "$(ARIA="$ARIA" node "$TMP/vis.js" 2>&1)"

# ---- the mutants: each part of the change, removed, turns its arm red ---------
MUT="$TMP/mut"; mkdir -p "$MUT"
sed 's/      if (els\[j\].shadowRoot) elements(els\[j\].shadowRoot, into);//' "$ARIA" > "$MUT/noshadow.cjs"
t  'X1 (anchor) the no-shadow mutant really differs' 'yes' "$(cmp -s "$ARIA" "$MUT/noshadow.cjs" && echo no || echo yes)"
tn 'X1b without the shadow walk the banner button is gone' 'button/Deny' \
   "$(ARIA="$MUT/noshadow.cjs" node "$TMP/map.js" interactive | jq -r '.refs|join(" ")')"
sed "s/    if (!interactive\[role\] && clickable(el)) role = 'clickable';//" "$ARIA" > "$MUT/noclick.cjs"
t  'X2 (anchor) the no-clickable mutant really differs' 'yes' "$(cmp -s "$ARIA" "$MUT/noclick.cjs" && echo no || echo yes)"
tn 'X2b without it the calendar day is gone' 'clickable/1' \
   "$(ARIA="$MUT/noclick.cjs" node "$TMP/map.js" interactive | jq -r '.refs|join(" ")')"
sed 's/ || pointer(drawnParent(el)))) return false;/)) return false;/' "$ARIA" > "$MUT/noinherit.cjs"
t  'X3 (anchor) the inherited-cursor mutant really differs' 'yes' "$(cmp -s "$ARIA" "$MUT/noinherit.cjs" && echo no || echo yes)"
tc 'X3b without the parent test the inner span is offered too' 'clickable/1#' \
   "$(ARIA="$MUT/noinherit.cjs" node "$TMP/map.js" interactive | jq -r '.refs|join(" ")')"

sed '/el.isContentEditable === true && !(el.parentElement/d' "$ARIA" > "$MUT/noedit.cjs"
t  'X4 (anchor) the no-editor mutant really differs' 'yes' "$(cmp -s "$ARIA" "$MUT/noedit.cjs" && echo no || echo yes)"
tn 'X4b without it the Description editor is gone' 'textbox/Rich Text Area' \
   "$(ARIA="$MUT/noedit.cjs" node "$TMP/map.js" interactive | jq -r '.refs|join(" ")')"
sed "s/    return deep ? parts.join('') : null;/    return null;/" "$ARIA" > "$MUT/nodrawn.cjs"
t  'X5 (anchor) the no-drawn-text mutant really differs' 'yes' "$(cmp -s "$ARIA" "$MUT/nodrawn.cjs" && echo no || echo yes)"
tn 'X5b without it the Draft option has no name a seat can pick' 'clickable/Draft' \
   "$(ARIA="$MUT/nodrawn.cjs" node "$TMP/map.js" interactive | jq -r '.refs|join(" ")')"
sed '/    if (el.assignedSlot) return el.assignedSlot;/d' "$ARIA" > "$MUT/noslot.cjs"
t  'X6 (anchor) the no-slot-parent mutant really differs' 'yes' "$(cmp -s "$ARIA" "$MUT/noslot.cjs" && echo no || echo yes)"
tc 'X6b without it the slotted small print is offered as its own clickable' ' clickable/Not visible' \
   " $(ARIA="$MUT/noslot.cjs" node "$TMP/map.js" interactive | jq -r '.refs|join(" ")')"
sed 's/  try { els = deep(document, \[\]); } catch (e) { els = null; }/  try { els = document.querySelectorAll(t); } catch (e) { els = null; }/' "$ARIA" > "$MUT/noshadowwait.cjs"
t  'X7 (anchor) the light-DOM-wait mutant really differs' 'yes' "$(cmp -s "$ARIA" "$MUT/noshadowwait.cjs" && echo no || echo yes)"
t  'X7b without it the shadow-drawn field is never seen' 'false false' "$(ARIA="$MUT/noshadowwait.cjs" node "$TMP/vis.js" 2>&1)"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
