#!/usr/bin/env node
// Pulls a reviewer's final message out of an NDJSON run log and writes it as the
// verdict file.
//
// Codex enforced the verdict schema in the runner (--output-schema) and wrote the
// final message straight to a file (--output-last-message). Command Code offers
// neither, so the schema becomes a harness-side check rather than a runner-side
// guarantee: an off-schema verdict is caught by validate_schema and the run dies
// loudly, instead of being impossible to produce. Weaker, but never silent.
import { readFileSync, writeFileSync } from 'node:fs';

const [, , logPath, outPath] = process.argv;
if (!logPath || !outPath) {
  console.error('usage: extract-verdict.mjs <runlog> <out.json>');
  process.exit(2);
}

const texts = [];
for (const raw of readFileSync(logPath, 'utf8').split('\n')) {
  const s = raw.trim();
  if (!s || s[0] !== '{') continue;
  let o;
  try { o = JSON.parse(s); } catch { continue; }
  // Command Code's shapes: a terminal {type:"result", result:"..."} line, and
  // assistant text arriving as deltas or whole blocks along the way.
  if (typeof o.result === 'string') texts.push(o.result);
  else if (o.type === 'result' && typeof o.text === 'string') texts.push(o.text);
  else if (o.event?.type === 'text_delta' && typeof o.event.delta === 'string') texts.push(o.event.delta);
}

// Prefer the last standalone result; fall back to the concatenated stream.
let candidate = texts.length ? texts[texts.length - 1] : '';
if (!candidate.includes('{')) candidate = texts.join('');

// Models fence JSON even when told not to; take the outermost object either way.
const start = candidate.indexOf('{');
const end = candidate.lastIndexOf('}');
if (start === -1 || end <= start) {
  console.error('no JSON object found in the reviewer output');
  process.exit(1);
}
const json = candidate.slice(start, end + 1);
try {
  JSON.parse(json);                     // parse-check here so the error names this step
} catch (e) {
  console.error(`reviewer output was not parseable JSON: ${e.message}`);
  process.exit(1);
}
// Normalise key renames only — never values, never structure. A reviewer that
// returns a correct verdict under a differently spelled key has done the work;
// throwing that away costs a full review to gain nothing. Anything beyond a
// rename is left alone so validate_schema still rejects it.
const ALIASES = { acceptance_criteria: 'criteria', acceptanceCriteria: 'criteria',
                  inspected: 'independently_inspected', files_inspected: 'independently_inspected' };
const parsed = JSON.parse(json);
for (const [from, to] of Object.entries(ALIASES)) {
  if (parsed[from] !== undefined && parsed[to] === undefined) {
    parsed[to] = parsed[from];
    delete parsed[from];
    console.error(`extract-verdict: renamed "${from}" to "${to}" (key alias, content untouched)`);
  }
}
writeFileSync(outPath, `${JSON.stringify(parsed, null, 2)}\n`);
