#!/usr/bin/env node
// Poll workflow status-writes drift guard.
//
// outreach_items.status='published' is a terminal-truth statement: "this
// item was actually published to the destination platform". The
// outreach-publish-poll workflow (poll.json) is the unique writer of
// that value — because it is the only workflow that has confirmation
// from Postiz that the post landed.
//
// If any other workflow ever writes outreach_items.status='published'
// (e.g. Workflow D regresses, or someone wires a new optimistic path),
// this guard fails and forces the author to either route through the
// poll or to explicitly justify the bypass.
//
// Pinned invariant:
//   1. EXACTLY ONE workflow file under apps/outreach-workflows/n8n/
//      contains a SQL string with outreach_items + status + 'published'
//      in a write position. That file MUST be poll.json.
//
// Re-run after authoring any new workflow:
//   node apps/outreach-workflows/tests/sha256-audit/poll-workflow-status-writes-audit.js
//
// Exit code: 0 = invariant holds, 1 = drift.

const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '../../../..');
const N8N_DIR = path.join(REPO, 'apps/outreach-workflows/n8n');

function nodeQueryStrings(doc) {
    const queries = [];
    for (const node of (doc.nodes || [])) {
        if (node.type === 'n8n-nodes-base.postgres') {
            const q = ((node.parameters || {}).query || '').toString();
            if (q) queries.push({ nodeName: node.name, q });
        }
    }
    return queries;
}

function writesOutreachPublished(q) {
    // Heuristic: an UPDATE or INSERT that touches outreach_items AND mentions
    // status with the literal 'published'. Catches both forms:
    //   UPDATE outreach_items SET status='published' ...
    //   INSERT INTO outreach_items (... status ...) VALUES ('published' ...)
    const upper = q;
    const writesItems = /\b(UPDATE|INSERT\s+INTO)\s+outreach_items\b/i.test(upper);
    if (!writesItems) return false;
    // Must contain both 'status' and the literal 'published' inside the same statement.
    return /\bstatus\b/i.test(upper) && /'published'/.test(upper);
}

function main() {
    console.log('=== poll-workflow-status-writes drift guard ===');
    const files = fs.readdirSync(N8N_DIR).filter(f => f.endsWith('.json')).sort();
    const writers = [];
    for (const f of files) {
        const raw = JSON.parse(fs.readFileSync(path.join(N8N_DIR, f), 'utf8'));
        const docs = Array.isArray(raw) ? raw : [raw];
        for (const doc of docs) {
            for (const { nodeName, q } of nodeQueryStrings(doc)) {
                if (writesOutreachPublished(q)) {
                    writers.push({ file: f, nodeName });
                }
            }
        }
    }

    const failures = [];
    if (writers.length === 0) {
        failures.push("No workflow writes outreach_items.status='published'. Expected poll.json to do so.");
    } else {
        for (const w of writers) {
            if (w.file !== 'poll.json') {
                failures.push(`'${w.file}' :: '${w.nodeName}' writes outreach_items.status='published' — poll.json must be the unique writer`);
            } else {
                console.log(`  OK: '${w.file}' :: '${w.nodeName}' writes outreach_items.status='published'`);
            }
        }
    }

    if (failures.length === 0) {
        console.log('\nPASS: poll.json is the unique writer of outreach_items.published.');
        process.exit(0);
    }
    console.error("\nFAIL: outreach_items.status='published' writes drifted:");
    for (const f of failures) console.error(`  - ${f}`);
    process.exit(1);
}

main();
