#!/usr/bin/env node
// End-to-end Slack signature verification test for the Verify Slack Signature
// Code node in review.json.
//
// Bug class: JS's `encodeURIComponent` and Go's `url.QueryEscape` disagree on
// several characters that are NOT percent-encoded by JS but ARE encoded by Go:
//   ( ) ' * ! ~   and  space (Go uses '+', JS uses '%20')
// Slack's Go-based dispatcher signs the body it transmitted, encoded by
// `url.QueryEscape`. The previous Code-node implementation re-encoded the
// parsed payload through `encodeURIComponent` — for any payload containing
// those characters (Slack interactive payloads routinely do: team/user/channel
// names with quotes, exclamation marks, parentheses, etc.) the reconstructed
// HMAC base string did NOT match what Slack signed, so the request was always
// rejected as "Invalid Slack signature".
//
// The fix: the Webhook node has options.rawBody=true, which exposes the raw
// HTTP body bytes under `item.binary.data` (base64). The verify code now
// HMAC's directly over those bytes — no re-encoding needed.
//
// This test:
//   1. Builds a synthetic Slack interactive payload (JSON) containing the
//      exact characters where the two encoders disagree.
//   2. Encodes the form body the way Slack/Go ACTUALLY would
//      (goQueryEscape — implemented here as a Go-faithful escape).
//   3. Computes the expected `v0=` signature with Node's crypto module.
//   4. Loads the `Verify Slack Signature` jsCode from review.json and runs it
//      in a sandbox that mirrors what n8n produces when rawBody=true (parsed
//      JSON under item.json.body PLUS the raw bytes under item.binary.data).
//   5. Asserts the Code node does NOT throw on a valid signature, and DOES
//      throw on a tampered body or wrong secret.
//
// Operational guardrail intent: lock in that we HMAC over the original bytes,
// not over a re-encoded reconstruction. If a future edit reintroduces
// `encodeURIComponent(bodyPayload)` (or any other re-encoding path) this test
// will fail because the synthetic payload contains characters where Go and JS
// differ.
//
// Re-run after editing review.json:
//   node apps/outreach-workflows/tests/sha256-audit/slack-signature-end-to-end.js
//
// Exit code: 0 = all pass, 1 = any failure.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const REPO = path.resolve(__dirname, '../../../..');
const REVIEW_JSON = path.join(REPO, 'apps/outreach-workflows/n8n/review.json');

let pass = 0;
let fail = 0;
function check(name, ok, detail) {
  if (ok) { pass++; console.log(`PASS  ${name}`); }
  else { fail++; console.log(`FAIL  ${name}${detail ? '\n  ' + detail : ''}`); }
}

// ---------------------------------------------------------------------------
// goQueryEscape: bit-faithful port of Go's net/url.QueryEscape.
// Unreserved (per Go's shouldEscape with mode=encodeQueryComponent):
//   A-Z a-z 0-9 - _ . ~
// Special:
//   space  -> '+'
//   others -> %HH (uppercase hex)
// ---------------------------------------------------------------------------
function goQueryEscape(s) {
  const bytes = Buffer.from(s, 'utf8');
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    const b = bytes[i];
    const isUnreserved =
      (b >= 0x41 && b <= 0x5A) || // A-Z
      (b >= 0x61 && b <= 0x7A) || // a-z
      (b >= 0x30 && b <= 0x39) || // 0-9
      b === 0x2D || // -
      b === 0x5F || // _
      b === 0x2E || // .
      b === 0x7E;   // ~
    if (isUnreserved) {
      out += String.fromCharCode(b);
    } else if (b === 0x20) {
      out += '+';
    } else {
      out += '%' + b.toString(16).toUpperCase().padStart(2, '0');
    }
  }
  return out;
}

// Sanity-check goQueryEscape against known divergences from encodeURIComponent.
// Go encodes these, JS leaves them raw: ( ) ' * ! ~ (note: Go also encodes ~ ... actually
// per RFC 3986 Go's mark set includes "~" as unreserved; double-check.)
// Per Go source (net/url/url.go shouldEscape mode=encodeQueryComponent):
//   unreserved = A-Z a-z 0-9 '-' '_' '.' '~'
// So ~ is unreserved in BOTH; the divergences from JS encodeURIComponent are:
//   ( ) ' * !  (JS leaves alone, Go encodes)
//   space      (JS -> %20, Go -> +)
// Add tests:
const divCases = [
  { ch: '(',  enc: '%28' },
  { ch: ')',  enc: '%29' },
  { ch: "'",  enc: '%27' },
  { ch: '*',  enc: '%2A' },
  { ch: '!',  enc: '%21' },
  { ch: ' ',  enc: '+'   },
];
for (const c of divCases) {
  check(`goQueryEscape('${c.ch === ' ' ? '<space>' : c.ch}') === '${c.enc}'`,
    goQueryEscape(c.ch) === c.enc,
    `got ${JSON.stringify(goQueryEscape(c.ch))}`);
}
// And confirm '~' is left alone (unreserved in both).
check("goQueryEscape('~') === '~'", goQueryEscape('~') === '~');

// ---------------------------------------------------------------------------
// Build the synthetic Slack payload + sign it with a test secret.
// ---------------------------------------------------------------------------
const payloadJson = JSON.stringify({
  type: 'block_actions',
  team: { id: 'T123', domain: 'plotlens' },
  user: { id: 'U456', name: 'jeremy', username: "o'jeremy" },
  actions: [{
    action_id: 'reject_1956',
    value: 'hello (world) ~ test * !',
    type: 'button',
  }],
  response_url: 'https://hooks.slack.com/actions/T123/abc/v0=def',
});

// Verify the synthetic payload genuinely triggers the encoder divergence.
// If goQueryEscape(payloadJson) === encodeURIComponent(payloadJson), the test
// would not catch the bug. Assert they differ.
const goEncoded = goQueryEscape(payloadJson);
const jsEncoded = encodeURIComponent(payloadJson);
check('Synthetic payload exercises Go/JS encoder divergence',
  goEncoded !== jsEncoded,
  'goQueryEscape and encodeURIComponent produced IDENTICAL output for the synthetic payload — test would not catch the bug.');

const goEncodedBody = 'payload=' + goEncoded;

const testSecret = '8f742231b10e8888abcd99aabbccdd11';
const testTs = String(Math.floor(Date.now() / 1000)); // fresh — must be within ±300s
const sigBase = `v0:${testTs}:${goEncodedBody}`;
const expectedSig = 'v0=' + crypto.createHmac('sha256', testSecret).update(sigBase, 'utf8').digest('hex');

// ---------------------------------------------------------------------------
// Load the Verify Slack Signature Code node's jsCode.
// ---------------------------------------------------------------------------
const docs = JSON.parse(fs.readFileSync(REVIEW_JSON, 'utf8'));
const docList = Array.isArray(docs) ? docs : [docs];
let verifyCode = null;
for (const doc of docList) {
  for (const n of (doc.nodes || [])) {
    if (n.name === 'Verify Slack Signature') verifyCode = n.parameters.jsCode;
  }
}
if (!verifyCode) {
  check('Verify Slack Signature jsCode loaded from review.json', false, 'node not found');
  console.log(`\n=== ${pass} pass, ${fail} fail ===`);
  process.exit(1);
}
check('Verify Slack Signature jsCode loaded from review.json', true);

// ---------------------------------------------------------------------------
// Build the n8n-shaped sandbox.
// With options.rawBody=true on a form-encoded webhook, n8n keeps the parsed
// JSON under item.json.body AND attaches the raw bytes under item.binary.data
// (base64). We mirror that exactly.
// ---------------------------------------------------------------------------
function buildItem(rawBytesB64, headers, parsedPayload) {
  return {
    json: {
      body: { payload: parsedPayload },
      headers,
    },
    binary: {
      data: {
        data: rawBytesB64,
        mimeType: 'application/x-www-form-urlencoded',
        fileName: 'data',
      },
    },
  };
}

function runVerify(itemOverride, secret) {
  const item = itemOverride;
  const $env = { SLACK_SIGNING_SECRET: secret };
  const $ = (name) => {
    if (name !== 'Webhook Slack Interactive') throw new Error('unexpected $ lookup: ' + name);
    return {
      first: () => item,
      item: item,
    };
  };
  const $input = {
    first: () => item,
    item: item,
  };
  // eslint-disable-next-line no-new-func
  const fn = new Function('$', '$env', '$input', 'Buffer', verifyCode);
  return fn($, $env, $input, Buffer);
}

// ---- Positive case: valid signature, bytes preserved ----------------------
const goodHeaders = {
  'x-slack-request-timestamp': testTs,
  'x-slack-signature': expectedSig,
};
const parsedPayload = payloadJson; // n8n stores the form value as a string
const goodItem = buildItem(
  Buffer.from(goodEncodedBytes()).toString('base64'),
  goodHeaders,
  parsedPayload,
);
function goodEncodedBytes() { return goEncodedBody; }

let positiveResult = null;
let positiveErr = null;
try {
  positiveResult = runVerify(goodItem, testSecret);
} catch (e) {
  positiveErr = e;
}
check('Verify Slack Signature ACCEPTS Go-encoded body (rawBody path)',
  positiveErr === null,
  positiveErr ? `threw: ${positiveErr.message}` : null);
check('Verify Slack Signature returns one item with verb=reject',
  Array.isArray(positiveResult) &&
    positiveResult.length === 1 &&
    positiveResult[0].json.verb === 'reject' &&
    positiveResult[0].json.outreach_item_id === 1956,
  positiveResult ? JSON.stringify(positiveResult[0] && positiveResult[0].json) : 'no result');

// ---- Negative case 1: wrong secret ----------------------------------------
let badSecretErr = null;
try {
  runVerify(goodItem, 'wrong-secret-1111111111111111');
} catch (e) {
  badSecretErr = e;
}
check('Wrong secret -> throws "Invalid Slack signature"',
  badSecretErr !== null && /Invalid Slack signature/.test(badSecretErr.message),
  badSecretErr ? badSecretErr.message : 'did not throw');

// ---- Negative case 2: tampered body ---------------------------------------
const tamperedBytes = goEncodedBody.replace('reject_1956', 'reject_9999');
const tamperedItem = buildItem(
  Buffer.from(tamperedBytes, 'utf8').toString('base64'),
  goodHeaders, // signature still matches the ORIGINAL body
  parsedPayload,
);
let tamperedErr = null;
try {
  runVerify(tamperedItem, testSecret);
} catch (e) {
  tamperedErr = e;
}
check('Tampered body -> throws "Invalid Slack signature"',
  tamperedErr !== null && /Invalid Slack signature/.test(tamperedErr.message),
  tamperedErr ? tamperedErr.message : 'did not throw');

// ---- Negative case 3: rawBody missing (regression guard) ------------------
const noRawBodyItem = {
  json: {
    body: { payload: parsedPayload },
    headers: goodHeaders,
  },
  binary: {},
};
let noRawErr = null;
try {
  runVerify(noRawBodyItem, testSecret);
} catch (e) {
  noRawErr = e;
}
check('Missing rawBody -> throws clear diagnostic',
  noRawErr !== null && /Raw body not available/.test(noRawErr.message),
  noRawErr ? noRawErr.message : 'did not throw');

// ---- Unknown verb / open_form_<oid> short-circuit -------------------------
// Build a payload with action_id 'open_form_42' and a valid signature, then
// confirm the verify code returns verb:'ignore' instead of throwing.
const openFormPayloadJson = JSON.stringify({
  type: 'block_actions',
  team: { id: 'T123', domain: 'plotlens' },
  user: { id: 'U456', name: 'jeremy', username: 'jeremy' },
  actions: [{
    action_id: 'open_form_42',
    type: 'button',
    url: 'https://n8n.corbello.io/webhook/render-approval-form?outreach_item_id=42',
  }],
  response_url: 'https://hooks.slack.com/actions/T123/abc/v0=def',
});
const openFormBody = 'payload=' + goQueryEscape(openFormPayloadJson);
const openFormSig = 'v0=' + crypto.createHmac('sha256', testSecret)
  .update(`v0:${testTs}:${openFormBody}`, 'utf8').digest('hex');
const openFormItem = buildItem(
  Buffer.from(openFormBody, 'utf8').toString('base64'),
  { 'x-slack-request-timestamp': testTs, 'x-slack-signature': openFormSig },
  openFormPayloadJson,
);
let openFormResult = null;
let openFormErr = null;
try {
  openFormResult = runVerify(openFormItem, testSecret);
} catch (e) {
  openFormErr = e;
}
check('open_form_<oid> -> verb:ignore, no throw',
  openFormErr === null &&
    Array.isArray(openFormResult) &&
    openFormResult[0].json.verb === 'ignore',
  openFormErr ? openFormErr.message : JSON.stringify(openFormResult && openFormResult[0] && openFormResult[0].json));

// ---- Unknown auto-id like 'e/DS5' -----------------------------------------
const autoIdPayloadJson = JSON.stringify({
  type: 'block_actions',
  team: { id: 'T123' },
  user: { id: 'U456', name: 'jeremy' },
  actions: [{ action_id: 'e/DS5', type: 'button' }],
  response_url: 'https://hooks.slack.com/actions/T123/abc/v0=def',
});
const autoIdBody = 'payload=' + goQueryEscape(autoIdPayloadJson);
const autoIdSig = 'v0=' + crypto.createHmac('sha256', testSecret)
  .update(`v0:${testTs}:${autoIdBody}`, 'utf8').digest('hex');
const autoIdItem = buildItem(
  Buffer.from(autoIdBody, 'utf8').toString('base64'),
  { 'x-slack-request-timestamp': testTs, 'x-slack-signature': autoIdSig },
  autoIdPayloadJson,
);
let autoIdResult = null;
let autoIdErr = null;
try {
  autoIdResult = runVerify(autoIdItem, testSecret);
} catch (e) {
  autoIdErr = e;
}
check("Auto-assigned action_id 'e/DS5' -> verb:ignore, no throw",
  autoIdErr === null &&
    Array.isArray(autoIdResult) &&
    autoIdResult[0].json.verb === 'ignore',
  autoIdErr ? autoIdErr.message : JSON.stringify(autoIdResult && autoIdResult[0] && autoIdResult[0].json));

console.log(`\n=== ${pass} pass, ${fail} fail ===`);
process.exit(fail ? 1 : 0);
