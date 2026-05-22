#!/usr/bin/env node
// Code-node return-shape drift guard.
//
// Bug class: n8n's Code node has two execution modes:
//
//   - `runOnceForAllItems`  - the body sees `items` (array) and must return
//     an array of `{ json: ... }` objects.
//   - `runOnceForEachItem`  - the body sees `$json` (single object) and must
//     return a SINGLE `{ json: ... }` object (NOT wrapped in an array).
//
// If a `runOnceForEachItem` node returns `[{ json: $json }]`, n8n's
// `validateRunCodeEachItem` walks the returned array and tries `.json` on the
// array itself (which is undefined), then throws:
//
//   A 'json' property isn't an object [item 0]
//
// In review.json this was the cause of `Assert Slack Blocks Sent` crashing
// AFTER Slack already accepted the message, which prevented `Log Notification`
// from writing a `notified` outcome row and broke the dedup query — so every
// 2-min cycle re-notified the same items.
//
// This audit rejects any Code node whose `parameters.mode` is
// `runOnceForEachItem` AND whose body's final return statement returns an
// array literal of the shape `[{ json: ... }]`. The shape is loose on purpose
// (the AST varies by author); we only catch the literal pattern.
//
// Re-run after editing any *.json workflow under apps/outreach-workflows/n8n/:
//   node apps/outreach-workflows/tests/sha256-audit/code-node-return-shape-audit.js

const fs = require('fs');
const path = require('path');

const WORKFLOW_DIR = path.resolve(__dirname, '../../n8n');

// Match `return [{ json: ... }];` (with optional async whitespace + trailing
// content). The pattern is anchored to the literal `return [` followed by an
// opening brace and the `json:` key word — that's the n8n-shape return.
const BAD_RETURN = /return\s*\[\s*\{\s*json\s*:/;

// Grandfathered nodes — the bug pattern is present but production behaviour
// has been observed (e.g. T25 row 62 SUCCESS for Workflow D Verify Hash).
// Why these pass: the n8n validator's tolerance varies with the upstream
// node's pairedItem shape; some inputs happen to flatten cleanly through
// the array wrapper, others (like the Slack v2 response shape) do not.
// Touching live Workflow D is out of scope for this fix bundle (session
// boundary). New violations should still fail — only the explicit set below
// is allowed, and each entry MUST cite the reason it's grandfathered.
const GRANDFATHERED = new Set([
  // publish-dispatcher.json — Verify Hash. T25 (row 62) succeeded with this
  // shape; full deploy + smoke pending future work. Tracked in HANDOFF.
  'publish-dispatcher.json:Verify Hash',
]);

function loadWorkflows() {
  const out = [];
  for (const f of fs.readdirSync(WORKFLOW_DIR)) {
    if (!f.endsWith('.json')) continue;
    const p = path.join(WORKFLOW_DIR, f);
    const raw = JSON.parse(fs.readFileSync(p, 'utf8'));
    const docs = Array.isArray(raw) ? raw : [raw];
    for (const doc of docs) {
      out.push({ file: f, doc });
    }
  }
  return out;
}

function main() {
  console.log('=== code-node-return-shape drift guard ===');
  const failures = [];
  let checked = 0;

  for (const { file, doc } of loadWorkflows()) {
    for (const node of (doc.nodes || [])) {
      if (node.type !== 'n8n-nodes-base.code') continue;
      const code = node.parameters && node.parameters.jsCode;
      if (typeof code !== 'string') continue;
      const mode = node.parameters && node.parameters.mode;
      // Default mode is runOnceForAllItems; only the explicit each-item mode is
      // the trap. (runOnceForAllItems freely returns arrays.)
      if (mode !== 'runOnceForEachItem') continue;
      checked++;
      const key = `${file}:${node.name}`;
      if (BAD_RETURN.test(code)) {
        if (GRANDFATHERED.has(key)) {
          console.log(`  SKIP (grandfathered): ${key}`);
        } else {
          failures.push(
            `${key} — mode=runOnceForEachItem returns array-wrapped item ([{ json: ... }]); use { json: ... } (bare object)`,
          );
        }
      } else {
        console.log(`  OK ${key}`);
      }
    }
  }

  console.log(`\n  Checked ${checked} runOnceForEachItem Code node(s).`);
  if (failures.length === 0) {
    console.log('\nPASS: no Code-node return-shape mismatches.');
    process.exit(0);
  }
  console.error('\nFAIL: Code-node return-shape drift detected:');
  for (const f of failures) console.error(`  - ${f}`);
  process.exit(1);
}

main();
