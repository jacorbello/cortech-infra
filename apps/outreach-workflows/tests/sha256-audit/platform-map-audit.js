#!/usr/bin/env node
// PLATFORM_MAP drift guard for review.json.
//
// Two n8n Code nodes encode the Slack quick-approve platform map in
// different shapes:
//   - 'Build Slack Blocks' (cc000010-...) — array of {key, platform, integration, label}
//   - 'Build Slack Approval' (t29w0006-...) — object {<key>: {platform, integration, label}}
//
// The runbook (docs/runbooks/postiz-channel-onboarding.md, "Slack quick-approve
// registration") tells the operator to add a row in BOTH nodes. Today nothing
// catches drift if they forget one — the result is either a button that goes
// to the wrong integration, or a Slack approval that throws 'Unknown
// platform_key'.
//
// This script parses both maps, normalizes them, and asserts:
//   - identical key sets
//   - identical (platform, integration, label) for each key
//   - every platform is in the schema CHECK set
//   - every integration looks like a Postiz integration id (cmpe + 20+ alnum)
//
// Re-run after editing review.json:
//   node apps/outreach-workflows/tests/sha256-audit/platform-map-audit.js
//
// Exit code: 0 = all pass, 1 = any failure.

const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '../../../..');
const REVIEW_JSON = path.join(REPO, 'apps/outreach-workflows/n8n/review.json');

const NODE_BLOCKS = {
  id: 'cc000010-0010-0010-0010-000000000010',
  name: 'Build Slack Blocks',
  shape: 'array',
};
const NODE_APPROVAL = {
  id: 't29w0006-0006-0006-0006-000000000006',
  name: 'Build Slack Approval',
  shape: 'object',
};

const VALID_PLATFORMS = new Set(['bluesky', 'mastodon', 'linkedin', 'x', 'reddit']);
const INTEGRATION_RE = /^cmpe[a-z0-9]{20,}$/;

function loadNodeJsCode(file, id) {
  const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
  const docs = Array.isArray(raw) ? raw : [raw];
  for (const doc of docs) {
    for (const node of (doc.nodes || [])) {
      if (node.id === id) return { name: node.name, jsCode: node.parameters.jsCode || '' };
    }
  }
  throw new Error(`Node id '${id}' not found in ${file}`);
}

// Extract the value of `const PLATFORM_MAP = <expr>;` — track bracket depth so
// nested object literals don't fool us. Works for both array and object shapes.
function extractPlatformMapLiteral(code) {
  const anchor = code.indexOf('PLATFORM_MAP');
  if (anchor < 0) throw new Error('PLATFORM_MAP identifier not found');
  const eq = code.indexOf('=', anchor);
  if (eq < 0) throw new Error('No assignment to PLATFORM_MAP');
  // Find the first '[' or '{' after '=' to start the literal.
  let start = -1;
  let openCh = '';
  for (let i = eq + 1; i < code.length; i++) {
    const ch = code[i];
    if (ch === '[' || ch === '{') { start = i; openCh = ch; break; }
    if (!/\s/.test(ch)) throw new Error(`Unexpected char '${ch}' before PLATFORM_MAP literal`);
  }
  if (start < 0) throw new Error('Could not locate start of PLATFORM_MAP literal');
  const closeCh = openCh === '[' ? ']' : '}';
  let depth = 0;
  let inStr = false;
  let strCh = '';
  for (let j = start; j < code.length; j++) {
    const ch = code[j];
    const prev = j > 0 ? code[j - 1] : '';
    if (inStr) {
      if (ch === strCh && prev !== '\\') inStr = false;
      continue;
    }
    if (ch === '"' || ch === "'" || ch === '`') { inStr = true; strCh = ch; continue; }
    if (ch === openCh) depth++;
    else if (ch === closeCh) {
      depth--;
      if (depth === 0) return code.slice(start, j + 1);
    }
  }
  throw new Error('Unbalanced PLATFORM_MAP literal');
}

function evalLiteral(src) {
  // Evaluate as a JS expression in an isolated sandbox-ish wrapper. The
  // literals here are plain data — no function references, no globals — so a
  // simple Function constructor is sufficient.
  // eslint-disable-next-line no-new-func
  return new Function(`return (${src});`)();
}

function normalize(value, shape, nodeName) {
  if (shape === 'array') {
    if (!Array.isArray(value)) throw new Error(`${nodeName}: expected array, got ${typeof value}`);
    const out = {};
    for (const row of value) {
      if (!row || typeof row !== 'object') throw new Error(`${nodeName}: array element not an object`);
      const { key, platform, integration, label } = row;
      if (!key) throw new Error(`${nodeName}: array element missing 'key'`);
      if (out[key]) throw new Error(`${nodeName}: duplicate key '${key}'`);
      out[key] = { platform, integration, label };
    }
    return out;
  }
  if (shape === 'object') {
    if (!value || typeof value !== 'object' || Array.isArray(value)) {
      throw new Error(`${nodeName}: expected object, got ${Array.isArray(value) ? 'array' : typeof value}`);
    }
    const out = {};
    for (const [key, entry] of Object.entries(value)) {
      if (!entry || typeof entry !== 'object') throw new Error(`${nodeName}: entry for '${key}' not an object`);
      const { platform, integration, label } = entry;
      out[key] = { platform, integration, label };
    }
    return out;
  }
  throw new Error(`Unknown shape '${shape}'`);
}

function fail(msg) {
  console.error(`FAIL: ${msg}`);
  process.exit(1);
}

function main() {
  const blocksNode = loadNodeJsCode(REVIEW_JSON, NODE_BLOCKS.id);
  const approvalNode = loadNodeJsCode(REVIEW_JSON, NODE_APPROVAL.id);

  const blocksSrc = extractPlatformMapLiteral(blocksNode.jsCode);
  const approvalSrc = extractPlatformMapLiteral(approvalNode.jsCode);

  let blocksValue;
  let approvalValue;
  try { blocksValue = evalLiteral(blocksSrc); }
  catch (e) { fail(`Could not parse PLATFORM_MAP in '${NODE_BLOCKS.name}': ${e.message}`); }
  try { approvalValue = evalLiteral(approvalSrc); }
  catch (e) { fail(`Could not parse PLATFORM_MAP in '${NODE_APPROVAL.name}': ${e.message}`); }

  const blocksMap = normalize(blocksValue, NODE_BLOCKS.shape, NODE_BLOCKS.name);
  const approvalMap = normalize(approvalValue, NODE_APPROVAL.shape, NODE_APPROVAL.name);

  const blocksKeys = new Set(Object.keys(blocksMap));
  const approvalKeys = new Set(Object.keys(approvalMap));

  // Key-set equality
  const onlyInBlocks = [...blocksKeys].filter(k => !approvalKeys.has(k));
  const onlyInApproval = [...approvalKeys].filter(k => !blocksKeys.has(k));
  if (onlyInBlocks.length || onlyInApproval.length) {
    if (onlyInBlocks.length) console.error(`  only in '${NODE_BLOCKS.name}': ${onlyInBlocks.join(', ')}`);
    if (onlyInApproval.length) console.error(`  only in '${NODE_APPROVAL.name}': ${onlyInApproval.join(', ')}`);
    fail('PLATFORM_MAP key sets disagree between the two nodes.');
  }

  // Per-key field agreement
  const mismatches = [];
  for (const key of blocksKeys) {
    const a = blocksMap[key];
    const b = approvalMap[key];
    for (const field of ['platform', 'integration', 'label']) {
      if (a[field] !== b[field]) {
        mismatches.push({ key, field, blocks: a[field], approval: b[field] });
      }
    }
  }
  if (mismatches.length) {
    for (const m of mismatches) {
      console.error(`  ${m.key}.${m.field}: blocks=${JSON.stringify(m.blocks)} approval=${JSON.stringify(m.approval)}`);
    }
    fail(`${mismatches.length} field mismatch(es) between the two PLATFORM_MAPs.`);
  }

  // Schema invariants on the canonical (now-equal) map
  const platformViolations = [];
  const integrationViolations = [];
  for (const [key, entry] of Object.entries(blocksMap)) {
    if (!VALID_PLATFORMS.has(entry.platform)) {
      platformViolations.push({ key, platform: entry.platform });
    }
    if (typeof entry.integration !== 'string' || !INTEGRATION_RE.test(entry.integration)) {
      integrationViolations.push({ key, integration: entry.integration });
    }
  }
  if (platformViolations.length) {
    for (const v of platformViolations) console.error(`  ${v.key}: platform '${v.platform}' not in {${[...VALID_PLATFORMS].join(', ')}}`);
    fail(`${platformViolations.length} platform value(s) violate schema CHECK constraint.`);
  }
  if (integrationViolations.length) {
    for (const v of integrationViolations) console.error(`  ${v.key}: integration '${v.integration}' does not match ${INTEGRATION_RE}`);
    fail(`${integrationViolations.length} integration id(s) malformed.`);
  }

  // Success summary
  console.log('=== PLATFORM_MAP drift check ===');
  console.log(`  '${NODE_BLOCKS.name}' (array shape): ${blocksKeys.size} entries`);
  console.log(`  '${NODE_APPROVAL.name}' (object shape): ${approvalKeys.size} entries`);
  console.log('');
  const pad = (s, n) => (s + ' '.repeat(n)).slice(0, n);
  console.log('  ' + pad('key', 20) + pad('platform', 12) + pad('integration', 32) + 'label');
  console.log('  ' + '-'.repeat(20 + 12 + 32 + 20));
  for (const [key, e] of Object.entries(blocksMap)) {
    console.log('  ' + pad(key, 20) + pad(e.platform, 12) + pad(e.integration, 32) + e.label);
  }
  console.log(`\nOK: PLATFORM_MAP in sync across both nodes (${blocksKeys.size} entries, all valid).`);
  process.exit(0);
}

main();
