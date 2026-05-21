# Adding a New Channel to Postiz

This runbook covers connecting a new social channel to the PlotLens outreach pipeline. The initial onboarding of Bluesky and Mastodon happened during Phase 2 (tasks T22-T23 in `docs/superpowers/plans/2026-05-20-plotlens-outreach-phase2.md`). Reddit/X/LinkedIn are deferred to Phase 2.1.

## Pre-flight

1. The Postiz integration for the channel must exist as a provider in the running Postiz version (`ghcr.io/gitroomhq/postiz-app:v2.13.0`). Check `https://docs.postiz.com/providers/overview` first.
2. The brand convention for social accounts is `plotlens` / `@plotlens` / `plotlens.<instance>`.
3. You'll need terminal access with the Infisical CLI authenticated.

## Steps (in order)

### 1. Create the social account if it doesn't exist

Use the brand convention. Record the account email + recovery info in 1Password (or wherever brand secrets live).

### 2. Register OAuth app or generate an access token

Platform-specific. Each provider has its own quirks:

- **Bluesky** — handle + app password (NOT main account password). Settings → App passwords → "Add app password".
- **Mastodon** — register an application at `https://mastodon.social/settings/applications` (or whatever instance you're using). Redirect URI must be `https://postiz.corbello.io/integrations/social/mastodon`. Scopes must be granular: `write:statuses`, `write:media`, `profile` — NOT the broad `read write` checkbox.
- **Reddit** — currently blocked by Reddit's Responsible Builder Policy gate. Devvit is the replacement platform but doesn't fit a Postiz-style scheduler. Deferred to Phase 2.1.
- **X / Twitter** — needs a Developer Account; Free tier allows 1500 posts/month.
- **LinkedIn** — needs Marketing Developer Platform approval (1-2 weeks).

For Mastodon (and any other OAuth-based provider that uses env vars), set them in the deployment BEFORE attempting to connect:

```bash
# Example for Mastodon (already done as part of T23)
infisical secrets set --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --path=/postiz \
  MASTODON_CLIENT_ID=<client_id> \
  MASTODON_CLIENT_SECRET=<client_secret> \
  MASTODON_URL=https://mastodon.social
```

Then redeploy Postiz so the env vars take effect:

```bash
ssh root@192.168.1.52 "kubectl rollout restart deployment postiz -n plotlens-marketing"
```

### 3. Connect via the Postiz UI

`https://postiz.corbello.io` → Add Channel → pick provider → enter credentials. The provider will open an OAuth window or prompt for a token. If it fails:

- "Authorization failed - unknown client" → the env vars for that provider aren't wired. See step 2.
- "Invalid scope" → recheck the OAuth app's scope checkboxes (granular vs broad).
- "Redirect URI mismatch" → the OAuth app's redirect URI must EXACTLY match `https://postiz.corbello.io/integrations/social/<provider>`.

### 4. Smoke post

Test with a one-line message via the Postiz UI ("Create Post" → write text → pick channel → "Post Now"). Confirm visibility on the platform itself.

### 5. Save the channel integration ID to Infisical

The channel ID is visible in the URL or via the API. Easiest path is the API:

```bash
API_KEY=$(infisical secrets get POSTIZ_API_KEY --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --path=/postiz --plain)
curl -sS -H "Authorization: $API_KEY" \
  "https://postiz.corbello.io/api/public/v1/integrations" | python3 -m json.tool
```

Note: the Authorization header takes the raw key. Do NOT prefix with `Bearer ` — Postiz's public API rejects it. The base path is `/api/public/v1`, NOT `/api`.

Save the integration ID:

```bash
infisical secrets set --projectId=db72a923-3cd8-4636-b1ff-80845dc070ca --env=dev --path=/postiz \
  POSTIZ_INTEGRATION_<CHANNEL_NAME>=<integration_id>
```

Example existing entries:

| Secret | Channel | Provider |
|---|---|---|
| POSTIZ_INTEGRATION_BLUESKY | `jacorbello.bsky.social` | Bluesky (personal) |
| POSTIZ_INTEGRATION_BLUESKY_PLOTLENS | `plotlens.bsky.social` | Bluesky (brand — default for outreach) |
| POSTIZ_INTEGRATION_MASTODON | `@plotlens@mastodon.social` | Mastodon |

### 6. Update Workflow D if the channel needs platform-specific request shape

Most providers accept the default payload (see `[[postiz-public-api-conventions]]` memory or `docs/runbooks/postiz-failed-job-recovery.md`). Some need extras:

- **Reddit subreddit posts** need a subreddit name. Add a `settings.subreddit` field per-post inside the `posts[]` entry.
- **X with media** needs explicit media uploads via `POST /api/public/v1/upload` first.

If a per-channel payload tweak is needed, modify the `Postiz Create Post` HTTP node's `jsonBody` expression in n8n. Export the workflow JSON via the UI; commit to `apps/outreach-workflows/n8n/publish-dispatcher.json`; bump the version in the file.

### 7. Use it in approvals

When approving a draft from the Slack review notification (`outreach-review-notify` workflow's webhook form), paste the `POSTIZ_INTEGRATION_<CHANNEL>` value into the **"Approved destination"** field. Workflow C's CTE writes that into `publish_jobs.destination_account`, and Workflow D's Postiz Create Post node reads it into `integration.id`.

## Per-channel quirks (long-form)

### Reddit
- Comment replies = manual-only forever, per AC-4 of the original outreach design. Any subreddit, including r/PlotLens.
- Original posts to r/PlotLens via Postiz: blocked in Phase 2 — see "Deferred items" in `docs/superpowers/roadmaps/plotlens-outreach.md`.
- Manual posting via the Reddit web UI is the Phase 2 path.

### Bluesky
- "Identifier" prompted by Postiz = your Bluesky handle WITHOUT the `@` prefix (e.g., `plotlens.bsky.social`).
- Use an **app password**, not your main account password. App passwords are scoped and revocable.

### Mastodon
- The Postiz Mastodon provider reads `MASTODON_CLIENT_ID`, `MASTODON_CLIENT_SECRET`, `MASTODON_URL` from environment, NOT from the UI. These must be in Infisical AND in the deployment env before clicking "Add Channel".
- Scopes must be the granular form (`write:statuses`, `write:media`, `profile`). Mastodon rejects broad scopes even though they include the granular ones.

### X
- **Paid plan required for posting.** As of February 2023, X's Free developer tier is read-only. Posting requires the Basic plan ($100/month, 100 posts per 24h — sufficient for outreach) or Pro plan ($5000/month). Confirm before scheduling X work; the previous "1500 posts/month free" allowance no longer exists.
- Postiz uses **OAuth 1.0a** for X (not OAuth 2.0). When you create the X Developer app, enable "OAuth 1.0a User Authentication settings" and grab the **Consumer Keys** ("API Key" + "API Key Secret"). The OAuth 2.0 Client ID/Secret on the same app will NOT work — the Postiz X provider only reads `X_API_KEY` + `X_API_SECRET` (which are the 1.0a consumer keys).
- App permissions: Read + Write (or higher).
- App type: "Web App, Automated App or Bot".
- **Callback URL on the X app must be exactly:** `https://postiz.corbello.io/integrations/social/x`.
- Wiring once you have the keys: add `X_API_KEY` + `X_API_SECRET` to Infisical at PlotLens project (db72a923-…), env `dev`, path `/postiz`. Then add the two `secretKeyRef` env entries to `apps/postiz/base/postiz/deployment.yaml` mirroring the existing `MASTODON_*` block. ArgoCD reconciles within the next sync window; Postiz pod restart picks up the env vars.
- Tooltip caveat: Postiz's X tile shows "You will be logged in into your current account…" — this is informational. The OAuth flow uses your browser's current X session (`forceLogin: false`), so sign in to the brand X account first.
- The `made_with_ai` flag (in Postiz's X settings) defaults to `false`. PlotLens posts are all human-approved, so the default is fine.
- **No allow-list/deny-list in Postiz** to hide the X tile when env vars are missing. Clicking the tile while keys aren't configured returns `200 OK` with body `{"err":true}` (caught by the `try/catch` in `apps/backend/src/api/routes/integrations.controller.ts:225-245`) — the frontend renders this as a generic "Could not connect to the platform" toast.

### LinkedIn
- Marketing Developer Platform approval can take 1-2 weeks.
- Fallback if denied: use "Share on LinkedIn" only (posts as personal profile, not Company Page).
