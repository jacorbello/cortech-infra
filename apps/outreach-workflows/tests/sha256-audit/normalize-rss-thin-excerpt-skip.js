#!/usr/bin/env node
// Normalize RSS thin-excerpt-skip drift guard.
//
// Bug class: feeds vary on which field they populate. The Creative Penn often
// uses `contentSnippet`. Writer Unboxed / Kill Zone / etc. sometimes emit only
// `content` or `description`, and occasionally none of them. When the excerpt
// is empty or near-empty, the downstream Anthropic draft step produces useless
// "No usable excerpt was found in this source" boilerplate that wastes both
// Anthropic tokens and reviewer attention — and Slack notifications keep
// firing for those items.
//
// `Normalize RSS` MUST:
//   1. Fall back through contentSnippet -> content -> description -> ''.
//   2. Drop items whose final extracted excerpt is shorter than the threshold
//      (currently 50 characters).
//   3. Strip HTML tags before measuring length (so a 200-char body of HTML
//      with 30 chars of text still gets skipped).
//
// Re-run after editing discover.json:
//   node apps/outreach-workflows/tests/sha256-audit/normalize-rss-thin-excerpt-skip.js
//
// Exit code: 0 = all invariants hold, 1 = at least one failure.

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const REPO = path.resolve(__dirname, '../../../..');
const DISCOVER_PATH = path.join(REPO, 'apps/outreach-workflows/n8n/discover.json');
const PASSTHROUGH_URL = 'https://janefriedman.com/2026/05/12/some-post/';

function loadNormalizeRssJs() {
  const raw = JSON.parse(fs.readFileSync(DISCOVER_PATH, 'utf8'));
  const docs = Array.isArray(raw) ? raw : [raw];
  for (const doc of docs) {
    for (const node of (doc.nodes || [])) {
      if (node.name === 'Normalize RSS' && node.type === 'n8n-nodes-base.code') {
        const code = node.parameters && node.parameters.jsCode;
        if (typeof code !== 'string') {
          throw new Error("'Normalize RSS' node has no jsCode parameter");
        }
        return code;
      }
    }
  }
  throw new Error("'Normalize RSS' Code node not found in discover.json");
}

function noopFetch() {
  return async () => ({ headers: { get() { return null; } } });
}

async function runSandbox(jsCode, items) {
  const wrapped = `(async () => { ${jsCode} })()`;
  const ctx = vm.createContext({
    items,
    fetch: noopFetch(),
    AbortSignal,
    URL,
    decodeURIComponent,
    encodeURIComponent,
    console: { log: () => {} },
  });
  return vm.runInContext(wrapped, ctx, { timeout: 5000 });
}

async function main() {
  console.log('=== normalize-rss-thin-excerpt-skip drift guard ===');
  const jsCode = loadNormalizeRssJs();
  const failures = [];

  if (!jsCode.includes('THIN_EXCERPT_THRESHOLD')) {
    failures.push("Normalize RSS jsCode no longer references THIN_EXCERPT_THRESHOLD constant");
  } else {
    console.log("  OK static: THIN_EXCERPT_THRESHOLD present");
  }

  // Mixed-field input covering the fallback chain + thin-skip + HTML stripping.
  const items = [
    // 0: thin contentSnippet, should be skipped
    { json: { link: `${PASSTHROUGH_URL}thin`, contentSnippet: 'too short' } },
    // 1: meaty contentSnippet, kept
    { json: { link: `${PASSTHROUGH_URL}meaty-snippet`, contentSnippet: 'A meaningful contentSnippet that easily clears the threshold and contains real authoring discussion.' } },
    // 2: empty contentSnippet, falls back to content
    { json: { link: `${PASSTHROUGH_URL}content-fallback`, contentSnippet: '', content: 'Body via content field with enough substance to clear the threshold and represent useful discussion.' } },
    // 3: empty contentSnippet + content, falls back to description
    { json: { link: `${PASSTHROUGH_URL}description-fallback`, contentSnippet: '', content: '', description: 'Body via description field with enough substance to clear the threshold and represent useful text.' } },
    // 4: HTML body that, once tags stripped, is BELOW the threshold — should be skipped
    { json: { link: `${PASSTHROUGH_URL}html-thin`, contentSnippet: '<p><b><i>hi</i></b></p><br/><br/>' } },
    // 5: nothing in any field, should be skipped silently
    { json: { link: `${PASSTHROUGH_URL}empty`, contentSnippet: '', content: '', description: '' } },
  ];

  let out;
  try {
    out = await runSandbox(jsCode, items);
  } catch (e) {
    failures.push(`Normalize RSS jsCode threw under sandbox: ${e.message}`);
  }

  if (out !== undefined) {
    if (!Array.isArray(out)) {
      failures.push(`Normalize RSS returned non-array: ${typeof out}`);
    } else {
      const urls = out.map((o) => o.json && o.json.source_url);
      const expectKept = [
        `${PASSTHROUGH_URL}meaty-snippet`,
        `${PASSTHROUGH_URL}content-fallback`,
        `${PASSTHROUGH_URL}description-fallback`,
      ];
      const expectSkipped = [
        `${PASSTHROUGH_URL}thin`,
        `${PASSTHROUGH_URL}html-thin`,
        `${PASSTHROUGH_URL}empty`,
      ];
      for (const u of expectKept) {
        if (!urls.includes(u)) failures.push(`expected kept URL not in output: ${u}`);
        else console.log(`  OK kept: ${u}`);
      }
      for (const u of expectSkipped) {
        if (urls.includes(u)) failures.push(`expected skipped URL was kept: ${u}`);
        else console.log(`  OK skipped: ${u}`);
      }
      // HTML stripping invariant on kept items
      for (const o of out) {
        if (o.json && /<[a-z]/i.test(o.json.source_excerpt || '')) {
          failures.push(`HTML tag survived strip in ${o.json.source_url}: ${o.json.source_excerpt}`);
        }
      }
    }
  }

  if (failures.length === 0) {
    console.log('\nPASS: Normalize RSS skips thin-excerpt items and walks the fallback chain.');
    process.exit(0);
  }
  console.error('\nFAIL: Normalize RSS thin-excerpt invariants broken:');
  for (const f of failures) console.error(`  - ${f}`);
  process.exit(1);
}

main().catch((e) => {
  console.error('FAIL: audit crashed:', e);
  process.exit(1);
});
