#!/usr/bin/env node
// Webhook rawBody shape guard for n8n workflows.
//
// Bug class: any webhook whose downstream code verifies an HMAC signature
// MUST preserve the original request bytes. n8n's Webhook node only attaches
// the raw bytes under `item.binary.data` when `options.rawBody === true`;
// without that flag, the downstream Code node has only the parsed form/JSON
// fields and has to RE-ENCODE the body to reconstruct the signed string.
//
// In our case Slack signs the body using Go's `url.QueryEscape`, which
// disagrees with JS's `encodeURIComponent` on `( ) ' * ! ` and space — so any
// re-encoding path is silently wrong on the majority of real interactive
// payloads. We hit exactly that bug in production today.
//
// This audit asserts that every webhook node whose name matches an
// HMAC-bound pattern (currently "*Slack*Interactive*") has
// `options.rawBody === true`.
//
// Re-run after editing any workflow JSON that adds or modifies a webhook
// node:
//   node apps/outreach-workflows/tests/sha256-audit/webhook-rawbody-audit.js
//
// Exit code: 0 = all guarded webhooks have rawBody enabled, 1 = at least one
// offender (signature verification will reject otherwise-valid Slack traffic).

const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '../../../..');
const N8N_DIR = path.join(REPO, 'apps/outreach-workflows/n8n');

const WEBHOOK_TYPE = 'n8n-nodes-base.webhook';

// Webhook node-name patterns that REQUIRE options.rawBody === true.
// Add new patterns here when introducing other HMAC-signed callbacks.
const RAW_BODY_REQUIRED = [
  /Slack.*Interactive/i,
];

function listJsonFiles(dir) {
  return fs.readdirSync(dir)
    .filter(f => f.endsWith('.json'))
    .sort()
    .map(f => path.join(dir, f));
}

function inspectDoc(doc, file, findings, inspected) {
  for (const node of (doc.nodes || [])) {
    if (node.type !== WEBHOOK_TYPE) continue;
    const matchedPattern = RAW_BODY_REQUIRED.find(re => re.test(node.name));
    if (!matchedPattern) continue;
    const opts = (node.parameters && node.parameters.options) || {};
    inspected.push({
      file,
      node: node.name,
      pattern: matchedPattern.toString(),
      rawBody: opts.rawBody,
    });
    if (opts.rawBody !== true) {
      findings.push({
        file,
        node: node.name,
        pattern: matchedPattern.toString(),
        reason: `options.rawBody is ${JSON.stringify(opts.rawBody)} — must be literal true`,
      });
    }
  }
}

function main() {
  const files = listJsonFiles(N8N_DIR);
  const findings = [];
  const inspected = [];

  for (const filePath of files) {
    const raw = JSON.parse(fs.readFileSync(filePath, 'utf8'));
    const docs = Array.isArray(raw) ? raw : [raw];
    const rel = path.relative(REPO, filePath);
    for (const doc of docs) inspectDoc(doc, rel, findings, inspected);
  }

  console.log('=== webhook rawBody shape guard ===');
  console.log(`  scanned ${files.length} workflow file(s), ${inspected.length} guarded webhook node(s)\n`);

  const pad = (s, n) => (s + ' '.repeat(n)).slice(0, n);
  console.log('  ' + pad('file', 48) + pad('node', 32) + 'rawBody');
  console.log('  ' + '-'.repeat(48 + 32 + 16));
  for (const row of inspected) {
    console.log('  ' + pad(row.file, 48) + pad(row.node, 32) + String(row.rawBody));
  }

  if (findings.length === 0) {
    console.log(`\nOK: every webhook bound by an HMAC pattern has options.rawBody=true.`);
    process.exit(0);
  }

  console.error('\nFAIL: webhook(s) missing options.rawBody=true:');
  for (const f of findings) {
    console.error(`  ${f.file}::${f.node}  (pattern ${f.pattern})  -> ${f.reason}`);
  }
  console.error('\nSignature verification downstream of these webhooks will silently fail on');
  console.error('any payload containing characters where Go url.QueryEscape and JS');
  console.error('encodeURIComponent disagree (parens, quotes, asterisks, exclamation marks,');
  console.error('spaces, etc.). Set options.rawBody=true to preserve the original request');
  console.error('bytes under item.binary.data.');
  process.exit(1);
}

main();
