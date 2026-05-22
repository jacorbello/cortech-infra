#!/usr/bin/env node
// Draft prompt invariants drift guard.
//
// Bug class: the `Build Prompt` Code node in `draft.json` constructs the
// Anthropic prompt that produces all three outreach variants. Two product
// failures we've already seen in production:
//
//   1. Length: Sonnet generated 542 / 579 / 716-char drafts for outreach item
//      #2258 — all over Bluesky's 300-char limit. Postiz accepted the API
//      call, queued the post, and Bluesky silently rejected it on publish.
//      The visible Postiz UI message was just "length 542/300".
//
//   2. Attribution: even when the excerpt was rich, drafts did not reference
//      the source by name or URL. Readers saw posts about "Joanna and Nadim"
//      with no context for who they are or what conversation is being
//      responded to. Out-of-feed framing is hostile.
//
// Both issues trace back to the prompt giving Sonnet no hard constraints. The
// fix is to PIN per-variant length budgets and a source-attribution
// requirement in the prompt body. This audit ensures those pins don't drift.
//
// Pinned invariants:
//   1. The prompt contains the literal sub-heading "## Length & attribution".
//   2. Each of the three variants has its char budget literally present:
//        - `helpful_only`     ≤ 280 characters
//        - `founder_context`  ≤ 280 characters
//        - `soft_product`     ≤ 500 characters
//   3. The attribution requirement is referenced ("Reference the source author"
//      or "Inline the source URL").
//
// Re-run after editing draft.json:
//   node apps/outreach-workflows/tests/sha256-audit/draft-prompt-invariants.js
//
// Exit code: 0 = all pins hold, 1 = drift.

const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '../../../..');
const DRAFT_PATH = path.join(REPO, 'apps/outreach-workflows/n8n/draft.json');

function loadBuildPromptCode() {
  const raw = JSON.parse(fs.readFileSync(DRAFT_PATH, 'utf8'));
  const docs = Array.isArray(raw) ? raw : [raw];
  for (const doc of docs) {
    for (const node of (doc.nodes || [])) {
      if (node.name === 'Build Prompt' && node.type === 'n8n-nodes-base.code') {
        const code = node.parameters && node.parameters.jsCode;
        if (typeof code !== 'string') {
          throw new Error("'Build Prompt' node has no jsCode parameter");
        }
        return code;
      }
    }
  }
  throw new Error("'Build Prompt' Code node not found in draft.json");
}

function main() {
  console.log('=== draft-prompt-invariants drift guard ===');
  const code = loadBuildPromptCode();
  const failures = [];

  // Invariant 1: section heading present
  if (!code.includes('## Length & attribution')) {
    failures.push("'## Length & attribution' section missing from prompt");
  } else {
    console.log("  OK: section heading present");
  }

  // Invariant 2: per-variant char budgets pinned
  // Match `\`helpful_only\` ... ≤ 280` (with markdown backtick escape from the template literal)
  const BUDGET_PATTERNS = [
    { variant: 'helpful_only',    re: /helpful_only.*≤\s*280/ },
    { variant: 'founder_context', re: /founder_context.*≤\s*280/ },
    { variant: 'soft_product',    re: /soft_product.*≤\s*500/ },
  ];
  for (const { variant, re } of BUDGET_PATTERNS) {
    if (!re.test(code)) {
      failures.push(`Per-variant length budget for '${variant}' is missing or changed`);
    } else {
      console.log(`  OK: char budget pinned for '${variant}'`);
    }
  }

  // Invariant 3: attribution requirement present
  const ATTRIBUTION_PATTERN = /Reference the source author|Inline the source URL/;
  if (!ATTRIBUTION_PATTERN.test(code)) {
    failures.push("source-attribution requirement missing from prompt");
  } else {
    console.log("  OK: source-attribution requirement present");
  }

  if (failures.length === 0) {
    console.log('\nPASS: draft-prompt invariants intact.');
    process.exit(0);
  }
  console.error('\nFAIL: draft-prompt invariants drifted:');
  for (const f of failures) console.error(`  - ${f}`);
  process.exit(1);
}

main();
