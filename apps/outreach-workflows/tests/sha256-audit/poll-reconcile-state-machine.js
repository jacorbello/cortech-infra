#!/usr/bin/env node
// Reconcile state-machine sandbox test.
//
// The Reconcile Code node in poll.json maps the Postiz GET /posts response
// against the publish_jobs WHERE status='sent_to_postiz' set, emitting per-row
// action records routed by the downstream Switch. The state machine is
// load-bearing — every bug we've avoided in this design (premature published,
// missed ERROR alerts, stuck queue silently inflating gauges) only avoids
// regression as long as Reconcile keeps the mapping exact.
//
// This test VM-sandboxes the actual Reconcile jsCode against six input vectors
// covering every row in the state table:
//   1. found, state=PUBLISHED       -> action=PUBLISH (payload has publishDate + releaseURL)
//   2. found, state=ERROR           -> action=FAIL_ERROR
//   3. found, state=QUEUE, age<30m  -> action=NOOP
//   4. found, state=QUEUE, age>=30m -> action=STUCK (payload.age_seconds set)
//   5. not in Postiz list           -> action=FAIL_ORPHAN
//   6. found, state=DRAFT (unknown) -> action=WARN_UNKNOWN
//
// Re-run after editing poll.json:
//   node apps/outreach-workflows/tests/sha256-audit/poll-reconcile-state-machine.js
//
// Exit code: 0 = all vectors match expected action, 1 = drift.

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const REPO = path.resolve(__dirname, '../../../..');
const POLL_PATH = path.join(REPO, 'apps/outreach-workflows/n8n/poll.json');

function loadReconcileCode() {
    const raw = JSON.parse(fs.readFileSync(POLL_PATH, 'utf8'));
    const docs = Array.isArray(raw) ? raw : [raw];
    for (const doc of docs) {
        for (const node of (doc.nodes || [])) {
            if (node.name === 'Reconcile' && node.type === 'n8n-nodes-base.code') {
                const code = (node.parameters || {}).jsCode;
                if (typeof code !== 'string') throw new Error("'Reconcile' has no jsCode");
                if (node.parameters.mode !== 'runOnceForAllItems') {
                    throw new Error("'Reconcile' must be mode=runOnceForAllItems");
                }
                return code;
            }
        }
    }
    throw new Error("'Reconcile' Code node not found in poll.json");
}

function runReconcile(code, postizPosts, rows) {
    // n8n provides $input, $() helpers, etc. We stub the minimal surface used by Reconcile.
    const sandbox = {
        $input: {
            first: () => ({ json: { posts: postizPosts } }),
            all:   () => [{ json: { posts: postizPosts } }],
        },
        $: (nodeName) => {
            if (nodeName === 'Compute Window Bounds') {
                return { item: { json: { rows } } };
            }
            throw new Error(`Unstubbed $() reference: ${nodeName}`);
        },
        out: undefined,
    };
    // The Reconcile code returns a value (`return out;`). Wrap it in a function so
    // VM treats `return` as terminal.
    const wrapped = `out = (function() { ${code} })();`;
    vm.createContext(sandbox);
    vm.runInContext(wrapped, sandbox);
    return sandbox.out;
}

function main() {
    console.log('=== poll-reconcile state-machine sandbox test ===');
    const code = loadReconcileCode();
    const failures = [];

    const POSTS = [
        { id: 'p_published', state: 'PUBLISHED', publishDate: '2026-05-22T10:00:00Z', releaseURL: 'https://bsky.app/...' },
        { id: 'p_error',     state: 'ERROR' },
        { id: 'p_queue_fresh', state: 'QUEUE' },
        { id: 'p_queue_stuck', state: 'QUEUE' },
        { id: 'p_unknown',   state: 'DRAFT' },
    ];
    const ROWS = [
        { publish_job_id: 1, outreach_item_id: 100, postiz_post_id: 'p_published',   sent_at: '2026-05-22T09:55:00Z', age_seconds: 300 },
        { publish_job_id: 2, outreach_item_id: 101, postiz_post_id: 'p_error',       sent_at: '2026-05-22T09:55:00Z', age_seconds: 300 },
        { publish_job_id: 3, outreach_item_id: 102, postiz_post_id: 'p_queue_fresh', sent_at: '2026-05-22T09:55:00Z', age_seconds: 300 },
        { publish_job_id: 4, outreach_item_id: 103, postiz_post_id: 'p_queue_stuck', sent_at: '2026-05-22T09:25:00Z', age_seconds: 2100 },
        { publish_job_id: 5, outreach_item_id: 104, postiz_post_id: 'p_missing',     sent_at: '2026-05-22T09:55:00Z', age_seconds: 300 },
        { publish_job_id: 6, outreach_item_id: 105, postiz_post_id: 'p_unknown',     sent_at: '2026-05-22T09:55:00Z', age_seconds: 300 },
    ];

    const out = runReconcile(code, POSTS, ROWS);
    if (!Array.isArray(out) || out.length !== ROWS.length) {
        failures.push(`Reconcile returned ${out ? out.length : 'undefined'} items, expected ${ROWS.length}`);
    } else {
        const expected = [
            { action: 'PUBLISH',      pid: 'p_published',    extra: { publish_date: '2026-05-22T10:00:00Z', release_url: 'https://bsky.app/...' } },
            { action: 'FAIL_ERROR',   pid: 'p_error' },
            { action: 'NOOP',         pid: 'p_queue_fresh' },
            { action: 'STUCK',        pid: 'p_queue_stuck',  extra: { age_seconds: 2100 } },
            { action: 'FAIL_ORPHAN',  pid: 'p_missing' },
            { action: 'WARN_UNKNOWN', pid: 'p_unknown',      extra: { state: 'DRAFT' } },
        ];
        for (let i = 0; i < expected.length; i++) {
            const actual = out[i].json;
            const exp = expected[i];
            if (actual.action !== exp.action) {
                failures.push(`Vector ${i+1} (${exp.pid}): expected action=${exp.action}, got ${actual.action}`);
            } else if (exp.extra) {
                if (exp.action === 'PUBLISH' && (actual.payload.publish_date !== exp.extra.publish_date || actual.payload.release_url !== exp.extra.release_url)) {
                    failures.push(`Vector ${i+1} (${exp.pid}): payload mismatch: got ${JSON.stringify(actual.payload)}`);
                } else if (exp.action === 'STUCK' && Number(actual.payload.age_seconds) !== exp.extra.age_seconds) {
                    failures.push(`Vector ${i+1} (${exp.pid}): age_seconds mismatch: got ${actual.payload.age_seconds}`);
                } else if (exp.action === 'WARN_UNKNOWN' && actual.payload.state !== exp.extra.state) {
                    failures.push(`Vector ${i+1} (${exp.pid}): state mismatch: got ${actual.payload.state}`);
                } else {
                    console.log(`  OK: vector ${i+1} (${exp.pid}) -> ${exp.action}`);
                }
            } else {
                console.log(`  OK: vector ${i+1} (${exp.pid}) -> ${exp.action}`);
            }
        }
    }

    if (failures.length === 0) {
        console.log('\nPASS: Reconcile state machine matches the 6-vector table.');
        process.exit(0);
    }
    console.error('\nFAIL: Reconcile state-machine drift:');
    for (const f of failures) console.error(`  - ${f}`);
    process.exit(1);
}

main();
