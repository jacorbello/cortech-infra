#!/usr/bin/env node
// Public self-loop URL drift guard for n8n workflow JSON.
//
// Bug class: an n8n HTTP Request node inside LXC 112 calls its own
// publicly-routed hostname (e.g. `https://n8n.corbello.io/...`). Public
// traffic exits the container, traverses NGINX/Traefik, hits IP allow-lists
// configured for human browsers, and fails — often silently from the
// scheduler's point of view, because the workflow throws a NodeApiError on a
// generic 4xx/5xx with no operator-visible context.
//
// The fix: workflows that need to invoke another n8n webhook should call the
// container's local listener directly (`http://127.0.0.1:5678/...`); the
// `httpHeaderAuth` credential applies the same Authorization header over
// plain HTTP, so webhook auth still works. The public hostname is reserved
// for traffic that genuinely originates outside the container.
//
// Re-run after editing any workflow JSON that adds or modifies an
// httpRequest node:
//   node apps/outreach-workflows/tests/sha256-audit/no-public-self-loop.js
//
// Exit code: 0 = no public self-loops, 1 = at least one offender.

const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '../../../..');
const N8N_DIR = path.join(REPO, 'apps/outreach-workflows/n8n');

// Substrings that indicate "this workflow is calling itself by its public
// hostname". `n8n.corbello.io` is the only one today; if the n8n public
// hostname ever changes, append the new value here.
const FORBIDDEN_HOST_SUBSTRINGS = ['n8n.corbello.io'];

const N8N_HTTP_TYPE = 'n8n-nodes-base.httpRequest';

function listJsonFiles(dir) {
  return fs.readdirSync(dir)
    .filter(f => f.endsWith('.json'))
    .sort()
    .map(f => path.join(dir, f));
}

function inspectDoc(doc, file, findings, inspected) {
  for (const node of (doc.nodes || [])) {
    if (node.type !== N8N_HTTP_TYPE) continue;
    const url = node.parameters && node.parameters.url;
    if (typeof url !== 'string') continue;
    inspected.push({ file, node: node.name, id: node.id, url });
    for (const forbidden of FORBIDDEN_HOST_SUBSTRINGS) {
      if (url.includes(forbidden)) {
        findings.push({ file, node: node.name, id: node.id, url, forbidden });
      }
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

  console.log('=== no-public-self-loop drift guard ===');
  console.log(`  scanned ${files.length} workflow file(s), ${inspected.length} httpRequest node(s)\n`);

  const pad = (s, n) => (s + ' '.repeat(n)).slice(0, n);
  console.log('  ' + pad('file', 48) + pad('node', 32) + 'url');
  console.log('  ' + '-'.repeat(48 + 32 + 40));
  for (const row of inspected) {
    console.log('  ' + pad(row.file, 48) + pad(row.node, 32) + row.url);
  }

  if (findings.length === 0) {
    console.log(`\nOK: no httpRequest node calls a forbidden self-loop host (${FORBIDDEN_HOST_SUBSTRINGS.join(', ')}).`);
    process.exit(0);
  }

  console.error('\nFAIL: public self-loop URL(s) detected. These nodes run INSIDE the n8n');
  console.error('container and should target http://127.0.0.1:5678/... instead.');
  for (const f of findings) {
    console.error(`  ${f.file}::${f.node}  matched '${f.forbidden}' in: ${f.url}`);
  }
  process.exit(1);
}

main();
