#!/usr/bin/env node
// blocksUi shape drift guard for n8n Slack nodes.
//
// Bug class: n8n's Slack v2 node (typeVersion 2.x) reads `parameters.blocksUi`
// with `ensureType: 'object'`. That helper JSON.parses strings and accepts
// arrays as-is — but the downstream code at
//   n8n-nodes-base/Slack/V2/GenericFunctions.js:194
// reads `value.blocks` and spreads it into the request body. If the resolved
// value is a BARE ARRAY (e.g. `={{ JSON.stringify($json.slack_blocks) }}`,
// where `slack_blocks` is already a JS array), `value.blocks` is `undefined`
// and the array's numeric keys leak into the request as integer-keyed form
// parameters. Slack's chat.postMessage receives no `blocks` argument, so it
// renders only the `text` fallback as a single rich_text block — no buttons.
//
// The correct shape is an OBJECT that wraps the blocks array, e.g.
//   ={{ { blocks: $json.slack_blocks } }}
//
// This audit walks every workflow JSON in apps/outreach-workflows/n8n/, finds
// every `n8n-nodes-base.slack` node with `messageType: "block"`, and asserts
// that `blocksUi` contains the literal substring `blocks:` and does NOT match
// the broken `JSON.stringify($json.<id>)` pattern.
//
// Re-run after editing any workflow JSON that touches a Slack node:
//   node apps/outreach-workflows/tests/sha256-audit/blocksui-shape-audit.js
//
// Exit code: 0 = all Slack block-message nodes look sane, 1 = at least one
// offender (workflow will render fallback-text-only in Slack at runtime).

const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '../../../..');
const N8N_DIR = path.join(REPO, 'apps/outreach-workflows/n8n');

const SLACK_TYPE = 'n8n-nodes-base.slack';

// Detects the broken pattern: `JSON.stringify($json.<identifier>)` as a whole
// expression body inside an n8n expression `={{ ... }}`. Whitespace is
// permitted around the JSON.stringify call.
const BROKEN_PATTERN = /JSON\.stringify\(\s*\$json\.[a-zA-Z_][a-zA-Z0-9_]*\s*\)/;

function listJsonFiles(dir) {
  return fs.readdirSync(dir)
    .filter(f => f.endsWith('.json'))
    .sort()
    .map(f => path.join(dir, f));
}

function inspectDoc(doc, file, findings, inspected) {
  for (const node of (doc.nodes || [])) {
    if (node.type !== SLACK_TYPE) continue;
    const params = node.parameters || {};
    if (params.messageType !== 'block') continue;
    const blocksUi = params.blocksUi;
    inspected.push({ file, node: node.name, id: node.id, blocksUi });

    if (typeof blocksUi !== 'string') {
      findings.push({
        file, node: node.name, id: node.id, blocksUi,
        reason: `blocksUi is not a string (got ${blocksUi === null ? 'null' : typeof blocksUi})`,
      });
      continue;
    }

    if (!blocksUi.includes('blocks:')) {
      findings.push({
        file, node: node.name, id: node.id, blocksUi,
        reason: "blocksUi missing literal 'blocks:' — expression must resolve to an object of shape { blocks: <array> }",
      });
      continue;
    }

    if (BROKEN_PATTERN.test(blocksUi)) {
      findings.push({
        file, node: node.name, id: node.id, blocksUi,
        reason: 'blocksUi matches broken JSON.stringify($json.<id>) pattern — Slack v2 node will silently drop blocks',
      });
      continue;
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
    for (const doc of docs) {
      inspectDoc(doc, rel, findings, inspected);
    }
  }

  console.log('=== blocksUi shape drift guard ===');
  console.log(`  scanned ${files.length} workflow file(s), ${inspected.length} Slack block-message node(s)\n`);

  const pad = (s, n) => (s + ' '.repeat(n)).slice(0, n);
  console.log('  ' + pad('file', 48) + pad('node', 26) + 'blocksUi');
  console.log('  ' + '-'.repeat(48 + 26 + 40));
  for (const row of inspected) {
    console.log('  ' + pad(row.file, 48) + pad(row.node, 26) + row.blocksUi);
  }

  if (findings.length === 0) {
    console.log(`\nOK: every Slack block-message node has an object-shape blocksUi expression.`);
    process.exit(0);
  }

  console.error('\nFAIL: malformed blocksUi expression(s) detected. Slack v2 node expects the');
  console.error('expression to resolve to an OBJECT of shape { blocks: <array> }; a bare array');
  console.error('or JSON-stringified array makes the request body lose `blocks`, leaving Slack');
  console.error('to render only the text fallback as a single rich_text block.');
  for (const f of findings) {
    console.error(`  ${f.file}::${f.node}`);
    console.error(`    blocksUi: ${f.blocksUi}`);
    console.error(`    reason:   ${f.reason}`);
  }
  process.exit(1);
}

main();
