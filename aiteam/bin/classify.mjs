#!/usr/bin/env node
// Computes a task's risk tier from the paths it declares and the tags it carries.
//
// Risk is computed rather than chosen so that nobody can downgrade the review of
// their own work. A task may declare a HIGHER tier than computed (caution is
// always allowed); declaring a lower one is rejected at creation.
//
// Usage: classify.mjs <policy.json> <task.json>
// Prints: <tier> <review_required> <lens,lens>

import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";

const [, , policyPath, taskPath] = process.argv;
const policy = JSON.parse(readFileSync(policyPath, "utf8"));
const task = JSON.parse(readFileSync(taskPath, "utf8"));

// Project-specific risk concepts live in the project layer, not in the portable
// policy. Merging them here is what lets "scoring" or "timer" be high-risk in one
// product without the generic harness carrying that assumption to the next.
const overridePath = join(dirname(dirname(dirname(policyPath))), ".aiteam", "risk-overrides.json");
if (existsSync(overridePath)) {
  const extra = JSON.parse(readFileSync(overridePath, "utf8"));
  for (const [tier, spec] of Object.entries(extra.risk_tiers ?? {})) {
    if (!policy.risk_tiers[tier]) continue;
    for (const field of ["tags", "path_patterns"]) {
      if (spec[field]) {
        policy.risk_tiers[tier][field] = [
          ...(policy.risk_tiers[tier][field] ?? []),
          ...spec[field],
        ];
      }
    }
  }
}

// Glob → RegExp for the subset used here: ** spans separators, * does not.
const globToRe = (glob) => {
  let re = "";
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === "*") {
      if (glob[i + 1] === "*") { re += ".*"; i++; if (glob[i + 1] === "/") i++; }
      else re += "[^/]*";
    } else if (c === "?") re += "[^/]";
    else re += c.replace(/[.+^${}()|[\]\\]/g, "\\$&");
  }
  return new RegExp(`^${re}$`);
};

const paths = [...(task.files?.expected ?? []), ...(task.files?.forbidden ?? [])];
const tags = [
  ...(task.lens ?? []),
  ...(task.risk_reason ? [task.risk_reason] : []),
  ...(task.tags ?? []),
  // The title and objective are scanned too: a task about tokens is high-risk
  // whether or not whoever wrote it remembered to tag it.
  ...`${task.title ?? ""} ${task.objective ?? ""}`.toLowerCase().split(/[^a-z-]+/),
];

const order = ["low", "medium", "high"];
let computed = null;

for (const tier of order) {
  const spec = policy.risk_tiers[tier];
  if (!spec) continue;
  const pathHit = (spec.path_patterns ?? []).some((g) => {
    const re = globToRe(g);
    return paths.some((p) => re.test(p));
  });
  const tagHit = (spec.tags ?? []).some((t) => tags.includes(t));
  if (pathHit || tagHit) computed = tier; // later (higher) tiers overwrite earlier
}

if (!computed) computed = policy.risk_resolution?.default_when_unmatched ?? "medium";

const spec = policy.risk_tiers[computed];
process.stdout.write(
  `${computed} ${spec.review_required ? "true" : "false"} ${(spec.lenses ?? []).join(",")}\n`
);
