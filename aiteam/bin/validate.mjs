#!/usr/bin/env node
// Minimal JSON Schema validator covering the draft-07 subset the harness uses:
// type, enum, pattern, minLength, minItems, required, properties, items,
// additionalProperties. Written dependency-free on purpose — the harness must
// run in a fresh clone before anyone has installed anything.
//
// Usage: validate.mjs <schema.json> <instance.json>   (exit 0 = valid)

import { readFileSync } from "node:fs";

const [, , schemaPath, instancePath] = process.argv;
if (!schemaPath || !instancePath) {
  console.error("usage: validate.mjs <schema.json> <instance.json>");
  process.exit(2);
}

const read = (p) => {
  try {
    return JSON.parse(readFileSync(p, "utf8"));
  } catch (e) {
    console.error(`cannot parse ${p}: ${e.message}`);
    process.exit(2);
  }
};

const schema = read(schemaPath);
const instance = read(instancePath);
const errors = [];

const typeOf = (v) =>
  v === null ? "null" : Array.isArray(v) ? "array" : typeof v === "number" ? (Number.isInteger(v) ? "integer" : "number") : typeof v;

function check(value, sch, path) {
  if (!sch || typeof sch !== "object") return;

  if (sch.type) {
    const allowed = Array.isArray(sch.type) ? sch.type : [sch.type];
    const actual = typeOf(value);
    // An integer satisfies a "number" constraint; nothing else is coerced.
    const matches = allowed.includes(actual) || (actual === "integer" && allowed.includes("number"));
    if (!matches) {
      errors.push(`${path}: expected ${allowed.join("|")}, got ${actual}`);
      return; // further checks would be noise once the type is wrong
    }
  }

  if (sch.enum && !sch.enum.includes(value)) {
    errors.push(`${path}: ${JSON.stringify(value)} is not one of ${sch.enum.join(", ")}`);
  }

  if (typeof value === "string") {
    if (sch.minLength !== undefined && value.length < sch.minLength) {
      errors.push(`${path}: needs at least ${sch.minLength} characters, has ${value.length}`);
    }
    if (sch.pattern && !new RegExp(sch.pattern).test(value)) {
      errors.push(`${path}: ${JSON.stringify(value)} does not match ${sch.pattern}`);
    }
  }

  if (typeof value === "number") {
    if (sch.minimum !== undefined && value < sch.minimum) {
      errors.push(`${path}: must be >= ${sch.minimum}`);
    }
  }

  if (Array.isArray(value)) {
    if (sch.minItems !== undefined && value.length < sch.minItems) {
      errors.push(`${path}: needs at least ${sch.minItems} item(s), has ${value.length}`);
    }
    if (sch.items) value.forEach((v, i) => check(v, sch.items, `${path}[${i}]`));
  }

  if (value && typeof value === "object" && !Array.isArray(value)) {
    for (const key of sch.required || []) {
      if (!(key in value)) errors.push(`${path}: missing required property "${key}"`);
    }
    for (const [key, sub] of Object.entries(sch.properties || {})) {
      if (key in value) check(value[key], sub, path === "" ? key : `${path}.${key}`);
    }
    if (sch.additionalProperties === false) {
      const known = new Set(Object.keys(sch.properties || {}));
      for (const key of Object.keys(value)) {
        // $-prefixed keys are treated as annotations, so configs can carry comments.
        if (!known.has(key) && !key.startsWith("$")) {
          errors.push(`${path}: unexpected property "${key}"`);
        }
      }
    }
  }
}

check(instance, schema, "");

if (errors.length) {
  console.error(`${instancePath} failed validation against ${schemaPath}:`);
  for (const e of errors) console.error(`  - ${e}`);
  process.exit(1);
}
process.exit(0);
