#!/usr/bin/env node
// Hash-payload concatenation-order drift guard.
//
// Three n8n Code nodes compute the same approval content hash:
//   - review.json :: 'Build Approval'        (form path — t28w0002-...)
//   - review.json :: 'Build Slack Approval'  (Slack quick-approve — t29w0006-...)
//   - publish-dispatcher.json :: 'Verify Hash' (Workflow D — pd0000a4-0001-...)
//
// The canonical concatenation is `draft_text + destination + postType + platform`.
// If ANY of those nodes reorders the fields, publish_jobs hash verification
// fails at dispatch time — workflow D throws, the job flips to `failed`, and
// the operator finds out only via Uptime-Kuma. This test pins the order by
// running each node's jsCode in a sandbox against a fixed fixture and
// asserting every node produces the same precomputed reference hash.
//
// Re-run after editing any of the three nodes' jsCode:
//   node apps/outreach-workflows/tests/sha256-audit/hash-payload-order.js
//
// Exit code: 0 = all pass, 1 = any failure.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const REPO = path.resolve(__dirname, '../../../..');
const N8N_DIR = path.join(REPO, 'apps/outreach-workflows/n8n');

// ---------------------------------------------------------------------------
// Fixture — values picked to exercise multibyte UTF-8 + a realistic Postiz
// integration id. The reference hash is precomputed by Node's crypto module.
// ---------------------------------------------------------------------------
const FIXTURE = {
  draft_text:           'Hey — interesting take on subplot tracking. PlotLens (https://plotlens.ai) is built around exactly this; free tier handles 3 books and the timeline UI is the killer feature.',
  destination:          'cmpefsrxp0005kbb1ttpbkjnf',
  postType:             'reply',
  platform:             'bluesky',
};

const REFERENCE_HASH = crypto.createHash('sha256')
  .update(FIXTURE.draft_text + FIXTURE.destination + FIXTURE.postType + FIXTURE.platform, 'utf8')
  .digest('hex');

// ---------------------------------------------------------------------------
// Node loader
// ---------------------------------------------------------------------------
function loadNodeJs(file, name) {
  const raw = JSON.parse(fs.readFileSync(path.join(N8N_DIR, file), 'utf8'));
  const docs = Array.isArray(raw) ? raw : [raw];
  for (const doc of docs) {
    for (const node of (doc.nodes || [])) {
      if (node.name === name) return node.parameters.jsCode || '';
    }
  }
  throw new Error(`Node '${name}' not found in ${file}`);
}

// ---------------------------------------------------------------------------
// Sandbox runner. Each node's jsCode is wrapped in a function that stubs
// `$input` / `$env` / etc. with values backed by the fixture so the node's
// own sha256 / concat expression runs unchanged. We capture the
// `approved_content_hash` field from the node's return value.
// ---------------------------------------------------------------------------
function runNode(jsCode, stubs) {
  const argNames = Object.keys(stubs);
  const argValues = argNames.map(n => stubs[n]);
  // eslint-disable-next-line no-new-func
  const fn = new Function(...argNames, `
    ${jsCode}
  `);
  return fn(...argValues);
}

// Build Approval expects body fields from a parsed urlencoded form.
function runBuildApproval(jsCode) {
  const body = {
    decision: 'approved',
    chosen_variant: 'helpful_only',
    approved_platform: FIXTURE.platform,
    text_helpful_only: FIXTURE.draft_text,
    original_text_helpful_only: FIXTURE.draft_text,  // wasEdited = false
    draft_id_helpful_only: '4242',
    outreach_item_id: '777',
    approved_destination: FIXTURE.destination,
    approved_post_type: FIXTURE.postType,
    notes: null,
  };
  const $input = { item: { json: { body } } };
  const result = runNode(jsCode, { $input });
  if (!Array.isArray(result) || !result[0] || !result[0].json) {
    throw new Error("Build Approval returned unexpected shape");
  }
  return result[0].json.approved_content_hash;
}

// Build Slack Approval reads from $input.item.json directly. The PLATFORM_MAP
// in the node maps platform_key -> {platform, integration, label}; pick the
// key whose integration matches our fixture destination so the lookup yields
// the fixture values.
function runBuildSlackApproval(jsCode) {
  const d = {
    verb: 'approve',
    platform_key: 'bluesky_brand',           // → bluesky / cmpefsrxp0005kbb1ttpbkjnf
    draft_text: FIXTURE.draft_text,
    draft_id: 4242,
    outreach_item_id: 777,
    slack_user_name: 'jeremy',
    response_url: 'https://hooks.slack.example/x',
    suggested_post_type: FIXTURE.postType,
  };
  const $input = { item: { json: d } };
  const result = runNode(jsCode, { $input });
  if (!Array.isArray(result) || !result[0] || !result[0].json) {
    throw new Error("Build Slack Approval returned unexpected shape");
  }
  const row = result[0].json;
  // Defensive: the fixture's PLATFORM_MAP entry must actually be present in
  // the live node. If the operator removed bluesky_brand, surface that.
  if (row.approved_destination !== FIXTURE.destination) {
    throw new Error(
      `PLATFORM_MAP regression: bluesky_brand maps to integration ` +
      `'${row.approved_destination}', fixture expects '${FIXTURE.destination}'. ` +
      `Update this test's FIXTURE.destination if the integration id was rotated.`
    );
  }
  if (row.approved_platform !== FIXTURE.platform) {
    throw new Error(`PLATFORM_MAP regression: bluesky_brand → platform '${row.approved_platform}' (expected '${FIXTURE.platform}')`);
  }
  return row.approved_content_hash;
}

// Verify Hash reads from $input.item.json. We don't want it to throw on
// mismatch; we just want to capture the computed hash. Pre-set
// approved_content_hash to the (already known) reference so the node returns
// {..., hash_verified: true} — but we'll fish the computed hash out by
// patching the node's throw into a return. Simpler: feed it the reference
// hash AND swap to a try/catch in the wrapper to re-run with a deliberately
// wrong hash to force the error path, and parse the computed value from the
// thrown Error message.
//
// Why this throw-parsing trick exists: Verify Hash deliberately throws on
// hash mismatch and embeds `computed=<hex>` in the Error message — this is
// what an n8n operator sees in the execution log when a dispatch fails
// integrity verification, so the throw format is part of the operational
// contract for diagnosing publish failures, not an internal implementation
// detail. We piggy-back on that contract here to recover the computed hash
// for this test. If Verify Hash's error message format ever changes (e.g.
// the `computed=<hex>` token is renamed or removed), this test produces a
// clear `Verify Hash error did not include computed=<hex>: <error>`
// diagnostic rather than silently misreporting, so the coupling is loud.
function runVerifyHash(jsCode) {
  const item = {
    final_text:             FIXTURE.draft_text,
    approved_destination:   FIXTURE.destination,
    approved_post_type:     FIXTURE.postType,
    approved_platform:      FIXTURE.platform,
    approved_content_hash:  REFERENCE_HASH,   // happy path; the node returns successfully
  };
  const $input = { item: { json: item } };
  let result;
  try {
    result = runNode(jsCode, { $input });
  } catch (e) {
    // If the reference hash is wrong, the node throws with the computed hash
    // in the message — pull it out so the diagnostic is useful.
    const m = /computed=([0-9a-f]{64})/.exec(e.message || '');
    if (m) return m[1];
    throw e;
  }
  if (!Array.isArray(result) || !result[0] || !result[0].json) {
    throw new Error("Verify Hash returned unexpected shape");
  }
  // The node doesn't return the computed hash explicitly when it matches,
  // but it does set hash_verified. Recompute via the same expression by
  // re-running with a wrong stored hash and parsing the error message.
  const wrongItem = { ...item, approved_content_hash: '0'.repeat(64) };
  try {
    runNode(jsCode, { $input: { item: { json: wrongItem } } });
  } catch (e) {
    const m = /computed=([0-9a-f]{64})/.exec(e.message || '');
    if (m) return m[1];
    throw new Error(`Verify Hash error did not include computed=<hex>: ${e.message}`);
  }
  throw new Error('Verify Hash did not throw on intentional mismatch — invariant broken.');
}

// ---------------------------------------------------------------------------
// Bonus: pin the literal concat expression in each node. The expression
// shape is `sha256(<a> + <b> + <c> + <d>)`. We assert each variable in the
// concat resolves (in order) to: text-bearing var, destination, postType,
// platform. This catches reorderings that happen to collide on a fixture.
// ---------------------------------------------------------------------------
const CANONICAL_TAIL = ['destination', 'postType', 'platform'];

function findHashConcat(jsCode, label) {
  // Find all `sha256(` calls; return the first one whose body is a `+`-chain
  // of length 4. Walk indices manually to skip nested parens.
  let from = 0;
  while (true) {
    const i = jsCode.indexOf('sha256(', from);
    if (i < 0) return null;
    let depth = 0;
    let start = -1;
    let end = -1;
    for (let j = i + 'sha256'.length; j < jsCode.length; j++) {
      const ch = jsCode[j];
      if (ch === '(') { depth++; if (start < 0) start = j + 1; }
      else if (ch === ')') { depth--; if (depth === 0) { end = j; break; } }
    }
    if (end < 0) return null;
    const inner = jsCode.slice(start, end).trim();
    const parts = inner.split('+').map(s => s.trim());
    if (parts.length === 4 && parts.every(p => /^[A-Za-z_][\w.]*$/.test(p))) {
      return { inner, parts, label };
    }
    from = end + 1;
  }
}

// ---------------------------------------------------------------------------
// Run the checks
// ---------------------------------------------------------------------------
let pass = 0;
let fail = 0;
function record(name, ok, detail) {
  if (ok) { pass++; console.log(`PASS  ${name}`); }
  else    { fail++; console.log(`FAIL  ${name}${detail ? '\n  ' + detail : ''}`); }
}

console.log('=== hash-payload concatenation-order drift guard ===');
console.log(`  fixture.draft_text  = ${JSON.stringify(FIXTURE.draft_text.slice(0, 48))}...`);
console.log(`  fixture.destination = ${FIXTURE.destination}`);
console.log(`  fixture.postType    = ${FIXTURE.postType}`);
console.log(`  fixture.platform    = ${FIXTURE.platform}`);
console.log(`  reference hash      = ${REFERENCE_HASH}\n`);

const nodes = [
  { label: 'Build Approval (form)',     file: 'review.json',             name: 'Build Approval',       runner: runBuildApproval },
  { label: 'Build Slack Approval',      file: 'review.json',             name: 'Build Slack Approval', runner: runBuildSlackApproval },
  { label: 'Verify Hash (dispatcher)',  file: 'publish-dispatcher.json', name: 'Verify Hash',          runner: runVerifyHash },
];

const concats = [];

for (const spec of nodes) {
  const code = loadNodeJs(spec.file, spec.name);
  // 1. Live-execute the node against the fixture and compare to reference.
  let got;
  try {
    got = spec.runner(code);
  } catch (e) {
    record(`${spec.label}: hash matches reference`, false, `runner threw: ${e.message}`);
    continue;
  }
  record(
    `${spec.label}: hash matches reference`,
    got === REFERENCE_HASH,
    `expected ${REFERENCE_HASH}\n  got      ${got}`
  );

  // 2. Extract the literal sha256(...) concat expression for the
  // pinned-canonical-order assertion.
  const concat = findHashConcat(code, spec.label);
  if (!concat) {
    record(`${spec.label}: sha256() concat shape extractable`, false, 'could not locate a sha256(a+b+c+d) call');
    continue;
  }
  concats.push({ ...concat, spec });
  record(`${spec.label}: sha256() concat is 4-part identifier chain`, true);
}

// Canonical-order pinning: every concat's tail (parts 1..3) must equal
// CANONICAL_TAIL via the bare identifier name (last segment after a dot).
// The leading text variable differs across nodes (finalText / d.draft_text /
// finalText) so we only pin the tail.
console.log('\n=== canonical order (tail = destination, postType, platform) ===');
for (const c of concats) {
  const tailIdentifiers = c.parts.slice(1).map(p => p.split('.').pop());
  const ok = tailIdentifiers.length === 3 && tailIdentifiers.every((v, i) => v === CANONICAL_TAIL[i]);
  record(
    `${c.spec.label}: concat tail = [${tailIdentifiers.join(', ')}]`,
    ok,
    `expected tail ${JSON.stringify(CANONICAL_TAIL)}, got ${JSON.stringify(tailIdentifiers)} (raw: ${c.inner})`
  );
}

console.log(`\n=== ${pass} pass, ${fail} fail ===`);
process.exit(fail ? 1 : 0);
