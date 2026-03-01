# HEARTBEAT.md

<!-- ═══════════════════════════════════════════════════════════════════════════
     🆕 ENHANCED: Complete rewrite with severity levels, rotating checks,
     delivery rules, self-health checks, and work queue integration
     ═══════════════════════════════════════════════════════════════════════════ -->

## 🔴🟡🟢 Alert Severity Levels

| Level | Emoji | Meaning | Delivery |
|-------|-------|---------|----------|
| 🔴 Urgent | Red | Needs attention NOW | Message immediately (even quiet hours) |
| 🟡 Important | Yellow | Should know soon | Message during active hours |
| 🟢 FYI | Green | Nice to know | Batch into daily digest or skip |

## Periodic Checks

### Always Check (Every Heartbeat)
1. **Calendar** — Events in next 2 hours
   - 🔴 if <30 min away and not acknowledged
   - 🟡 if <2h away

2. **Email** — Scan unread on both accounts
   - 🔴 if from known important contacts (attorneys, family)
   - 🟡 if from real humans (not newsletters/GitHub)
   - 🟢 GitHub notifications, marketing → skip alert

3. **Investigation Requests** — Check for patterns: `investigation|background check|due diligence|skip trace|locate`
   - 🟡 Whitelisted attorneys → auto-create case, notify Jeremy
   - 🔴 Unknown sender → ask Jeremy before proceeding

### Rotating Checks (Cycle Through Daily)

Pick 1-2 per heartbeat. Track last check time in state file.

| Check | Frequency | What to Look For |
|-------|-----------|------------------|
| **Homelab Health** | 2-3x/day | Proxmox node status, critical containers (redis, proxy) |
| **PlotLens Status** | 2-3x/day | Uptime Kuma monitors, any DOWN alerts |
| **GitHub Notifications** | 2-3x/day | PRs needing review, mentions, CI failures |
| **k3s Cluster** | 1-2x/day | Pod health, any CrashLoopBackOff |
| **Weather** | 1x/day (morning) | Only if outdoor plans on calendar |
| **react-leaflet-milsymbol** | 1x/day | New releases (blogwatcher scan), open issues/PRs, CI status |

#### Homelab Health Check
```bash
# Quick cluster check
ssh root@192.168.1.52 "pvesh get /cluster/resources --type node" 2>/dev/null
```
- 🔴 if any node offline
- 🟡 if critical container (redis, proxy, postgres) stopped
- 🟢 if non-critical container stopped

#### PlotLens Check
- Check Uptime Kuma monitors #17, #18, #19
- 🔴 if frontend DOWN
- 🟡 if API health check failing
- 🟢 SSL cert warnings (already known issue)

### Investigation Updates
- Check for emails containing case IDs (`INV-20\d{2}-\d{3}`)
- 🟡 Link to existing case, note new information
- Kick off supplemental investigation if significant

## 📋 Work Queue Check

Each heartbeat, check `memory/work-queue.json` for queued tasks:
- If queue has items and you have capacity → work on highest priority
- Update queue status (started/completed/blocked)
- Add new items you discover (bugs, docs to update, etc.)

## 🩺 Self-Health Check

Once per day, verify your own systems:
- [ ] Can read/write to memory files
- [ ] Gmail CLI responds
- [ ] Calendar CLI responds  
- [ ] Can reach homelab (ssh to 192.168.1.52)
- [ ] State files are valid JSON

If any fail, log in daily notes and alert 🟡.

## Delivery Rules

### By Severity
| Severity | Quiet Hours (21:30-06:30) | Active Hours |
|----------|---------------------------|--------------|
| 🔴 Urgent | Deliver immediately | Deliver immediately |
| 🟡 Important | Hold until morning | Deliver |
| 🟢 FYI | Hold for digest | Batch or skip |

### Message Batching
- If multiple 🟡 alerts, combine into one message
- Never send more than 1 unsolicited message per heartbeat
- Format: Start with highest severity, list others below

### Example Alert Format
```
🟡 Heads up:

• Calendar: "Dentist appointment" in 1h 45m
• Email: New message from Sarah Chen (attorney) — looks like a case request

Also checked: Homelab ✓ PlotLens ✓ (all healthy)
```

## State Tracking

Update `memory/heartbeat-state.json` after each cycle:

```json
{
  "lastHeartbeat": "2024-01-15T14:30:00Z",
  "checksPerformed": {
    "email": "2024-01-15T14:30:00Z",
    "calendar": "2024-01-15T14:30:00Z",
    "homelab": "2024-01-15T10:00:00Z",
    "plotlens": "2024-01-15T10:00:00Z",
    "github": "2024-01-15T06:00:00Z",
    "k3s": "2024-01-14T18:00:00Z",
    "weather": "2024-01-15T07:00:00Z",
    "selfHealth": "2024-01-15T07:00:00Z"
  },
  "pendingAlerts": [],
  "lastMessageSent": "2024-01-15T10:15:00Z",
  "consecutiveSilentBeats": 3
}
```

## Proactive Work (No Alert Needed)

During quiet heartbeats, you can:
- Review and organize memory files
- Update MEMORY.md with insights from recent daily logs
- Check git status on active projects
- Work items from work-queue.json
- Update documentation you maintain
- Commit and push your own changes

## Rules Summary

1. **Respect quiet hours** (21:30-06:30 CST) unless 🔴 urgent
2. **One message max** per heartbeat (batch if multiple alerts)
3. **Track everything** in state file
4. **Rotate checks** — don't hammer the same services every time
5. **Skip known issues** — SSL cert warnings on PlotLens API are expected
6. **Be useful or be quiet** — HEARTBEAT_OK is fine if nothing needs attention
