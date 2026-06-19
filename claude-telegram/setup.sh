#!/usr/bin/env bash
# Provision the Claude Code + Telegram LXC (PCT 126). Idempotent; run as root inside the guest.
# Expects the three unit files pushed alongside it (see pct/126-claude-telegram.conf post-create).
# Stops short of the one-time interactive login — see README.md.
set -Eeuo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

echo "==> Base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl git ca-certificates gnupg sudo unzip

echo "==> GitHub CLI (gh)"
if ! command -v gh >/dev/null; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
  chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
  apt-get update
  apt-get install -y gh
fi

echo "==> Node.js LTS (NodeSource)"
if ! command -v node >/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
  apt-get install -y nodejs
fi

echo "==> claude user + working dir"
id claude >/dev/null 2>&1 || useradd -m -s /bin/bash claude
sudo -u claude mkdir -p /home/claude/telegram-claude

echo "==> Bun (hard dependency: the telegram plugin's MCP server launches via 'command: bun')"
if [ ! -x /home/claude/.bun/bin/bun ]; then
  sudo -iu claude bash -c 'curl -fsSL https://bun.sh/install | bash'   # -i so $HOME=/home/claude
fi
ln -sf /home/claude/.bun/bin/bun /usr/local/bin/bun
/usr/local/bin/bun --version || echo "  (verify the installed bun path if this failed)"

echo "==> Claude Code (installed as the claude user, symlinked into PATH)"
if [ ! -x /home/claude/.local/bin/claude ]; then
  sudo -iu claude bash -c 'curl -fsSL https://claude.ai/install.sh | bash'   # -i so $HOME=/home/claude
fi
# ponytail: symlink the per-user install so the unit's /usr/local/bin/claude is stable;
# `claude update` (run as the claude user) updates the target in place, symlink stays valid.
ln -sf /home/claude/.local/bin/claude /usr/local/bin/claude
/usr/local/bin/claude --version || echo "  (verify the installed claude path if this failed)"

echo "==> Telegram channel env (the plugin reads ~/.claude/channels/telegram/.env, mode 0600)"
CHAN_DIR=/home/claude/.claude/channels/telegram
sudo -u claude mkdir -p "$CHAN_DIR"
chmod 700 "$CHAN_DIR"
# Copy as root (template lives in root-owned $HERE), but own the result as claude.
[ -f "$CHAN_DIR/.env" ] || install -o claude -g claude -m 600 "$HERE/.env.example" "$CHAN_DIR/.env"

# Pre-seed the DM allowlist so the bot answers without an interactive pairing step.
# 8781423571 = the only allowed Telegram user id (Jeremy). Edit allowFrom to change.
if [ ! -f "$CHAN_DIR/access.json" ]; then
  # cat > (not install /dev/stdin — /dev/stdin isn't readable under install in an unpriv LXC)
  cat > "$CHAN_DIR/access.json" <<'JSON'
{"dmPolicy":"allowlist","allowFrom":["8781423571"],"groups":{},"pending":{}}
JSON
  chown claude:claude "$CHAN_DIR/access.json"; chmod 644 "$CHAN_DIR/access.json"
fi

echo "==> Telegram plugin (official marketplace)"
# `claude plugin marketplace add` shells out to git via a Node wrapper that dies with
# ERR_STREAM_PREMATURE_CLOSE in this LXC, even though plain `git clone` works. So we clone
# the marketplace ourselves, register it, then `claude plugin install` copies it locally.
PLUGINS=/home/claude/.claude/plugins
MKT="$PLUGINS/marketplaces/claude-plugins-official"
if [ ! -d "$MKT" ]; then
  sudo -u claude mkdir -p "$PLUGINS/marketplaces"
  sudo -iu claude git clone --depth 1 https://github.com/anthropics/claude-plugins-official.git "$MKT"
  cat > "$PLUGINS/known_marketplaces.json" <<JSON
{"claude-plugins-official":{"source":{"source":"github","repo":"anthropics/claude-plugins-official"},"installLocation":"$MKT"}}
JSON
  chown claude:claude "$PLUGINS/known_marketplaces.json"; chmod 644 "$PLUGINS/known_marketplaces.json"
fi
sudo -iu claude env PATH=/usr/local/bin:/home/claude/.bun/bin:/usr/bin:/bin \
  claude plugin install telegram@claude-plugins-official   # writes settings.json + enables it

echo "==> Pre-accept onboarding + folder trust (headless claude blocks on these prompts otherwise)"
# Under systemd there's no TTY to answer claude's first-run onboarding or the "trust this folder?"
# dialog — both must be pre-seeded in ~/.claude.json or the service parks forever at the prompt.
cat > /tmp/claude-headless-seed.js <<'JS'
const fs = require('fs');
const f = process.env.HOME + '/.claude.json';
let d = {};
try { d = JSON.parse(fs.readFileSync(f, 'utf8')); } catch (e) {}
d.hasCompletedOnboarding = true;
if (!d.theme) d.theme = 'dark';
const dir = process.env.HOME + '/telegram-claude';
d.projects = d.projects || {};
d.projects[dir] = Object.assign({}, d.projects[dir], {
  hasTrustDialogAccepted: true,
  hasCompletedProjectOnboarding: true,
  hasClaudeMdExternalIncludesApproved: true,
  hasClaudeMdExternalIncludesWarningShown: true,
});
fs.writeFileSync(f, JSON.stringify(d, null, 2));
console.log('seeded onboarding + trust for', dir);
JS
sudo -iu claude node /tmp/claude-headless-seed.js

echo "==> Claude auth env file (populated interactively post-setup; required by the unit)"
install -d -m 700 /etc/claude-telegram
# CLAUDE_CODE_OAUTH_TOKEN goes here after `claude setup-token`. Empty placeholder so the unit's
# required EnvironmentFile exists; service stays down until the real token is written in.
[ -f /etc/claude-telegram/claude.env ] || install -m 600 /dev/null /etc/claude-telegram/claude.env

echo "==> systemd units"
install -m 644 "$HERE/claude-telegram.service"         /etc/systemd/system/
install -m 644 "$HERE/claude-telegram-restart.service" /etc/systemd/system/
install -m 644 "$HERE/claude-telegram-restart.timer"   /etc/systemd/system/
systemctl daemon-reload
systemctl enable claude-telegram-restart.timer

cat <<'EOF'

==> Base setup done. Remaining ONE-TIME interactive steps (run as the claude user):

  sudo -u claude -i
  claude setup-token        # subscription OAuth login; credential persists in ~/.claude/

  # Install / confirm the telegram plugin, then verify it runs:
  cd ~/telegram-claude
  claude --channels plugin:telegram@claude-plugins-official   # Ctrl-C once it's listening

Then, as root:
  - Put the BotFather token into Infisical (dev), then write it into the channel env:
      /home/claude/.claude/channels/telegram/.env   (owned by claude, mode 0600)
  - systemctl enable --now claude-telegram.service
  - systemctl status claude-telegram
EOF
