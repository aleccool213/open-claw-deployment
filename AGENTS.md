# AGENTS.md — OpenClaw Hetzner Deployment

## Overview

This repository contains deployment scripts for running [OpenClaw](https://github.com/openclaw/openclaw) — an AI agent gateway — on a Hetzner VPS (~$5/month). Uses **OpenCode Zen** as the model provider (free tier available).

### What are Heartbeats?

Heartbeats are periodic check-ins OpenClaw does to maintain context and keep the agent "warm". By default they run every 30 minutes (48/day), which adds unnecessary cost. **Recommendation**: Set to `2h` (12/day) or disable entirely if you don't need continuous context.

## Quick Reference

| Task | Command |
|------|---------|
| Provision VPS | `hcloud server create --name openclaw --type cx22 --image ubuntu-24.04 --location fsn1 --ssh-key openclaw-key` |
| Bootstrap (root) | `ssh root@<IP> 'bash -s' < oc-bootstrap.sh` |
| Configure (deploy) | `ssh deploy@<IP> 'bash -s' < oc-configure.sh` |
| SSH to VPS | `ssh deploy@$(hcloud server ip openclaw)` |
| Open tunnel | `ssh -N -L 18789:127.0.0.1:18789 deploy@<IP>` |
| View logs | `ssh deploy@<IP> "cd ~/openclaw && docker compose logs -f openclaw-gateway"` |
| Restart gateway | `ssh deploy@<IP> "cd ~/openclaw && docker compose restart openclaw-gateway"` |
| Trigger backup | `sudo /usr/local/bin/openclaw-backup.sh` |

## Repository Structure

```
.
├── oc-bootstrap.sh              # Run once as root on fresh VPS
├── oc-configure.sh              # Run as deploy user to configure integrations
├── openclaw.json.example        # OpenClaw configuration template (OpenCode Zen)
├── openclaw-hetzner-checklist.md # Complete deployment checklist
└── oc-scripts.zip               # Original archive (extracted above)
```

## Development Guidelines

### Testing Requirements

**⚠️ CRITICAL RULE**: Never push changes to the repository unless all tests pass locally.

Before pushing any changes:

1. **Run all tests**:
   ```bash
   bats tests/*.bats
   ```

2. **Run integration checks**:
   ```bash
   # Check for hardcoded secrets
   # Check for TODO/FIXME markers
   # Verify shebangs and pipefail settings
   ./lint-scripts.sh
   ```

3. **Verify syntax**:
   ```bash
   bash -n oc-provision.sh
   bash -n oc-bootstrap.sh
   bash -n oc-configure.sh
   bash -n lint-scripts.sh
   ```

All 25 Bats tests must pass, and all integration checks must succeed before committing and pushing code. This ensures CI/CD pipelines remain green and deployments stay reliable.

## Deployment Architecture

### Network Security
- **Gateway port**: 18789 bound to `127.0.0.1` only (not exposed to internet)
- **Access method**: SSH tunnel from local machine → VPS → container
- **Firewall**: UFW allows only SSH (22), denies everything else
- **SSH hardening**: Key-only auth, root login disabled, fail2ban active

### User Model
- `root`: Used only for initial bootstrap, then disabled
- `deploy`: Non-root user for running OpenClaw (member of `docker` group)
- Container runs as UID 1000 (`node` user inside)

### Data Persistence
All durable state lives on the host, not in containers:
- Config: `/home/deploy/.openclaw/openclaw.json`
- Workspace: `/home/deploy/.openclaw/workspace/`
- Secrets: `/home/deploy/openclaw/.env` (chmod 600)
- Backups: `/var/backups/openclaw/` (daily at 03:00 UTC)

## Key Configuration Files

### Environment Variables (.env)
Located at `/home/deploy/openclaw/.env`:
```bash
OPENCLAW_IMAGE=openclaw:latest
OPENCLAW_GATEWAY_TOKEN=<32-byte-hex>  # Save this! Used for web UI auth
OPENCLAW_GATEWAY_BIND=lan
OPENCLAW_GATEWAY_PORT=18789
OPENCLAW_CONFIG_DIR=/home/deploy/.openclaw
OPENCLAW_WORKSPACE_DIR=/home/deploy/.openclaw/workspace
GOG_KEYRING_PASSWORD=<32-byte-hex>
XDG_CONFIG_HOME=/home/node/.openclaw

# Added by oc-configure.sh (REQUIRED):
OPENCODE_ZEN_API_KEY=ocz_...
TELEGRAM_BOT_TOKEN=123456:ABC-...
OP_SERVICE_ACCOUNT_TOKEN=ops_eyJ...

# Optional:
NOTION_API_KEY=ntn_...
```

### OpenClaw Config (openclaw.json)
Located at `/home/deploy/.openclaw/openclaw.json`:
- **Provider**: OpenCode Zen (free tier available)
- Primary model: Grok Code Fast 1 (FREE during beta) or GLM 4.7 (FREE)
- Heartbeat: Every **2 hours** (reduced from 30min to save costs)
- Model aliases: `grok`, `glm4`, `grokcode`, `flash`, `ds`

## Integration Details

### 1. OpenCode Zen (Required)
- Sign up: https://opencode.ai/zen (create account, add $20 balance)
- **FREE models** (during beta): Grok Code Fast 1, GLM 4.7, MiniMax M2.1, Big Pickle
- Curated models optimized for coding agents
- Pay-as-you-go: $20 minimum, auto-top-up at $5
- Get API key from dashboard and add to `.env`:
  ```bash
  OPENCODE_ZEN_API_KEY=ocz_...
  ```

### 2. Telegram Bot (REQUIRED)
- Create via @BotFather in Telegram
- Must be configured (script will fail without it)
- Pairing required: User sends `/start`, admin approves with pairing code
- Uses grammY with long-polling (works behind NAT/firewall)

### 3. 1Password (REQUIRED)
- Create Service Account at 1password.com → Developer → Service Accounts
- Grant access to dedicated "OpenClaw" vault only
- Service accounts cannot access Personal/Private vaults
- Use `op run` or `op inject` to avoid plaintext secrets
- **Required** for secure secret management (email passwords, API keys)

### 4. Email via Himalaya (REQUIRED)
- CLI email client for IMAP/SMTP
- Supports Gmail (App Password), Fastmail, Migadu
- Config: `~/.config/himalaya/config.toml`
- **Required** for notifications and agent interactions
- App password stored in 1Password vault for security

### 5. Notion (Optional)
- Create integration at notion.so/my-integrations
- Must explicitly share each page with the integration
- API version: 2025-09-03

## Local Development Aliases

Add to `~/.zshrc` or `~/.bashrc`:

```bash
export OPENCLAW_VPS="openclaw"
_oc_ip() { hcloud server ip "$OPENCLAW_VPS" 2>/dev/null; }

alias ocs='ssh deploy@$(_oc_ip)'
alias oct='ssh -f -N -L 18789:127.0.0.1:18789 deploy@$(_oc_ip) && echo "Tunnel open → http://127.0.0.1:18789/"'
alias octk='pkill -f "ssh -f -N -L 18789:127.0.0.1:18789" 2>/dev/null && echo "Tunnel closed"'
alias ocl='ssh deploy@$(_oc_ip) "cd ~/openclaw && docker compose logs -f --tail 100 openclaw-gateway"'
alias ocst='ssh deploy@$(_oc_ip) "cd ~/openclaw && docker compose ps openclaw-gateway"'
alias ocr='ssh deploy@$(_oc_ip) "cd ~/openclaw && docker compose restart openclaw-gateway"'
alias och='ssh deploy@$(_oc_ip) "curl -sf http://127.0.0.1:18789/ > /dev/null && echo ✅ || echo ❌"'
alias ocon='hcloud server poweron $OPENCLAW_VPS'
alias ocoff='hcloud server poweroff $OPENCLAW_VPS'
```

## Security Checklist

Before considering deployment complete:

- [ ] SSH key-only auth (password auth disabled)
- [ ] Root login disabled via SSH
- [ ] fail2ban active and monitoring SSH
- [ ] UFW enabled, only port 22 allowed
- [ ] Docker ports bound to 127.0.0.1 (not 0.0.0.0)
- [ ] `.env` file chmod 600, not in git
- [ ] No secrets in logs or shell history
- [ ] Container running as non-root (UID 1000)
- [ ] Automated backups tested manually
- [ ] Can SSH as deploy user from second terminal

## Troubleshooting

### Gateway not responding
```bash
ssh deploy@<IP>
cd ~/openclaw
docker compose logs -f openclaw-gateway
docker compose ps
```

### Can't SSH after hardening
- Verify key is in `/home/deploy/.ssh/authorized_keys`
- Check `/var/log/auth.log` on VPS
- Ensure `AllowUsers deploy` in `/etc/ssh/sshd_config`

### Telegram bot not responding
- Check token: `curl https://api.telegram.org/bot<TOKEN>/getMe`
- Verify IPv6 routing if on Hetzner: `curl -6 https://api.telegram.org`
- Check gateway logs for pairing requests

### 1Password not working
- Verify service account token: `op vault list`
- Ensure token has access to correct vault
- Service accounts can't access Personal vaults

## Maintenance

### Rotate gateway token
```bash
NEW_TOKEN=$(openssl rand -hex 32)
# Update .env with new OPENCLAW_GATEWAY_TOKEN
cd ~/openclaw && docker compose up -d --force-recreate openclaw-gateway
```

### Update OpenClaw
```bash
ssh deploy@<IP>
cd ~/openclaw
git pull --ff-only
docker compose build
docker compose up -d openclaw-gateway
```

### Restore from backup
```bash
# List available backups
ls -lh /var/backups/openclaw/

# Extract to restore
tar -xzf /var/backups/openclaw/openclaw-YYYY-MM-DD-HHMMSS.tar.gz -C /
# This restores /home/deploy/.openclaw/
```

## Cost Estimates

**With OpenCode Zen** (using free tier models + reduced heartbeats):

| Usage | Monthly Cost | Notes |
|-------|-------------|-------|
| Light (10 queries/day) | **$0-5** | Free models sufficient |
| Moderate (30 queries/day) | **$5-15** | Mix of free + paid models |
| Heavy (100 queries/day) | **$15-30** | Mostly paid models |

VPS: ~$5/month (Hetzner cx22)

**Total estimated**: $5-35/month (VPS + API usage)

## References

- OpenClaw: https://github.com/openclaw/openclaw
- Documentation: https://docs.openclaw.ai/platforms/hetzner
- Hetzner Cloud: https://console.hetzner.cloud
- OpenCode Zen: https://opencode.ai/zen (free models during beta)
