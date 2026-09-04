#!/usr/bin/env node
// Reads a verification log and reports how many tests actually ran.
//
//   testcount.mjs <verify.log>
//   prints: "passed <n>" | "zero" | "unknown"
//
// This replaced a loose regex that sniffed the log for the word "zero"-ish
// patterns. That regex matched the "0 test" inside npm's own banner line
// (`> project@0.1.0 test`) and discarded two correct implementations. The lesson
// is in the design, not the pattern: identify the runner's summary line and read
// its number, rather than pattern-matching arbitrary text that happens to
// contain digits.
//
// "unknown" is deliberately distinct from "zero". An unrecognised runner must
// not be treated as cheating, and must not be treated as proof either — the
// caller warns and moves on.

import { readFileSync } from "node:fs";

const path = process.argv[2];
if (!path) {
  console.error("usage: testcount.mjs <verify.log>");
  process.exit(2);
}

const log = readFileSync(path, "utf8");

// Each entry: a summary line only the runner emits, and how to read its count.
// Anchored to the summary label so version strings and file paths cannot match.
const RUNNERS = [
  // vitest:  "      Tests  7 passed (7)"   /  "Tests  2 failed | 5 passed (7)"
  { name: "vitest", re: /^\s*Tests\s+(?:\d+\s+failed\s*\|\s*)?(\d+)\s+passed/gm },
  // vitest with nothing to run
  { name: "vitest-empty", re: /^\s*No test files found/gm, zero: true },
  // node --test:  "ℹ pass 6"
  { name: "node", re: /^\s*(?:ℹ|#)\s*pass\s+(\d+)\s*$/gm },
  // jest:  "Tests:       7 passed, 7 total"
  { name: "jest", re: /^\s*Tests:\s+(?:\d+\s+failed,\s*)?(\d+)\s+passed/gm },
  // pytest:  "===== 7 passed in 0.12s ====="
  { name: "pytest", re: /^=+\s*(\d+)\s+passed/gm },
  // go test:  "ok   package  0.01s"  — counts packages, not tests, but non-zero
  { name: "go", re: /^ok\s+\S+\s+[\d.]+s/gm, countMatches: true },
];

let best = null;
let sawExplicitZero = false;

for (const runner of RUNNERS) {
  const matches = [...log.matchAll(runner.re)];
  if (matches.length === 0) continue;

  if (runner.zero) {
    sawExplicitZero = true;
    continue;
  }

  const n = runner.countMatches
    ? matches.length
    : Math.max(...matches.map((m) => Number(m[1])));

  if (Number.isFinite(n) && (best === null || n > best)) best = n;
}

if (best !== null && best > 0) {
  console.log(`passed ${best}`);
} else if (best === 0 || sawExplicitZero) {
  console.log("zero");
} else {
  console.log("unknown");
}
