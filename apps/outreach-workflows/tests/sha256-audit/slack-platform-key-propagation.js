#!/usr/bin/env node
// Slack platform_key propagation drift guard.
//
// Bug class: Verify Slack Signature parses the action_id into
// `verb` + `platform_key` + `outreach_item_id`. The downstream chain is:
//
//   Webhook Slack Interactive
//     -> Verify Slack Signature              (Code, emits platform_key)
//     -> Actionable Verb?                    (IF)
//     -> Look Up Draft                       (Postgres — REPLACES $json with the
//                                             draft row, dropping upstream fields)
//     -> Check Draft + Route                 (Code — RE-EMITS a specific shape;
//                                             MUST forward platform_key from sig)
//     -> Route Decision                      (Switch)
//     -> Build Slack Approval                (Code — reads d.platform_key,
//                                             throws if PLATFORM_MAP[key] is undef)
//
// If `Check Draft + Route` doesn't explicitly forward `platform_key`, the
// Postgres node's $json-replacement silently drops it. Build Slack Approval
// then sees d.platform_key === undefined and throws on the first real approve
// click. Reject clicks don't trigger this because Build Slack Approval skips
// the PLATFORM_MAP lookup entirely on `decision === 'rejected'`.
//
// This audit pins two invariants:
//   1. `Check Draft + Route` jsCode literally contains the string
//      `platform_key: sig.platform_key` (or `'platform_key': sig.platform_key`),
//      i.e. forwards it from the Verify Slack Signature reference.
//   2. `Build Slack Approval` jsCode references `d.platform_key` (or
//      `$input.item.json.platform_key`), confirming it's still reading the
//      field that Check Draft + Route forwards.
//
// Re-run after editing review.json:
//   node apps/outreach-workflows/tests/sha256-audit/slack-platform-key-propagation.js
//
// Exit code: 0 = invariants hold, 1 = drift.

const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '../../../..');
const REVIEW_PATH = path.join(REPO, 'apps/outreach-workflows/n8n/review.json');

function loadNodeCode(nodeName) {
  const raw = JSON.parse(fs.readFileSync(REVIEW_PATH, 'utf8'));
  const docs = Array.isArray(raw) ? raw : [raw];
  for (const doc of docs) {
    for (const node of (doc.nodes || [])) {
      if (node.name === nodeName && node.type === 'n8n-nodes-base.code') {
        const code = node.parameters && node.parameters.jsCode;
        if (typeof code !== 'string') {
          throw new Error(`'${nodeName}' Code node has no jsCode parameter`);
        }
        return code;
      }
    }
  }
  throw new Error(`'${nodeName}' Code node not found in review.json`);
}

function main() {
  console.log('=== slack-platform-key-propagation drift guard ===');
  const failures = [];

  const checkDraftRoute = loadNodeCode('Check Draft + Route');
  // Match `platform_key: sig.platform_key` or quoted-key form
  const FORWARD_PATTERN = /['"]?platform_key['"]?\s*:\s*sig\.platform_key/;
  if (!FORWARD_PATTERN.test(checkDraftRoute)) {
    failures.push(
      "'Check Draft + Route' jsCode does NOT forward platform_key from sig — " +
      "Build Slack Approval will throw on the first real approve click. Add " +
      "`platform_key: sig.platform_key,` to the returned object.",
    );
  } else {
    console.log("  OK: 'Check Draft + Route' forwards platform_key from sig");
  }

  const buildSlackApproval = loadNodeCode('Build Slack Approval');
  // Match `d.platform_key`, `$json.platform_key`, or `$input.item.json.platform_key`
  const READ_PATTERN = /(?:\bd\.platform_key\b|\$json\.platform_key\b|\$input\.item\.json\.platform_key\b)/;
  if (!READ_PATTERN.test(buildSlackApproval)) {
    failures.push(
      "'Build Slack Approval' jsCode no longer reads platform_key from the " +
      "incoming item — the propagation chain has changed. Re-audit the flow.",
    );
  } else {
    console.log("  OK: 'Build Slack Approval' reads platform_key from incoming item");
  }

  if (failures.length === 0) {
    console.log('\nPASS: Slack platform_key propagation chain intact.');
    process.exit(0);
  }
  console.error('\nFAIL: Slack platform_key propagation drift detected:');
  for (const f of failures) console.error(`  - ${f}`);
  process.exit(1);
}

main();
