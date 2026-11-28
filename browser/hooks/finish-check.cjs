#!/usr/bin/env node
'use strict';
// DIVE-9506: the nightly browser bench (2026-11-28, browser 1.97.7) lost 14 of 20
// tasks to the agent, not the site: 9 never applied, or never showed, a sort or filter
// the task named ("cheapest first", "nationwide", "Steam Deck reviews"), and 5 ended
// without the page or the answer showing the value asked for. The skill already says
// "check every part before done" (DIVE-7637, DIVE-8601) and the misses stayed: a line
// the agent reads at the start does not run at the end. This hook runs at the end.
//
// When the agent is about to stop a turn in which it drove a page with 5dive browser,
// it is sent back ONCE with the job's own words and a three-point check. A turn with no
// page verb, a second stop (stop_hook_active), or FIVEDIVE_BROWSER_FINISH_CHECK=0 stops
// as before. No network; it reads the session transcript's tail only.

const fs = require('fs');

// The verbs that load or change a page. status/auth/serve/help and the rest do not count.
const PAGE_VERB = /(^|[\s;&|(`])5dive\s+browser\s+(snapshot|act|read|links|shot|tree|download|replay)\b/;
const TAIL_CAP = 32 * 1024 * 1024; // never read more than the last 32 MB of a transcript
const CHUNK = 1024 * 1024;
const JOB_MAX = 700;

function text(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content.filter((b) => b && b.type === 'text' && typeof b.text === 'string').map((b) => b.text).join('\n');
}

// A message the person (or the bench's task) typed: not a tool result, not a skill's
// injected text, not a local slash-command echo, not a compaction summary.
function isPrompt(e) {
  if (!e || e.type !== 'user' || e.isMeta || e.isCompactSummary || e.isVisibleInTranscriptOnly) return false;
  const c = e.message && e.message.content;
  if (Array.isArray(c) && c.some((b) => b && b.type === 'tool_result')) return false;
  const t = text(c).trim();
  if (!t) return false;
  if (/^<(local-command-|command-name>|command-message>)/.test(t)) return false;
  if (/^Stop hook feedback:/.test(t)) return false; // our own reason, as some versions record it
  return true;
}

function pageVerbs(e) {
  if (!e || e.type !== 'assistant') return 0;
  const c = e.message && e.message.content;
  if (!Array.isArray(c)) return 0;
  let n = 0;
  for (const b of c) {
    if (b && b.type === 'tool_use' && b.name === 'Bash' && PAGE_VERB.test(String((b.input && b.input.command) || ''))) n++;
  }
  return n;
}

// Walk the transcript from its end back to the turn's prompt. Returns
// { verbs, job } — the page verbs run since the prompt, and the prompt's text.
function scan(file) {
  let fd;
  try { fd = fs.openSync(file, 'r'); } catch { return { verbs: 0, job: '' }; }
  try {
    const size = fs.fstatSync(fd).size;
    let pos = size, carry = '', read = 0, verbs = 0;
    while (pos > 0 && read < TAIL_CAP) {
      const len = Math.min(CHUNK, pos);
      pos -= len; read += len;
      const buf = Buffer.alloc(len);
      fs.readSync(fd, buf, 0, len, pos);
      const lines = (buf.toString('utf8') + carry).split('\n');
      carry = pos > 0 ? lines.shift() : '';
      for (let i = lines.length - 1; i >= 0; i--) {
        if (!lines[i]) continue;
        let e; try { e = JSON.parse(lines[i]); } catch { continue; }
        if (isPrompt(e)) return { verbs, job: text(e.message.content).trim() };
        verbs += pageVerbs(e);
      }
    }
    if (carry) { try { const e = JSON.parse(carry); if (isPrompt(e)) return { verbs, job: text(e.message.content).trim() }; verbs += pageVerbs(e); } catch {} }
    return { verbs, job: '' };
  } finally { fs.closeSync(fd); }
}

function quote(job) {
  const one = job.replace(/\s+/g, ' ').trim();
  return one.length > JOB_MAX ? one.slice(0, JOB_MAX - 1) + '…' : one;
}

function reason(job) {
  const lead = job ? `The job was: "${quote(job)}"\n\n` : '';
  return 'Finish check (5dive browser), once before you stop.\n\n' + lead +
    '1. List every condition the job names: each sort, filter, range, place, date, count, and the value to report.\n' +
    '2. For each sort or filter: is it set with the site\'s own control (the sort menu, the filter panel), and does the page show it NOW (the sort label, the filter chip, the URL)? ' +
    'If not, set it now. Then run one `5dive browser snapshot` of the page that shows it applied with the result, so the proof is on screen.\n' +
    '3. End with the answer: the exact value the job asked for (the price, the name, the count). If a condition cannot be met, say which one and why. Never end without it.\n\n' +
    'Everything already set, shown and answered? Then stop with your answer as it is. Do not send a message you already sent again.';
}

// Returns the Stop hook output object, or null to let the agent stop.
function check(input, env) {
  if (!input || typeof input !== 'object') return null;
  if (input.stop_hook_active) return null;
  const off = String((env || {}).FIVEDIVE_BROWSER_FINISH_CHECK || '').toLowerCase();
  if (off === '0' || off === 'off' || off === 'false' || off === 'no') return null;
  if (!input.transcript_path) return null;
  const { verbs, job } = scan(String(input.transcript_path));
  if (!verbs) return null;
  return { decision: 'block', reason: reason(job) };
}

module.exports = { check, scan, reason, isPrompt, PAGE_VERB };

if (require.main === module) {
  let buf = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (c) => { buf += c; });
  process.stdin.on('end', () => {
    let out = null;
    try { out = check(JSON.parse(buf), process.env); } catch { out = null; }
    if (out) process.stdout.write(JSON.stringify(out));
    process.exit(0);
  });
}
