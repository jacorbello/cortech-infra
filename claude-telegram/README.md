# claude-telegram — Persistent Claude Code + Telegram host (PCT 126)

An always-on unprivileged LXC (`192.168.1.153`, on cortech master) that runs Claude Code
in Telegram-channel mode as a systemd service. A daily timer restarts the service; each
restart self-updates (`claude update`) and starts a fresh session.

## What's here

| File | Purpose |
|------|---------|
| `../pct/126-claude-telegram.conf` | LXC definition + `pct create` commands |
| `setup.sh` | Idempotent guest provisioning (run as root inside the LXC) |
| `claude-telegram.service` | The long-running service (`User=claude`, `Restart=always`, `ExecStartPre=claude update`) |
| `claude-telegram-restart.{service,timer}` | Daily `systemctl restart` |
| `.env.example` | Template for the telegram channel env |

## Dependencies installed by setup.sh

- `git`, `gh` (GitHub CLI), Node.js LTS
- **Bun** — hard dependency: the telegram plugin's MCP server launches via `command: bun` in its `.mcp.json`. The service will not start without it.
- Claude Code (official installer), symlinked to `/usr/local/bin/claude`

## Lifecycle / why this shape

- **System service, not `systemd --user`:** a `--user` unit needs `loginctl enable-linger` + a login session to survive reboots. A system unit with `User=claude` starts at boot reliably and still runs non-root.
- **Daily restart:** `claude-telegram-restart.timer` → `systemctl restart claude-telegram`. The unit's `ExecStartPre=-/usr/local/bin/claude update` runs on every (re)start, so the daily bounce both upgrades the CLI and resets the session.
- **Not k8s:** `claude update` mutates the filesystem; that's lost on pod restart. A persistent LXC rootfs is the right fit.

## Deploy

On the cortech master, with this repo's `claude-telegram/` available:

```bash
# 1. Create the LXC (see header of pct/126-claude-telegram.conf for the full command)
pct create 126 local:vztmpl/ubuntu-24.04-standard_24.04-1_amd64.tar.zst \
  --hostname claude-telegram --memory 2048 --swap 512 --cores 2 --rootfs local-lvm:16 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.1.153/24,gw=192.168.1.1,firewall=1 \
  --unprivileged 1 --features nesting=1,keyctl=1 --ostype ubuntu --start 0
pct start 126

# 2. Push this dir into the guest and run setup
for f in setup.sh .env.example claude-telegram.service \
         claude-telegram-restart.service claude-telegram-restart.timer; do
  pct push 126 "claude-telegram/$f" "/root/$f"
done
pct exec 126 -- bash /root/setup.sh
```

## One-time interactive steps (not scriptable)

`setup.sh` installs the toolchain, the plugin, the allowlist, and the bot token. What's
left needs a human:

> ⚠️ **Only one host may poll a bot token at a time** — Telegram allows a single
> `getUpdates` per token. Stop the old poller (the WSL `tgc` session) *before* starting
> this service, or both will flap.

1. **Login (subscription token)** — needs a TTY, so use `ssh -t`:
   ```bash
   ssh -t CORTECH "pct exec 126 -- sudo -iu claude claude setup-token"
   ```
   `setup-token` does **not** persist a credential — it prints a token. Write it into the
   auth env file (the unit injects it via `EnvironmentFile`). Hidden prompt, never echoed:
   ```bash
   ssh -t CORTECH "pct exec 126 -- bash -c 'read -rsp \"token: \" T; echo; printf \"CLAUDE_CODE_OAUTH_TOKEN=%s\n\" \"\$T\" > /etc/claude-telegram/claude.env; chmod 600 /etc/claude-telegram/claude.env'"
   ```
2. **Stop the WSL `tgc` session**, then start the service (as root in the LXC):
   ```bash
   systemctl enable --now claude-telegram.service
   ```
   DM `@CorbelloBot` from the allowlisted account → Claude replies.

## Headless gotchas (already handled in setup.sh / the unit)

- **PTY required.** `claude` drops to non-interactive `--print` mode when stdout isn't a TTY
  and exits immediately. The unit wraps it in `script -qec "…" /dev/null` to allocate a PTY.
- **Onboarding + folder-trust prompts block headless.** Pre-seeded in `/home/claude/.claude.json`
  (`hasCompletedOnboarding`, and a `projects[~/telegram-claude]` entry with
  `hasTrustDialogAccepted` / `hasCompletedProjectOnboarding`). Without these the service parks
  forever at a prompt with no way to answer.
- **Auth is env-var, not a stored credential.** `CLAUDE_CODE_OAUTH_TOKEN` lives in
  `/etc/claude-telegram/claude.env` (root `0600`); systemd reads it as root before dropping to
  `User=claude`.
- **Plugin marketplace install** is done by cloning the repo manually + `claude plugin install`
  (claude's own `marketplace add` crashes in the LXC). See `setup.sh`.

## Make the bot smarter (GitHub access + local repos)

`setup.sh` sets the git identity, creates `~/repos`, and installs the bot's operating
instructions (`claude-home-CLAUDE.md` → `~/.claude/CLAUDE.md`, always-loaded user memory with
the dev conventions + homelab orientation). Two steps need a human, then I clone the repos:

1. **Authenticate gh** (interactive, one-time; needs a TTY):
   ```bash
   ssh -t CORTECH "pct exec 126 -- sudo -iu claude gh auth login"    # GitHub.com · HTTPS · web/device flow
   ssh CORTECH "pct exec 126 -- sudo -iu claude gh auth setup-git"   # gh as git credential helper for HTTPS push
   ```
   Persists in `/home/claude/.config/gh/`, survives reboots.
2. **Clone the mapped repos** into `~/repos` (per `~/telegram-claude/CLAUDE.md`):
   ```bash
   for r in Family-Friendly-Inc/plotlens Family-Friendly-Inc/UnityHOA \
            jacorbello/cortech-infra jacorbello/klvtool jacorbello/options-trading; do
     pct exec 126 -- sudo -iu claude gh repo clone "$r" "/home/claude/repos/${r##*/}"
   done
   ```
3. **Restart** so the running session reloads the new user memory:
   `systemctl restart claude-telegram` (in-flight sessions don't pick up memory changes live).

## Ops

```bash
pct exec 126 -- systemctl status claude-telegram
pct exec 126 -- journalctl -u claude-telegram -n 50 -f
pct exec 126 -- systemctl list-timers '*claude-telegram*'
pct exec 126 -- systemctl restart claude-telegram      # manual update + fresh session
```

## Notes

- **Backups:** `/home/claude/.claude/` holds the login credential and the channel `.env`. Losing it means re-running `claude setup-token` and re-writing the token.
- Var names in `.env` (`TELEGRAM_BOT_TOKEN`, optional `TELEGRAM_CHAT_ID`) should be confirmed against the telegram plugin's own README.
