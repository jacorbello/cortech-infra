#!/usr/bin/env node
// Workflow D no-rollup drift guard.
//
// The original outreach-publish-dispatcher (Workflow D) wrote
// outreach_items.status='published' via a Rollup outreach_items node fed
// by Mark Sent, Mark Failed, and Mark Manual. That set the row to
// "published" on Postiz HTTP 200 — before Postiz had actually published
// to Bluesky/Mastodon. Row 72 (Followup 13) was the proof. The fix
// (2026-05-22) was to delete the Rollup node and the 3 inbound edges.
// The outreach-publish-poll workflow now owns the "published" write.
//
// This guard ensures the Rollup never returns.
//
// Pinned invariants:
//   1. publish-dispatcher.json contains NO node named 'Rollup outreach_items'.
//   2. NO Postgres node in publish-dispatcher.json's SQL string contains a
//      write to outreach_items (UPDATE outreach_items ...).
//
// Re-run after editing publish-dispatcher.json:
//   node apps/outreach-workflows/tests/sha256-audit/workflow-d-no-rollup-audit.js
//
// Exit code: 0 = invariants hold, 1 = drift.

const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '../../../..');
const D_PATH = path.join(REPO, 'apps/outreach-workflows/n8n/publish-dispatcher.json');

function main() {
    console.log('=== workflow-d-no-rollup drift guard ===');
    const raw = JSON.parse(fs.readFileSync(D_PATH, 'utf8'));
    const docs = Array.isArray(raw) ? raw : [raw];
    const failures = [];
    for (const doc of docs) {
        for (const node of (doc.nodes || [])) {
            if (node.name === 'Rollup outreach_items') {
                failures.push("'Rollup outreach_items' node was reintroduced in publish-dispatcher.json");
            }
            if (node.type === 'n8n-nodes-base.postgres') {
                const q = (node.parameters || {}).query || '';
                if (/\bUPDATE\s+outreach_items\b/i.test(q) || /\bINSERT\s+INTO\s+outreach_items\b/i.test(q)) {
                    failures.push(`Postgres node '${node.name}' writes to outreach_items — the poll workflow is now the unique writer`);
                }
            }
        }
    }

    if (failures.length === 0) {
        console.log('  OK: no Rollup node; no outreach_items writes in dispatcher');
        console.log('\nPASS: Workflow D no-rollup invariant intact.');
        process.exit(0);
    }
    console.error('\nFAIL: Workflow D drifted back toward premature outreach_items writes:');
    for (const f of failures) console.error(`  - ${f}`);
    process.exit(1);
}

main();
