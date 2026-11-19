#!/usr/bin/env node
// DIVE-8755 — the end-of-task check, ENFORCED.
//
// WHY A HOOK AND NOT ANOTHER SKILL LINE. On the nightly bench a filter or sort the
// task names is never applied in about half of the misses that are not a bot wall.
// The skill already says "before you say done, check every part" and 1.94.0 added
// two more lines plus a better `select`: 4/28 against 4/28 for the control. The
// judges' reasons say "never applied", not "tried and it did not take", so the
// lever is what the agent does before it answers. This hook makes it do one pass.
//
// THE CONTRACT, each clause a test arm (tests/browser_applied_check_unit.sh):
//   - It blocks a stop ONLY when the agent drove the browser (a page verb of
//     `5dive browser`) since the owner's last message. A turn with no browser
//     call is never touched.
//   - It blocks at most ONCE per owner message: Claude Code's stop_hook_active,
//     the check's own tag already in the turn, and a per-session state file are
//     three separate guards, so a harness that drops one still cannot loop.
//   - It fails OPEN: unreadable input, a missing transcript, any exception →
//     exit 0 with nothing printed, and the agent answers as it would have.
//   - FIVEDIVE_BROWSER_APPLIED_CHECK=0 turns it off (an A/B control arm).
'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');

const TAG = '[browser applied-check]';
const PAGE_VERBS = 'snapshot|act|read|links|shot|tree|look';
// `5dive browser act _public …`, `/…/bin/browser snapshot …`; never `browser` alone,
// which could be anything on PATH.
const BROWSER_CALL = new RegExp(
  '(?:^|[\\s;&|(`"\'])(?:5dive\\s+browser|[^\\s;&|()`"\']*\\/bin\\/browser)\\s+(?:' + PAGE_VERBS + ')(?=\\s|$)', 'm');

const REASON = `${TAG} Before you answer, one pass (once per task):
1. List every filter, sort, date, place, price, size, rating and condition the task names.
2. For each one, find where the page shows it applied NOW: an active chip or a checked box, the sort control's label, a URL parameter, the results header. Read the page as it is, without loading it again: \`5dive browser act <site> --steps='[{"op":"eval","expr":"location.href"}]'\` (no URL) or \`5dive browser snapshot <site>\` (no URL). Not from memory: a later click can undo an earlier filter.
3. A part that is not shown as applied: set it now with the page's own control (the filter panel, the sort menu), then check again. Never turn a named filter off; an empty list with every filter on is the answer.
Then answer, and name each part with where you saw it applied. If the task names no filter, sort or condition, or you are stopping to ask the owner, answer now.`;

function textOf(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content.filter(b => b && b.type === 'text' && typeof b.text === 'string').map(b => b.text).join('\n');
}

// An owner's message: a user entry that carries text, not only tool results, and
// is not Claude Code's own meta/hook feedback.
function isOwnerPrompt(e) {
  if (!e || e.type !== 'user' || e.isMeta || !e.message) return false;
  const c = e.message.content;
  if (typeof c === 'string') return c.trim() !== '' && !c.includes(TAG);
  if (!Array.isArray(c)) return false;
  if (c.some(b => b && b.type === 'tool_result')) return false;
  const t = textOf(c);
  return t.trim() !== '' && !t.includes(TAG);
}

function browserCalls(entries) {
  let n = 0;
  for (const e of entries) {
    if (!e || e.type !== 'assistant' || !e.message || !Array.isArray(e.message.content)) continue;
    for (const b of e.message.content) {
      if (!b || b.type !== 'tool_use' || !b.input) continue;
      const cmd = typeof b.input.command === 'string' ? b.input.command : '';
      if (cmd && BROWSER_CALL.test(cmd)) n++;
    }
  }
  return n;
}

// Whatever shape a harness records the hook's feedback in (a meta user entry, an
// attachment, a system line), the tag is in it.
function alreadyFired(entries) {
  return entries.some(e => JSON.stringify(e).includes(TAG));
}

function stateFile(sessionId) {
  const dir = path.join(process.env.FIVEDIVE_BROWSER_APPLIED_STATE_DIR || os.tmpdir(), '5dive-browser-applied-check-' + process.getuid());
  return { dir, file: path.join(dir, String(sessionId).replace(/[^A-Za-z0-9._-]/g, '_')) };
}

// Returns the block object, or null to let the stop through.
function decide(input) {
  if (!input || typeof input !== 'object') return null;
  if (process.env.FIVEDIVE_BROWSER_APPLIED_CHECK === '0') return null;
  if (input.stop_hook_active === true) return null;          // guard 1: Claude Code's own
  const tp = input.transcript_path;
  if (!tp || !fs.existsSync(tp)) return null;
  const entries = [];
  for (const line of fs.readFileSync(tp, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    try { entries.push(JSON.parse(line)); } catch { /* a torn last line */ }
  }
  let start = -1;
  for (let i = entries.length - 1; i >= 0; i--) if (isOwnerPrompt(entries[i])) { start = i; break; }
  const turn = entries.slice(start + 1);
  const promptId = start >= 0 ? (entries[start].uuid || String(start)) : 'none';
  if (browserCalls(turn) === 0) return null;                  // no browser in this turn: never
  if (alreadyFired(turn)) return null;                        // guard 2: our tag is in the turn
  if (input.session_id) {                                     // guard 3: once per owner message
    const { dir, file } = stateFile(input.session_id);
    try { if (fs.readFileSync(file, 'utf8').trim() === promptId) return null; } catch { /* first time */ }
    try { fs.mkdirSync(dir, { recursive: true, mode: 0o700 }); fs.writeFileSync(file, promptId + '\n', { mode: 0o600 }); } catch { /* still block once */ }
  }
  return { decision: 'block', reason: REASON };
}

module.exports = { decide, BROWSER_CALL, TAG, REASON };

if (require.main === module) {
  let raw = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', d => { raw += d; });
  process.stdin.on('end', () => {
    try {
      const out = decide(JSON.parse(raw || '{}'));
      if (out) process.stdout.write(JSON.stringify(out) + '\n');
    } catch { /* fail open */ }
    process.exit(0);
  });
}
