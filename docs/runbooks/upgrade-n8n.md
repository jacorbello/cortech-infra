# Upgrade n8n (CT 112)

## Overview
n8n runs on CT 112 on cortech-node5, installed via npm/nvm.

## Upgrade Steps

1. **SSH to cortech-node5:**
   ```bash
   ssh root@192.168.1.80
   ```

2. **Update n8n package:**
   ```bash
   pct exec 112 -- bash -c 'source /root/.nvm/nvm.sh && npm update -g n8n'
   ```

3. **Restart n8n service:**
   ```bash
   pct exec 112 -- systemctl restart n8n
   ```

4. **Verify upgrade:**
   ```bash
   pct exec 112 -- systemctl status n8n
   ```

   Look for the version number in the output. Service should be `active (running)`.

## Quick One-Liner from cortech master

```bash
ssh root@192.168.1.80 "pct exec 112 -- bash -c 'source /root/.nvm/nvm.sh && npm update -g n8n' && pct exec 112 -- systemctl restart n8n && pct exec 112 -- systemctl status n8n"
```

## Rollback

If issues occur, install specific version:
```bash
pct exec 112 -- bash -c 'source /root/.nvm/nvm.sh && npm install -g n8n@<version>'
pct exec 112 -- systemctl restart n8n
```

## Notes
- n8n is accessible at https://n8n.corbello.io
- Service file: `/etc/systemd/system/n8n.service`
- Node.js managed via nvm at `/root/.nvm/`
