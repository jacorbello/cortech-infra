#!/usr/bin/env node
// SHA-256 RFC 6234 audit harness for the pure-JS implementation embedded
// in n8n Code nodes across Workflows A/C/D + Slack verify/build paths.
//
// Why this exists: the JS runtime in n8n 2.9.4 task runner blocks
// require('crypto'), so each Code node ships its own copy of sha256().
// A subtle bit-twiddling bug (the JS >>> mod-32 trap, see memory
// `js-unsigned-rshift-modulo-32`) shipped in an earlier revision; this
// audit confirms the post-fix copies are RFC 6234 compliant AND identical
// across all five nodes.
//
// Re-run after editing any workflow JSON that contains sha256():
//   node apps/outreach-workflows/tests/sha256-audit/audit.js
//
// Exit code: 0 = all pass, 1 = any failure.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const REPO = path.resolve(__dirname, '../../../..');
const N8N_DIR = path.join(REPO, 'apps/outreach-workflows/n8n');

const SOURCES = [
  { file: 'review.json',             node: 'Build Approval' },
  { file: 'review.json',             node: 'Verify Slack Signature' },
  { file: 'review.json',             node: 'Build Slack Approval' },
  { file: 'draft.json',              node: 'Apply Risk Score' },
  { file: 'publish-dispatcher.json', node: 'Verify Hash' },
];

function extractSha256(code) {
  const i = code.indexOf('function sha256');
  if (i < 0) return null;
  let depth = 0, started = false;
  for (let j = i; j < code.length; j++) {
    const ch = code[j];
    if (ch === '{') { depth++; started = true; }
    else if (ch === '}') { depth--; if (started && depth === 0) return code.slice(i, j + 1); }
  }
  return null;
}

function loadNodeCode(file, name) {
  const raw = JSON.parse(fs.readFileSync(path.join(N8N_DIR, file), 'utf8'));
  const docs = Array.isArray(raw) ? raw : [raw];
  for (const doc of docs) {
    for (const node of (doc.nodes || [])) {
      if (node.name === name) return node.parameters.jsCode || '';
    }
  }
  throw new Error(`Node '${name}' not found in ${file}`);
}

// 1. Extract all five copies; confirm bit-for-bit identical.
const extracted = SOURCES.map(({ file, node }) => {
  const code = loadNodeCode(file, node);
  const sha = extractSha256(code);
  if (!sha) throw new Error(`sha256() not found in ${file} / ${node}`);
  return { file, node, body: sha, md5: crypto.createHash('md5').update(sha).digest('hex') };
});

const uniqueHashes = new Set(extracted.map(e => e.md5));
console.log('=== drift check ===');
extracted.forEach(e => console.log(`  ${e.md5}  ${e.file}::${e.node}`));
if (uniqueHashes.size !== 1) {
  console.error(`\nFAIL: ${uniqueHashes.size} distinct sha256() bodies — drift detected. Fix workflows to share one implementation.`);
  process.exit(1);
}
console.log(`OK: all ${extracted.length} copies are bit-for-bit identical (${[...uniqueHashes][0]}).\n`);

// 2. Evaluate the canonical implementation.
const sha256 = eval(`(${extracted[0].body})`);
const refSha = (s) => crypto.createHash('sha256').update(s, 'utf8').digest('hex');

let pass = 0, fail = 0;
function check(name, input, expected) {
  const got = sha256(input);
  const ok = got === expected;
  if (ok) { pass++; console.log(`PASS  ${name}`); }
  else { fail++; console.log(`FAIL  ${name}\n  expected ${expected}\n  got      ${got}`); }
}

console.log('=== RFC 6234 Appendix B vectors ===');
check('"abc"',          'abc',
  'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
check('empty string',   '',
  'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
check('56-char vector', 'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
  '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
check('112-char vector',
  'abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu',
  'cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1');
check('1,000,000 × "a"',
  'a'.repeat(1000000),
  'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0');

console.log('\n=== padding/block boundaries ===');
for (const n of [54, 55, 56, 57, 63, 64, 65, 118, 119, 120, 127, 128, 129]) {
  const s = 'a'.repeat(n);
  check(`len ${n}`, s, refSha(s));
}

console.log('\n=== multibyte UTF-8 (custom encoder) ===');
check('2-byte (café)',         'café',           refSha('café'));
check('3-byte (Japanese)',     'こんにちは',     refSha('こんにちは'));
check('4-byte (😀 surrogate)', 'hello 😀 world', refSha('hello 😀 world'));
check('mixed BMP + surrogate', 'a→b漢字→😀→z',   refSha('a→b漢字→😀→z'));

console.log('\n=== realistic outreach payloads ===');
const payload =
  'Hey — saw your post about subplot tracking. PlotLens does exactly this. Free tier handles 3 books. https://plotlens.ai' +
  'reddit_plotlens_subreddit' + 'reply';
check('approval-shape concat', payload, refSha(payload));

console.log(`\n=== ${pass} pass, ${fail} fail ===`);
process.exit(fail ? 1 : 0);
