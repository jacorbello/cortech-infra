#!/usr/bin/env node
// Postiz list-window drift guard.
//
// Live probe (2026-05-22): GET /api/public/v1/posts returns HTTP 400
// with {"message":["startDate must be a valid ISO 8601 date string",
// "endDate must be a valid ISO 8601 date string"]} when called without
// query params. Postiz mandates the date window. If poll.json ever
// drops one of the params during a refactor, every poll cycle would
// 400 and we'd silently lose state reconciliation.
//
// Pinned invariant:
//   The 'Postiz List Posts' HTTP node in poll.json has a URL that
//   contains BOTH 'startDate=' and 'endDate=' as substrings.
//
// Re-run after editing poll.json:
//   node apps/outreach-workflows/tests/sha256-audit/postiz-list-window-audit.js
//
// Exit code: 0 = invariant holds, 1 = drift.

const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '../../../..');
const POLL_PATH = path.join(REPO, 'apps/outreach-workflows/n8n/poll.json');

function main() {
    console.log('=== postiz-list-window drift guard ===');
    const raw = JSON.parse(fs.readFileSync(POLL_PATH, 'utf8'));
    const docs = Array.isArray(raw) ? raw : [raw];
    const failures = [];
    let found = false;
    for (const doc of docs) {
        for (const node of (doc.nodes || [])) {
            if (node.name === 'Postiz List Posts' && node.type === 'n8n-nodes-base.httpRequest') {
                found = true;
                const url = (node.parameters || {}).url || '';
                if (!url.includes('startDate=')) failures.push("'Postiz List Posts' URL missing 'startDate=' query param");
                if (!url.includes('endDate=')) failures.push("'Postiz List Posts' URL missing 'endDate=' query param");
                if (failures.length === 0) console.log(`  OK: URL = ${url}`);
            }
        }
    }
    if (!found) failures.push("'Postiz List Posts' HTTP node missing from poll.json");

    if (failures.length === 0) {
        console.log('\nPASS: Postiz list-window query params intact.');
        process.exit(0);
    }
    console.error('\nFAIL: Postiz list-window drift detected:');
    for (const f of failures) console.error(`  - ${f}`);
    process.exit(1);
}

main();
