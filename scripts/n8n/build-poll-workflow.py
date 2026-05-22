#!/usr/bin/env python3
# Generates apps/outreach-workflows/n8n/poll.json — the outreach-publish-poll workflow.
#
# Per docs/superpowers/specs/2026-05-22-postiz-state-poll-design.md. Run this whenever
# the workflow shape needs an authoritative re-emit (e.g. after the n8n UI has been
# used to edit and re-export). Output is byte-stable across runs given the same input.

import json, os

WORKFLOW_ID = "pOlLpUbLiShReS01"
WORKFLOW_NAME = "outreach-publish-poll"

CRED_POSTGRES = {"id": "fOZmso5kyXr6Agdn", "name": "outreach-db-n8n"}
CRED_POSTIZ   = {"id": "pZtZApIkEy00000A", "name": "postiz-api-key"}
CRED_SLACK    = {"id": "o9pysvcgZQFhoOLP", "name": "slack-bot-token"}

SLACK_CHANNEL_ID = "C0B4SUTP8R4"  # SLACK_OUTREACH_CHANNEL_ID — see HANDOFF system-state table

def node(id_, name, type_, type_version, position, parameters, credentials=None, on_error=None):
    n = {
        "parameters": parameters,
        "id": id_,
        "name": name,
        "type": type_,
        "typeVersion": type_version,
        "position": position,
    }
    if credentials:
        n["credentials"] = credentials
    if on_error:
        n["onError"] = on_error
    return n

# ------- node definitions -------
schedule_trigger = node(
    "po000001-0001-0000-0000-000000000001",
    "Schedule Trigger",
    "n8n-nodes-base.scheduleTrigger",
    1,
    [200, 300],
    {"rule": {"interval": [{"field": "minutes", "minutesInterval": 2}]}},
)

fetch_pending = node(
    "po000002-0001-0000-0000-000000000002",
    "Fetch Pending",
    "n8n-nodes-base.postgres",
    2.6,
    [420, 300],
    {
        "operation": "executeQuery",
        "query": (
            "SELECT pj.id AS publish_job_id, pj.postiz_post_id, pj.sent_at, "
            "EXTRACT(EPOCH FROM (now() - pj.sent_at)) AS age_seconds, "
            "(SELECT d.outreach_item_id FROM approvals a JOIN drafts d ON d.id = a.draft_id WHERE a.id = pj.approval_id) AS outreach_item_id "
            "FROM publish_jobs pj "
            "WHERE pj.status = 'sent_to_postiz' AND pj.published_at IS NULL "
            "ORDER BY pj.sent_at NULLS FIRST, pj.id;"
        ),
        "options": {},
    },
    credentials={"postgres": CRED_POSTGRES},
)

if_any_pending = node(
    "po000003-0001-0000-0000-000000000003",
    "Any Pending?",
    "n8n-nodes-base.if",
    2.2,
    [640, 300],
    {
        "conditions": {
            "options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict"},
            "conditions": [{
                "id": "p1",
                "leftValue": "={{ $json.publish_job_id }}",
                "rightValue": "",
                "operator": {"type": "string", "operation": "exists"},
            }],
            "combinator": "and",
        },
        "options": {},
    },
)

compute_window = node(
    "po000004-0001-0000-0000-000000000004",
    "Compute Window Bounds",
    "n8n-nodes-base.code",
    2,
    [860, 200],
    {
        "mode": "runOnceForAllItems",
        "jsCode": (
            "const rows = $input.all().map(i => i.json);\n"
            "const sentAts = rows.map(r => new Date(r.sent_at)).filter(d => !isNaN(d.getTime()));\n"
            "const minSent = sentAts.length ? new Date(Math.min(...sentAts.map(d => d.getTime()))) : new Date(Date.now() - 60*60*1000);\n"
            "const SLACK_MS = 5 * 60 * 1000;\n"
            "const startDate = new Date(minSent.getTime() - SLACK_MS).toISOString();\n"
            "const endDate = new Date(Date.now() + SLACK_MS).toISOString();\n"
            "return { json: { startDate, endDate, rows } };"
        ),
    },
)

postiz_list = node(
    "po000005-0001-0000-0000-000000000005",
    "Postiz List Posts",
    "n8n-nodes-base.httpRequest",
    4.2,
    [1080, 200],
    {
        "method": "GET",
        "url": "={{ $env.POSTIZ_API_BASE_URL }}/posts?startDate={{ encodeURIComponent($json.startDate) }}&endDate={{ encodeURIComponent($json.endDate) }}",
        "authentication": "predefinedCredentialType",
        "nodeCredentialType": "httpHeaderAuth",
        "options": {},
    },
    credentials={"httpHeaderAuth": CRED_POSTIZ},
    on_error="continueErrorOutput",
)

reconcile = node(
    "po000006-0001-0000-0000-000000000006",
    "Reconcile",
    "n8n-nodes-base.code",
    2,
    [1300, 200],
    {
        "mode": "runOnceForAllItems",
        "jsCode": (
            "// Build map: postiz_id -> { state, publishDate, releaseURL }\n"
            "const resp = $input.first().json;\n"
            "const posts = (resp && resp.posts) || [];\n"
            "const byId = new Map();\n"
            "for (const p of posts) byId.set(p.id, p);\n"
            "\n"
            "const STUCK_THRESHOLD_SECONDS = 30 * 60;\n"
            "const KNOWN_STATES = new Set(['PUBLISHED', 'QUEUE', 'ERROR']);\n"
            "\n"
            "const rows = $('Compute Window Bounds').item.json.rows || [];\n"
            "const out = [];\n"
            "for (const r of rows) {\n"
            "  const post = byId.get(r.postiz_post_id);\n"
            "  if (!post) {\n"
            "    out.push({ json: { publish_job_id: r.publish_job_id, outreach_item_id: r.outreach_item_id, postiz_post_id: r.postiz_post_id, action: 'FAIL_ORPHAN', payload: {} } });\n"
            "    continue;\n"
            "  }\n"
            "  if (!KNOWN_STATES.has(post.state)) {\n"
            "    out.push({ json: { publish_job_id: r.publish_job_id, outreach_item_id: r.outreach_item_id, postiz_post_id: r.postiz_post_id, action: 'WARN_UNKNOWN', payload: { state: post.state } } });\n"
            "    continue;\n"
            "  }\n"
            "  if (post.state === 'PUBLISHED') {\n"
            "    out.push({ json: { publish_job_id: r.publish_job_id, outreach_item_id: r.outreach_item_id, postiz_post_id: r.postiz_post_id, action: 'PUBLISH', payload: { publish_date: post.publishDate, release_url: post.releaseURL || '' } } });\n"
            "    continue;\n"
            "  }\n"
            "  if (post.state === 'ERROR') {\n"
            "    out.push({ json: { publish_job_id: r.publish_job_id, outreach_item_id: r.outreach_item_id, postiz_post_id: r.postiz_post_id, action: 'FAIL_ERROR', payload: {} } });\n"
            "    continue;\n"
            "  }\n"
            "  // QUEUE\n"
            "  if (Number(r.age_seconds) >= STUCK_THRESHOLD_SECONDS) {\n"
            "    out.push({ json: { publish_job_id: r.publish_job_id, outreach_item_id: r.outreach_item_id, postiz_post_id: r.postiz_post_id, action: 'STUCK', payload: { age_seconds: Number(r.age_seconds) } } });\n"
            "  } else {\n"
            "    out.push({ json: { publish_job_id: r.publish_job_id, outreach_item_id: r.outreach_item_id, postiz_post_id: r.postiz_post_id, action: 'NOOP', payload: {} } });\n"
            "  }\n"
            "}\n"
            "return out;"
        ),
    },
)

switch_action = node(
    "po000007-0001-0000-0000-000000000007",
    "Switch by Action",
    "n8n-nodes-base.switch",
    3,
    [1520, 300],
    {
        "rules": {
            "values": [
                {"conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict"},
                                 "conditions": [{"id": "a1", "leftValue": "={{ $json.action }}",
                                                 "rightValue": "PUBLISH",
                                                 "operator": {"type": "string", "operation": "equals"}}],
                                 "combinator": "and"},
                  "renameOutput": True, "outputKey": "publish"},
                {"conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict"},
                                 "conditions": [{"id": "a2", "leftValue": "={{ $json.action }}",
                                                 "rightValue": "FAIL_ERROR",
                                                 "operator": {"type": "string", "operation": "equals"}}],
                                 "combinator": "and"},
                  "renameOutput": True, "outputKey": "fail_error"},
                {"conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict"},
                                 "conditions": [{"id": "a3", "leftValue": "={{ $json.action }}",
                                                 "rightValue": "FAIL_ORPHAN",
                                                 "operator": {"type": "string", "operation": "equals"}}],
                                 "combinator": "and"},
                  "renameOutput": True, "outputKey": "fail_orphan"},
                {"conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict"},
                                 "conditions": [{"id": "a4", "leftValue": "={{ $json.action }}",
                                                 "rightValue": "STUCK",
                                                 "operator": {"type": "string", "operation": "equals"}}],
                                 "combinator": "and"},
                  "renameOutput": True, "outputKey": "stuck"},
                {"conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict"},
                                 "conditions": [{"id": "a5", "leftValue": "={{ $json.action }}",
                                                 "rightValue": "WARN_UNKNOWN",
                                                 "operator": {"type": "string", "operation": "equals"}}],
                                 "combinator": "and"},
                  "renameOutput": True, "outputKey": "warn_unknown"},
            ],
        },
        "options": {"fallbackOutput": "extra"},  # NOOP falls through to the unconnected extra output and ends
    },
)

mark_published = node(
    "po000008-0001-0000-0000-000000000008",
    "Mark Published & Log",
    "n8n-nodes-base.postgres",
    2.6,
    [1740, 100],
    {
        "operation": "executeQuery",
        "query": (
            "WITH pj_update AS ( "
            "  UPDATE publish_jobs "
            "     SET status='published', published_at=$1::timestamptz, published_url=$2 "
            "   WHERE id=$3 AND status='sent_to_postiz' AND published_at IS NULL "
            "  RETURNING id, (SELECT d.outreach_item_id FROM approvals a JOIN drafts d ON d.id=a.draft_id WHERE a.id=approval_id) AS outreach_item_id "
            "), oi_update AS ( "
            "  UPDATE outreach_items SET status='published' "
            "   WHERE id=(SELECT outreach_item_id FROM pj_update) AND status='reviewed' "
            "  RETURNING id "
            ") "
            "INSERT INTO outcomes (publish_job_id, notes) "
            "SELECT id, jsonb_build_object('kind','publish_confirmed','outreach_item_id',(SELECT outreach_item_id FROM pj_update),'postiz_post_id',$4,'published_at',$1,'published_url',$2)::text "
            "  FROM pj_update;"
        ),
        "options": {"queryReplacement": "={{ [$json.payload.publish_date, $json.payload.release_url, $json.publish_job_id, $json.postiz_post_id] }}"},
    },
    credentials={"postgres": CRED_POSTGRES},
)

mark_failed_error = node(
    "po000009-0001-0000-0000-000000000009",
    "Mark Failed (ERROR) & Log",
    "n8n-nodes-base.postgres",
    2.6,
    [1740, 220],
    {
        "operation": "executeQuery",
        "query": (
            "WITH pj_update AS ( "
            "  UPDATE publish_jobs SET status='failed', failure_reason='Postiz state=ERROR' "
            "   WHERE id=$1 AND status='sent_to_postiz' "
            "  RETURNING id "
            ") "
            "INSERT INTO outcomes (publish_job_id, notes) "
            "SELECT id, jsonb_build_object('kind','publish_failed','outreach_item_id',$2::bigint,'postiz_post_id',$3,'reason','postiz_error')::text "
            "  FROM pj_update;"
        ),
        "options": {"queryReplacement": "={{ [$json.publish_job_id, $json.outreach_item_id, $json.postiz_post_id] }}"},
    },
    credentials={"postgres": CRED_POSTGRES},
)

mark_failed_orphan = node(
    "po000010-0001-0000-0000-00000000000a",
    "Mark Failed (Orphan) & Log",
    "n8n-nodes-base.postgres",
    2.6,
    [1740, 340],
    {
        "operation": "executeQuery",
        "query": (
            "WITH pj_update AS ( "
            "  UPDATE publish_jobs SET status='failed', failure_reason='Postiz post not found' "
            "   WHERE id=$1 AND status='sent_to_postiz' "
            "  RETURNING id "
            ") "
            "INSERT INTO outcomes (publish_job_id, notes) "
            "SELECT id, jsonb_build_object('kind','publish_orphaned','outreach_item_id',$2::bigint,'postiz_post_id',$3,'reason','postiz_orphan')::text "
            "  FROM pj_update;"
        ),
        "options": {"queryReplacement": "={{ [$json.publish_job_id, $json.outreach_item_id, $json.postiz_post_id] }}"},
    },
    credentials={"postgres": CRED_POSTGRES},
)

mark_stuck = node(
    "po000011-0001-0000-0000-00000000000b",
    "Mark Manual (Stuck) & Log",
    "n8n-nodes-base.postgres",
    2.6,
    [1740, 460],
    {
        "operation": "executeQuery",
        "query": (
            "WITH pj_update AS ( "
            "  UPDATE publish_jobs SET status='manual_post_required', failure_reason='Stuck in Postiz QUEUE >30m' "
            "   WHERE id=$1 AND status='sent_to_postiz' "
            "  RETURNING id "
            ") "
            "INSERT INTO outcomes (publish_job_id, notes) "
            "SELECT id, jsonb_build_object('kind','publish_stuck','outreach_item_id',$2::bigint,'postiz_post_id',$3,'age_seconds',$4::int)::text "
            "  FROM pj_update;"
        ),
        "options": {"queryReplacement": "={{ [$json.publish_job_id, $json.outreach_item_id, $json.postiz_post_id, $json.payload.age_seconds] }}"},
    },
    credentials={"postgres": CRED_POSTGRES},
)

# Slack alerts — minimal text messages tagged with action kind.
def slack_alert(id_, name, position, msg_template):
    return node(
        id_, name, "n8n-nodes-base.slack", 2.3, position,
        {
            "select": "channel",
            "channelId": {"__rl": True, "value": SLACK_CHANNEL_ID, "mode": "id"},
            "text": msg_template,
            "messageType": "text",
            "otherOptions": {},
        },
        credentials={"slackApi": CRED_SLACK},
    )

slack_alert_failed = slack_alert(
    "po000012-0001-0000-0000-00000000000c",
    "Slack Alert Failed",
    [1960, 220],
    "={{ ':rotating_light: outreach-poll *publish_failed* — publish_job=' + $json.publish_job_id + ', outreach_item=' + $json.outreach_item_id + ', postiz_post=' + $json.postiz_post_id + '. Postiz Post.state=ERROR. Investigate Postiz logs.' }}",
)
slack_alert_orphan = slack_alert(
    "po000013-0001-0000-0000-00000000000d",
    "Slack Alert Orphaned",
    [1960, 340],
    "={{ ':rotating_light: outreach-poll *publish_orphaned* — publish_job=' + $json.publish_job_id + ', outreach_item=' + $json.outreach_item_id + ', postiz_post=' + $json.postiz_post_id + '. Postiz post not found in list (deleted via UI?).' }}",
)
slack_alert_stuck = slack_alert(
    "po000014-0001-0000-0000-00000000000e",
    "Slack Alert Stuck",
    [1960, 460],
    "={{ ':rotating_light: outreach-poll *publish_stuck* — publish_job=' + $json.publish_job_id + ', outreach_item=' + $json.outreach_item_id + ', postiz_post=' + $json.postiz_post_id + '. Stuck in Postiz QUEUE for ' + Math.floor(Number($json.payload.age_seconds)/60) + ' min.' }}",
)
slack_warn_unknown = slack_alert(
    "po000015-0001-0000-0000-00000000000f",
    "Slack Warning Unknown",
    [1740, 580],
    "={{ ':warning: outreach-poll *unknown_postiz_state* — publish_job=' + $json.publish_job_id + ', postiz_post=' + $json.postiz_post_id + ', state=`' + $json.payload.state + '`. Add handling to Reconcile.' }}",
)

slack_alert_http = slack_alert(
    "po000016-0001-0000-0000-000000000010",
    "Slack Alert Postiz HTTP",
    [1300, 460],
    "={{ ':rotating_light: outreach-poll *postiz_http_failure* — ' + (String($json.error || JSON.stringify($json)).slice(0, 400)) }}",
)

NODES = [
    schedule_trigger, fetch_pending, if_any_pending,
    compute_window, postiz_list, reconcile, switch_action,
    mark_published, mark_failed_error, mark_failed_orphan, mark_stuck,
    slack_alert_failed, slack_alert_orphan, slack_alert_stuck,
    slack_warn_unknown, slack_alert_http,
]

CONNECTIONS = {
    "Schedule Trigger":      {"main": [[{"node": "Fetch Pending", "type": "main", "index": 0}]]},
    "Fetch Pending":         {"main": [[{"node": "Any Pending?", "type": "main", "index": 0}]]},
    "Any Pending?":          {"main": [[{"node": "Compute Window Bounds", "type": "main", "index": 0}], []]},
    "Compute Window Bounds": {"main": [[{"node": "Postiz List Posts", "type": "main", "index": 0}]]},
    "Postiz List Posts":     {"main": [[{"node": "Reconcile", "type": "main", "index": 0}], [{"node": "Slack Alert Postiz HTTP", "type": "main", "index": 0}]]},
    "Reconcile":             {"main": [[{"node": "Switch by Action", "type": "main", "index": 0}]]},
    "Switch by Action":      {"main": [
        [{"node": "Mark Published & Log", "type": "main", "index": 0}],
        [{"node": "Mark Failed (ERROR) & Log", "type": "main", "index": 0}],
        [{"node": "Mark Failed (Orphan) & Log", "type": "main", "index": 0}],
        [{"node": "Mark Manual (Stuck) & Log", "type": "main", "index": 0}],
        [{"node": "Slack Warning Unknown", "type": "main", "index": 0}],
    ]},
    "Mark Failed (ERROR) & Log":  {"main": [[{"node": "Slack Alert Failed", "type": "main", "index": 0}]]},
    "Mark Failed (Orphan) & Log": {"main": [[{"node": "Slack Alert Orphaned", "type": "main", "index": 0}]]},
    "Mark Manual (Stuck) & Log":  {"main": [[{"node": "Slack Alert Stuck", "type": "main", "index": 0}]]},
}

doc = {
    "id": WORKFLOW_ID,
    "name": WORKFLOW_NAME,
    "active": False,
    "isArchived": False,
    "nodes": NODES,
    "connections": CONNECTIONS,
    "settings": {"executionOrder": "v1"},
    "staticData": None,
    "meta": None,
    "pinData": None,
    "tags": [],
    "versionId": "",
    "triggerCount": 1,
}

out_path = "apps/outreach-workflows/n8n/poll.json"
with open(out_path, "w") as f:
    json.dump([doc], f)
print(f"wrote {out_path}, {len(NODES)} nodes, {len(CONNECTIONS)} connection sources")
