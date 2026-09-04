#!/usr/bin/env node
// Render an agent run log as readable text, live.
//
//   tail -n +1 -f <runlog> | render-events.mjs
//
// Providers disagree about output. Command Code in headless mode buffers plain
// text until the run ends — which makes a working agent indistinguishable from a
// hung one — but streams line-delimited JSON events as they happen when asked
// for `--output-format json`. Codex writes plain text and streams it already.
//
// So this reads both: a line that parses as JSON is rendered as an event, and a
// line that does not is passed through untouched. That keeps one viewer working
// for every provider, including any future one that streams plain text.

import { createInterface } from 'node:readline';

const useColour = process.env.NO_COLOR === undefined;
const c = (code, s) => (useColour ? `[${code}m${s}[0m` : s);
const dim = (s) => c('2', s);
const bold = (s) => c('1', s);
const cyan = (s) => c('36', s);
const green = (s) => c('32', s);
const yellow = (s) => c('33', s);
const red = (s) => c('31', s);

// Thinking is the bulk of the stream and is useful when you are watching to
// understand a decision, noise when you are watching for progress.
const showThinking = process.env.AITEAM_SHOW_THINKING !== '0';
let summary = null;     // held until close: run_end and result each carry part of it

const out = process.stdout;
let column = 0;            // tracks whether we are mid-line, so headers break cleanly
const write = (s) => {
  out.write(s);
  const nl = s.lastIndexOf('\n');
  column = nl === -1 ? column + s.length : s.length - nl - 1;
};
const line = (s = '') => write((column > 0 ? '\n' : '') + s + '\n');

const truncate = (s, n) => {
  const flat = String(s).replace(/\s+/g, ' ').trim();
  return flat.length > n ? flat.slice(0, n - 1) + '…' : flat;
};

// Show the argument that identifies what a tool is acting on, rather than the
// whole input object — the useful part is almost always a path or a command.
const summariseInput = (input) => {
  if (!input || typeof input !== 'object') return '';
  for (const k of ['command', 'file_path', 'path', 'pattern', 'query', 'url', 'old_string']) {
    if (input[k]) return truncate(input[k], 100);
  }
  return truncate(JSON.stringify(input), 100);
};

const resultText = (result) => {
  if (typeof result === 'string') return result;
  if (Array.isArray(result)) {
    return result.map((r) => (typeof r === 'string' ? r : (r?.text ?? ''))).join(' ');
  }
  return result?.text ?? '';
};

// Claude Code emits its own stream-json shape rather than the flat event stream
// the rest of this renderer speaks: assistant/user messages carrying content
// blocks, plus a terminal `result`. Translating here keeps one renderer for both
// providers, so the follow window shows real work instead of raw JSON.
const fromClaudeCode = (obj) => {
  if (obj.type === 'system' && obj.subtype === 'init') {
    return [{ type: 'run_start' }];
  }
  if (obj.type === 'assistant' || obj.type === 'user') {
    const blocks = obj.message?.content;
    if (!Array.isArray(blocks)) return [];
    return blocks.flatMap((b) => {
      if (b.type === 'text' && b.text) return [{ type: 'text_delta', delta: b.text }];
      if (b.type === 'thinking' && b.thinking) return [{ type: 'thinking_delta', delta: b.thinking }];
      if (b.type === 'tool_use') return [{ type: 'tool_queued', toolName: b.name, input: b.input }];
      if (b.type === 'tool_result') {
        return [{ type: b.is_error ? 'tool_failed' : 'tool_completed', toolName: b.name, result: b.content }];
      }
      return [];
    });
  }
  if (obj.type === 'result') {
    return [{ type: 'result', stopReason: obj.subtype, durationMs: obj.duration_ms,
              usage: { total_tokens: (obj.usage?.input_tokens ?? 0) + (obj.usage?.output_tokens ?? 0) || undefined } }];
  }
  return [];                                     // rate_limit_event and friends
};

// Claude Code's lines carry no `event` envelope. Detected once, at the line
// boundary, so a translated event never re-enters translation.
const isClaudeCode = (obj) => obj.event === undefined
  && (obj.message !== undefined || obj.subtype !== undefined || obj.type === 'rate_limit_event');

const render = (obj) => {
  const e = obj.event ?? obj;
  switch (e.type) {
    case 'run_start':
      line(bold('▶ run started'));
      break;
    case 'turn_start':
      line(dim(`── turn ${e.turnNumber} ──`));
      break;
    case 'thinking_start':
      if (showThinking) write(dim('  thinking: '));
      break;
    case 'thinking_delta':
      if (showThinking) write(dim(e.delta ?? ''));
      break;
    case 'thinking_end':
      if (showThinking) line('');
      break;
    case 'text_delta':
      write(e.delta ?? '');
      break;
    case 'tool_queued':
      line(`${cyan('⚙')} ${bold(e.toolName ?? 'tool')} ${dim(summariseInput(e.input))}`);
      break;
    case 'tool_completed': {
      const text = truncate(resultText(e.result), 160);
      if (text) line(`  ${green('✓')} ${dim(text)}`);
      break;
    }
    case 'tool_failed':
    case 'tool_error':
      line(`  ${red('✗')} ${truncate(resultText(e.result ?? e.error), 200)}`);
      break;
    case 'error':
      line(red(`error: ${truncate(e.message ?? JSON.stringify(e), 300)}`));
      break;
    // run_end arrives first carrying a nested result, then a richer top-level
    // result with usage and duration. Both are held rather than printed, and the
    // best one is emitted once the stream closes — otherwise the informative
    // summary is followed by an emptier duplicate.
    case 'result':
    case 'run_end': {
      const src = e.result ?? e;
      const stop = src.stopReason ?? obj.stopReason;
      const ms = src.durationMs ?? obj.durationMs;
      const u = src.usage ?? obj.usage;
      summary = {
        stop: stop ?? summary?.stop,
        ms: ms ?? summary?.ms,
        tokens: u?.totalTokens ?? u?.total_tokens ?? summary?.tokens,
      };
      break;
    }
    // Transport-level bookkeeping. Rendering it adds noise without adding signal.
    case 'tool_running':
    case 'message_start': case 'message_update': case 'message_end':
    case 'model_request_start': case 'model_request_end': case 'model_trace':
    case 'turn_end':
      break;
    default:
      if (e.type) line(dim(`· ${e.type}`));
  }
};

const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on('line', (raw) => {
  const s = raw.trim();
  if (!s) return;
  if (s[0] !== '{') { line(raw); return; }      // plain-text provider, or our own notes
  try {
    const obj = JSON.parse(s);
    if (isClaudeCode(obj)) for (const ev of fromClaudeCode(obj)) render(ev);
    else render(obj);
  } catch {
    line(raw);                                   // a partially written line; show it as-is
  }
});
rl.on('close', () => {
  if (summary) {
    const bits = [];
    if (summary.stop) bits.push(`stop=${summary.stop}`);
    if (summary.ms) bits.push(`${Math.round(summary.ms / 1000)}s`);
    if (summary.tokens) bits.push(`${summary.tokens} tokens`);
    const text = `\u25a0 finished (${bits.join(', ')})`;
    // A stop reason other than a normal end of turn is the signal that a run was
    // truncated — a turn limit, a timeout — so it is coloured rather than buried.
    line(bold(summary.stop && summary.stop !== 'end_turn' ? yellow(text) : text));
  }
  if (column > 0) out.write('\n');
});
