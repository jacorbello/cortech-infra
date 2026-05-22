#!/usr/bin/env node
// SHA-256 / HMAC-SHA-256 audit harness for the pure-JS implementations
// embedded in n8n Code nodes across Workflows A/C/D + Slack verify/build paths.
//
// Why this exists: the JS runtime in n8n 2.9.4 task runner blocks
// require('crypto'), so each Code node ships its own copy of sha256().
// A subtle bit-twiddling bug (the JS >>> mod-32 trap, see memory
// `js-unsigned-rshift-modulo-32`) shipped in an earlier revision; this
// audit confirms the post-fix copies are RFC 6234 compliant AND identical
// across all five nodes.
//
// Coverage:
//   1. Drift — every `function sha256*(` body across all workflow JSON is
//      bucketed by name (`sha256`, `sha256Raw`, ...); within a bucket all
//      bodies must be byte-for-byte identical.
//   2. RFC 6234 — canonical `sha256(str)` matches Node's crypto for the
//      RFC vectors, padding boundaries, multibyte UTF-8, and realistic
//      payloads.
//   3. HMAC — `Verify Slack Signature` contains its own `hmacSha256(key, msg)`
//      helper that wraps a nested `sha256Raw(byteArray)`. We exec that helper
//      in-place and compare against `crypto.createHmac('sha256', key)` for
//      RFC 4231 vectors plus Slack-shaped `v0:<ts>:<body>` payloads.
//      NOTE: these HMAC vectors validate the SHA-256 / HMAC math only; they
//      do NOT validate that the Code node reconstructs the body Slack signed.
//      That responsibility belongs to slack-signature-end-to-end.js, which
//      exercises the full sandboxed verify path against a Go-encoded body.
//
// Re-run after editing any workflow JSON that contains sha256() or hmacSha256():
//   node apps/outreach-workflows/tests/sha256-audit/audit.js
//
// Exit code: 0 = all pass, 1 = any failure.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const REPO = path.resolve(__dirname, '../../../..');
const N8N_DIR = path.join(REPO, 'apps/outreach-workflows/n8n');

// Nodes that should contain a `function sha256(str)` body.
const SHA256_SOURCES = [
  { file: 'review.json',             node: 'Build Approval' },
  { file: 'review.json',             node: 'Verify Slack Signature' },
  { file: 'review.json',             node: 'Build Slack Approval' },
  { file: 'draft.json',              node: 'Apply Risk Score' },
  { file: 'publish-dispatcher.json', node: 'Verify Hash' },
];

// Nodes that should contain an HMAC helper (`hmacSha256` + nested `sha256Raw`).
const HMAC_SOURCES = [
  { file: 'review.json', node: 'Verify Slack Signature' },
];

// Extract a top-level function declaration with the given name. Returns the
// substring starting at `function <name>` through its matching closing brace.
// Handles strings (so `}` inside a quoted string doesn't fool the matcher).
function extractFunction(code, name) {
  const anchor = `function ${name}(`;
  const i = code.indexOf(anchor);
  if (i < 0) return null;
  let depth = 0;
  let started = false;
  let inStr = false;
  let strCh = '';
  for (let j = i; j < code.length; j++) {
    const ch = code[j];
    const prev = j > 0 ? code[j - 1] : '';
    if (inStr) {
      if (ch === strCh && prev !== '\\') inStr = false;
      continue;
    }
    if (ch === '"' || ch === "'" || ch === '`') { inStr = true; strCh = ch; continue; }
    if (ch === '{') { depth++; started = true; }
    else if (ch === '}') {
      depth--;
      if (started && depth === 0) return code.slice(i, j + 1);
    }
  }
  return null;
}

// Find every `function <name>(` declaration in `code`, returning a list of
// `{ name, body, offset }`. Picks up nested declarations too. We track
// name-suffix characters so `sha256Raw` doesn't get confused with `sha256`.
function findAllFunctions(code, prefix) {
  const re = new RegExp(`function\\s+(${prefix}[A-Za-z0-9_]*)\\s*\\(`, 'g');
  const out = [];
  let m;
  while ((m = re.exec(code)) !== null) {
    const name = m[1];
    const body = extractFunction(code.slice(m.index), name);
    if (body) out.push({ name, body, offset: m.index });
  }
  return out;
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

// Conservative whitespace normalization: strip trailing whitespace per line.
// Preserves all internal structure (indentation, blank lines, commas, etc.).
function normalizeWhitespace(s) {
  return s.split('\n').map(l => l.replace(/[ \t]+$/, '')).join('\n');
}

function md5(s) {
  return crypto.createHash('md5').update(s).digest('hex');
}

let totalPass = 0;
let totalFail = 0;
function check(name, ok, detail) {
  if (ok) { totalPass++; console.log(`PASS  ${name}`); }
  else { totalFail++; console.log(`FAIL  ${name}${detail ? '\n  ' + detail : ''}`); }
}

// ---------------------------------------------------------------------------
// 1. Drift check across every sha256* function body in every workflow.
// ---------------------------------------------------------------------------
console.log('=== sha256* drift check (all workflows) ===');

const allWorkflows = fs.readdirSync(N8N_DIR).filter(f => f.endsWith('.json')).sort();

// Map of name -> [{ file, node, body, md5 }]
const byName = new Map();

for (const file of allWorkflows) {
  const raw = JSON.parse(fs.readFileSync(path.join(N8N_DIR, file), 'utf8'));
  const docs = Array.isArray(raw) ? raw : [raw];
  for (const doc of docs) {
    for (const node of (doc.nodes || [])) {
      const code = node.parameters && node.parameters.jsCode;
      if (typeof code !== 'string') continue;
      const fns = findAllFunctions(code, 'sha256');
      for (const fn of fns) {
        const norm = normalizeWhitespace(fn.body);
        const h = md5(norm);
        if (!byName.has(fn.name)) byName.set(fn.name, []);
        byName.get(fn.name).push({ file, node: node.name, body: fn.body, normalized: norm, md5: h });
      }
    }
  }
}

const expectedNames = ['sha256', 'sha256Raw'];
for (const name of expectedNames) {
  const entries = byName.get(name) || [];
  console.log(`\n  ${name}:  ${entries.length} occurrence(s)`);
  entries.forEach(e => console.log(`    ${e.md5}  ${e.file}::${e.node}`));
  if (entries.length === 0) {
    check(`${name} present somewhere`, false, `no copies found`);
    continue;
  }
  const unique = new Set(entries.map(e => e.md5));
  if (unique.size !== 1) {
    const groups = {};
    for (const e of entries) (groups[e.md5] ||= []).push(`${e.file}::${e.node}`);
    const detail = Object.entries(groups)
      .map(([hash, locs]) => `    ${hash}\n      ${locs.join('\n      ')}`)
      .join('\n');
    check(`${name} bodies bit-identical`, false, `${unique.size} distinct bodies:\n${detail}`);
  } else {
    check(`${name} bodies bit-identical (${entries.length} copies)`, true);
  }
}

// Drift check for the original 5-source set (preserves the historical assert
// that every named node still ships a sha256 — guards against accidental
// removal as much as drift).
console.log('\n  legacy 5-source check (back-compat):');
for (const src of SHA256_SOURCES) {
  const code = loadNodeCode(src.file, src.node);
  const fn = extractFunction(code, 'sha256');
  check(`${src.file}::${src.node} has function sha256`, !!fn);
}

// ---------------------------------------------------------------------------
// 2. Canonical sha256() vs Node crypto (RFC 6234, padding, UTF-8, payloads).
// ---------------------------------------------------------------------------
// Defensive: if the drift check above found zero copies of sha256(), the
// expectedNames loop will already have recorded a FAIL — but accessing
// `byName.get('sha256')[0].body` would still throw `Cannot read properties of
// undefined` and crash before we get to print a summary or exit cleanly. Bail
// out with a clear diagnostic instead.
const sha256Bucket = byName.get('sha256');
if (!sha256Bucket || sha256Bucket.length === 0) {
  check('canonical sha256 body available for RFC vectors', false,
    'no sha256() copies were discovered in any workflow — skipping RFC + HMAC vectors');
  console.log(`\n=== ${totalPass} pass, ${totalFail} fail ===`);
  process.exit(1);
}
const canonicalSha256Body = sha256Bucket[0].body;
const sha256 = eval(`(${canonicalSha256Body})`); // eslint-disable-line no-eval
const refSha = (s) => crypto.createHash('sha256').update(s, 'utf8').digest('hex');

console.log('\n=== RFC 6234 Appendix B vectors ===');
function checkSha(name, input, expected) {
  const got = sha256(input);
  check(name, got === expected, `expected ${expected}\n  got      ${got}`);
}

checkSha('"abc"',          'abc',
  'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
checkSha('empty string',   '',
  'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
checkSha('56-char vector', 'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
  '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
checkSha('112-char vector',
  'abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu',
  'cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1');
checkSha('1,000,000 × "a"',
  'a'.repeat(1000000),
  'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0');

console.log('\n=== padding/block boundaries ===');
for (const n of [54, 55, 56, 57, 63, 64, 65, 118, 119, 120, 127, 128, 129]) {
  const s = 'a'.repeat(n);
  checkSha(`len ${n}`, s, refSha(s));
}

console.log('\n=== multibyte UTF-8 (custom encoder) ===');
checkSha('2-byte (café)',         'café',           refSha('café'));
checkSha('3-byte (Japanese)',     'こんにちは',     refSha('こんにちは'));
checkSha('4-byte (😀 surrogate)', 'hello 😀 world', refSha('hello 😀 world'));
checkSha('mixed BMP + surrogate', 'a→b漢字→😀→z',   refSha('a→b漢字→😀→z'));

console.log('\n=== realistic outreach payloads ===');
const payload =
  'Hey — saw your post about subplot tracking. PlotLens does exactly this. Free tier handles 3 books. https://plotlens.ai' +
  'reddit_plotlens_subreddit' + 'reply';
checkSha('approval-shape concat', payload, refSha(payload));

// ---------------------------------------------------------------------------
// 3. HMAC-SHA-256 — exec the node's helper and compare against Node crypto.
// ---------------------------------------------------------------------------
console.log('\n=== HMAC-SHA-256 (Verify Slack Signature hmacSha256) ===');

const verifyCode = loadNodeCode('review.json', 'Verify Slack Signature');
const hmacFnBody = extractFunction(verifyCode, 'hmacSha256');
if (!hmacFnBody) {
  check('hmacSha256 helper present', false, "couldn't extract function hmacSha256 from Verify Slack Signature");
} else {
  check('hmacSha256 helper present', true);
  // The helper references the outer `sha256()` declared at the top of the
  // same node. Bundle the outer sha256 source first, then the helper, into
  // one Function() so the closure resolves.
  // eslint-disable-next-line no-new-func
  const hmacSha256 = new Function(`
    ${canonicalSha256Body}
    ${hmacFnBody}
    return hmacSha256;
  `)();

  const refHmac = (key, msg) =>
    crypto.createHmac('sha256', Buffer.from(key, 'utf8'))
          .update(Buffer.from(msg, 'utf8'))
          .digest('hex');

  function checkHmac(name, key, msg) {
    const got = hmacSha256(key, msg);
    const expected = refHmac(key, msg);
    check(name, got === expected, `key=${JSON.stringify(key.slice(0, 24))}... msg=${JSON.stringify(msg.slice(0, 40))}...\n  expected ${expected}\n  got      ${got}`);
  }

  // RFC 4231 vectors (UTF-8 string forms — the node's strToBytes is UTF-8).
  // Test Case 1: key = 0x0b * 20 ("\x0b" repeated), msg = "Hi There"
  checkHmac('RFC 4231 case 1 (\\x0b*20 / "Hi There")',
    '\x0b'.repeat(20),
    'Hi There');
  // Test Case 2: key = "Jefe", msg = "what do ya want for nothing?"
  checkHmac('RFC 4231 case 2 ("Jefe" / "what do ya want for nothing?")',
    'Jefe',
    'what do ya want for nothing?');
  // Test Case 4: key = 0x01..0x19 (25 bytes), msg = 0xcd * 50 — using latin-1
  // chars that fall in the ASCII / 1-byte UTF-8 range to keep encoding parity
  // with the node helper.
  const k4 = '';
  let key4 = '';
  for (let i = 1; i <= 25; i++) key4 += String.fromCharCode(i);
  checkHmac('RFC 4231 case 4 shape (ASCII substitute for UTF-8 encoder parity)',
    key4,
    '~'.repeat(50));
  // Long-key path: key longer than 64 bytes triggers the sha256Raw(key) branch
  // inside the helper. RFC 4231 case 6 uses a 131-byte key.
  checkHmac('RFC 4231 case 6 shape (ASCII substitute for UTF-8 encoder parity)',
    'a'.repeat(131),
    'Test Using Larger Than Block-Size Key - Hash Key First');

  // Slack signing convention: sigBase = `v0:${ts}:${body}`.
  // Use a fixed timestamp + raw body so the test is deterministic.
  const slackSecret = '8f742231b10e8888abcd99yyyzzz85a5';
  const slackBody = 'payload=%7B%22type%22%3A%22block_actions%22%2C%22user%22%3A%7B%22id%22%3A%22U123%22%7D%7D';
  const slackTs = '1531420618';
  const slackSigBase = `v0:${slackTs}:${slackBody}`;
  checkHmac('Slack signing v0 base (payload= form-encoded)',
    slackSecret,
    slackSigBase);

  // Slack with an arbitrary unicode payload to exercise multibyte encoding
  // through the helper.
  checkHmac('Slack signing v0 base (unicode body)',
    slackSecret,
    `v0:${slackTs}:payload=text%3D${encodeURIComponent('café→漢字→😀')}`);
}

// ---------------------------------------------------------------------------
console.log(`\n=== ${totalPass} pass, ${totalFail} fail ===`);
process.exit(totalFail ? 1 : 0);
