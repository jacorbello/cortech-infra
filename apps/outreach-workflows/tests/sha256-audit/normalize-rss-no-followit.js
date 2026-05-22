#!/usr/bin/env node
// Normalize RSS follow.it-unwrap drift guard.
//
// Bug class: the discover workflow's `Normalize RSS` Code node is the only
// hook we have to canonicalise feed item URLs before they hit the database.
// The Creative Penn (and any publisher who delegates their RSS to follow.it)
// emits items whose `link` and `guid` are tracking proxies of the shape:
//
//   https://api.follow.it/track-rss-story-click/v3/<opaque>?utm_source=follow.it
//
// If the `Normalize RSS` node is ever simplified back to a one-liner
// (`source_url: item.json.link`), every downstream consumer — review queue,
// auto-draft, Slack approvals, Postiz publish — starts re-storing those
// tracking proxies as canonical, and operators have to back-fill again.
//
// This audit pins three invariants:
//
//   1. The node's jsCode literally references `unwrapFollowIt` (function name).
//   2. It literally references `api.follow.it` (host predicate).
//   3. Functionally, when the body is loaded into a sandbox with a stubbed
//      `fetch` that mimics follow.it's 302-with-`?q=` behaviour, a synthetic
//      follow.it input is unwrapped to its canonical URL AND a non-follow.it
//      input passes through untouched.
//
// Re-run after editing discover.json:
//   node apps/outreach-workflows/tests/sha256-audit/normalize-rss-no-followit.js
//
// Exit code: 0 = all invariants hold, 1 = at least one failure.

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const REPO = path.resolve(__dirname, '../../../..');
const DISCOVER_PATH = path.join(REPO, 'apps/outreach-workflows/n8n/discover.json');

const FOLLOWIT_PROXY = 'https://api.follow.it/track-rss-story-click/v3/OPAQUE_TOKEN?utm_source=follow.it';
const FOLLOWIT_CANONICAL = 'https://thecreativepenn.com/2026/05/12/canonical-post/';
const FOLLOWIT_LOC = `https://follow.it/intl/?q=${encodeURIComponent(FOLLOWIT_CANONICAL)}&otherparam=1`;
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

// Stub fetch: mimics the follow.it 302 behaviour for the proxy URL and
// returns "no Location header" for everything else (which is never called
// because unwrapFollowIt early-returns on non-follow.it URLs).
function makeStubFetch() {
  return async function stubFetch(url /* , opts */) {
    if (/^https:\/\/api\.follow\.it\//.test(url)) {
      return {
        headers: {
          get(name) {
            if (String(name).toLowerCase() === 'location') return FOLLOWIT_LOC;
            return null;
          },
        },
      };
    }
    return { headers: { get() { return null; } } };
  };
}

// AbortSignal.timeout is a Node 20+ static. The sandbox inherits the host's
// AbortSignal via the context's globalThis, so we just expose it explicitly
// to keep the contract narrow.
function makeSandbox(jsCode) {
  const items = [
    { json: { link: FOLLOWIT_PROXY,    contentSnippet: 'Joanna Penn talks with a guest about authorship in an age of AI abundance — what changes, what holds.', creator: 'Joanna Penn' } },
    { json: { link: PASSTHROUGH_URL,   contentSnippet: 'Jane Friedman on what indie authors should actually charge for their next ebook in a market shifting weekly.', creator: 'Jane Friedman' } },
  ];
  // Wrap the node body as an async IIFE so top-level await works.
  const wrapped = `(async () => { ${jsCode} })()`;
  const ctx = vm.createContext({
    items,
    fetch: makeStubFetch(),
    AbortSignal,
    URL,
    decodeURIComponent,
    encodeURIComponent,
    console,
  });
  return vm.runInContext(wrapped, ctx, { timeout: 5000 });
}

async function main() {
  console.log('=== normalize-rss-no-followit drift guard ===');
  const jsCode = loadNormalizeRssJs();

  const failures = [];

  // Invariant 1+2: static substring presence
  if (!jsCode.includes('unwrapFollowIt')) {
    failures.push("Normalize RSS jsCode no longer references 'unwrapFollowIt' helper");
  } else {
    console.log("  OK static: 'unwrapFollowIt' present");
  }
  if (!jsCode.includes('api.follow.it')) {
    failures.push("Normalize RSS jsCode no longer references 'api.follow.it' host predicate");
  } else {
    console.log("  OK static: 'api.follow.it' present");
  }

  // Invariant 3: functional unwrap behaviour
  let out;
  try {
    out = await makeSandbox(jsCode);
  } catch (e) {
    failures.push(`Normalize RSS jsCode threw under sandbox: ${e.message}`);
  }

  if (out !== undefined) {
    if (!Array.isArray(out)) {
      failures.push(`Normalize RSS returned non-array: ${typeof out}`);
    } else if (out.length !== 2) {
      failures.push(`Normalize RSS returned ${out.length} items, expected 2`);
    } else {
      const first = out[0] && out[0].json;
      const second = out[1] && out[1].json;
      if (!first || first.source_url !== FOLLOWIT_CANONICAL) {
        failures.push(
          `follow.it proxy URL was NOT unwrapped — got ${JSON.stringify(first && first.source_url)}`,
        );
      } else {
        console.log(`  OK functional: follow.it proxy unwrapped -> ${first.source_url}`);
      }
      if (!second || second.source_url !== PASSTHROUGH_URL) {
        failures.push(
          `non-follow.it URL was MUTATED — got ${JSON.stringify(second && second.source_url)}`,
        );
      } else {
        console.log(`  OK functional: non-follow.it URL passed through -> ${second.source_url}`);
      }
      // Bonus: confirm the platform tagging didn't regress.
      if (first && first.source_platform !== 'rss') {
        failures.push(`source_platform changed from 'rss' to ${JSON.stringify(first.source_platform)}`);
      }
    }
  }

  if (failures.length === 0) {
    console.log('\nPASS: Normalize RSS unwraps follow.it proxies and leaves canonical URLs alone.');
    process.exit(0);
  }
  console.error('\nFAIL: Normalize RSS follow.it-unwrap invariants broken:');
  for (const f of failures) console.error(`  - ${f}`);
  process.exit(1);
}

main().catch((e) => {
  console.error('FAIL: audit crashed:', e);
  process.exit(1);
});
