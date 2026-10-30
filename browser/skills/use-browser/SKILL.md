---
name: use-browser
description: Do something on a website in a real browser on the box — click, type, fill a form, search, check a page, add to a cart, star a repo, draft a reply. Use for "go to <site> and …", "buy/book/fill/submit/check … on <site>", "open <url> and …", or anything a normal fetch cannot do (JavaScript pages, clicks, forms, logged-in pages). Works with NOTHING connected; connecting a site (the connect-site skill) is only for pages where it must be the owner's account.
---

# use-browser — snapshot, act by ref, verify; the owner says yes to pay

`5dive browser <verb> <url>` drives a real Chrome on this box. The URL picks the profile: the
owner's one login for that site, or the public profile (nothing logged in). **Start with the
verb.** Never run `--help`, `status` or setup first: this page is the manual, and a public page
needs nothing connected.

## The loop: ONE snapshot per decision

```bash
5dive browser snapshot <url> --interactive     # prints the page text and the refs you can act on
5dive browser act <url> --steps='[{"op":"fill","selector":"ref=textbox/Title","value":"Bug: …"},
                                  {"op":"click","selector":"ref=button/Save draft"}]' --expect='Draft saved'
```

1. **Snapshot** with `--interactive` and pick refs from what it printed. Never invent a ref.
   Exit 76 is a loading screen, not the page: run it again with `--wait-for='text=<words the
   loaded page has>'`. Never guess a CSS selector for `--wait-for`; a miss waits 10 s.
2. **Act** on those refs. `--steps` is a JSON array, never empty, run in order in one tab. Each
   step is one of:
   `{"op":"goto","url":…}` `{"op":"click","selector":…}` `{"op":"fill","selector":…,"value":…}`
   `{"op":"type","selector":…,"value":…}` `{"op":"select","selector":…,"value":…}`
   `{"op":"press","selector":…,"key":"Enter"}` `{"op":"wait_for","selector":"text=…"}`.
   A selector is `ref=<role>/<name>` from the snapshot; a control inside an embedded frame is
   `ref=frame:<frame> >> <role>/<name>`, copied whole. Use `type` for search boxes and
   autocompletes that react to keystrokes, and `fill` for plain inputs. An act with a URL loads
   the page fresh, so fill and submit a form in one act; without a URL it carries on in the page
   the browser is on. **An act prints what it changed**: the refs that appeared (`+ ref=…`), the
   ones that went and the new text. Act on those refs next; snapshot again only when the ref you
   need is not there.
3. **Verify** with `--expect=<regex>` only on the act that does the job (the save, the send,
   the search whose result you report): the words that prove it, matched on screen for up to
   2 s. A click that only opens a page or a menu needs no `--expect`: what it changed is printed.
   **A matched `--expect` IS the check:** report and move on, never re-open the page to confirm.
   Between steps, go by the text and refs the act printed, never the picture. Open the
   `page.png` once, at the end, only when no `--expect` matched, before you say the job worked.

## Reading pages

```bash
5dive browser read <url1> <url2> <url3>        # several pages: ONE call, loaded side by side
```

- **A job that names several pages reads them in one `read`**, never one call per page.
- `read` prints each page's facts first (`- label: value` lines from its infobox or spec
  table), then the head of its text. Take a fact from the facts when it is there.
- **Read a page once.** The whole page is in the `page.md` it names: grep that file for more,
  do not read the page again. `--full` prints all of it.
- `snapshot --interactive` prints every ref (up to 300) and a small page's text; `cat page.md`
  only for a big one. `snapshot _public` with no URL reads the page the browser is on.
- `links <url>` gives a page's links, `shot <url>` a picture of it.

## Paying, posting, sending and deleting are the owner's call

The default is **standard**: post, send and delete steps run and are logged for the owner, and
a **pay step stops**: `act` exits **73** with an ask, a screenshot and an approval id. Relay the
ask to the owner with the screenshot, in plain words: what is bought, sent or deleted, and
where. The owner approves, not you: their Telegram button or `sudo 5dive browser approve <id>`.
With no Telegram, put it on your row as ONE ask: `5dive task need <row> --type=approval
--browser-ask=<id> --ask="…"`; the owner's yes there is the approval. Then re-run the same act
with `--approved=<id>`. Going to the checkout page is not paying: only the button that charges
(Pay, Place order, Complete purchase, Buy) stops. `5dive browser approvals policy` shows
the policy; `approvals policy set careful` (the owner's, never yours) makes all four ask.
**Do not rephrase the steps** to get past a stop: a renamed button is still an order placed. If
a step will pay and `act` does not stop it, ask first anyway.

## Hard stops: never solve, never guess

- A captcha, "verify you are human" or "Just a moment…" that did not clear: never solve it.
  Run the `connect-request <site> --challenge` command the verb prints, then wait for the
  owner's Done.
- A sign-in form, a password, a 2FA code or a certificate warning: stop. Never type the owner's
  password. A page that must be the owner's account: the `connect-site` skill.
- A sign-in form with no saved login: never ask for a password in chat. Run
  `5dive browser login-ask <site>`; on your next turn fill `"saved":"<name>.login"` / `.password` / `.2fa`.
- Two accounts on one site (`github.com_work`, `github.com_personal`): ask the owner which one,
  never guess, then name it: `5dive browser act github.com_work <url> …`.

## Read more only when you need it

These files sit next to this one, in `references/`:

- `references/lessons.md`: before a form, a sign-up, a post or an upload; downloads and popups.
- `references/logins.md`: a sign-in stop, Google sign-up, a captcha, a blocked server IP, a proxy.
- `references/input-mode.md`: a verb says "INPUT mode", the site is tiktok.com or cjdropshipping.com,
  a new API key shows only a Copy button, code to paste, or the box's window is stuck.
- `references/paying.md`: the whole pay/post/send/delete rule, when an act exits 73.
- `references/repeat.md`: a flow you will run again (`--record`, `replay`, `--delta`).
