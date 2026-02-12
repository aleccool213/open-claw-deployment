# Alec's OpenClaw Setup

This is my opinionated deployment of [OpenClaw](https://github.com/openclaw/openclaw) that prioritizes **simplicity** and **value**. No overcomplicated orchestration, no vendor lock-in, just straightforward scripts that get OpenClaw running on a $5/month VPS.

## Philosophy

I believe in setups that are:
- **Simple to understand** — Plain bash scripts you can read and modify
- **Cheap to run** — $5-20/month total, not hundreds
- **Easy to maintain** — No complex tooling, just SSH and Docker
- **Secure by default** — Hardened from the start, not as an afterthought

If you want Kubernetes with 47 microservices, this isn't for you. If you want AI automation that just works without breaking the bank, read on.

## What is OpenClaw?

OpenClaw is an **AI agent gateway** that connects AI assistants (like Claude) to your real-world tools. Think of it as a bridge that lets AI:
- Send you Telegram messages
- Read and write emails on your behalf
- Manage your Notion databases
- Interact with any API you configure

Instead of copy-pasting between ChatGPT and your tools, OpenClaw lets AI take actions directly. It's particularly powerful for automation workflows and notifications.

## What These Scripts Do

This repo contains three main scripts that automate the entire deployment:

### 1. `oc-bootstrap.sh` — Server Setup (Run Once)
**What it does:** Takes a bare Ubuntu VPS and hardens it for production use.
- Creates a non-root user (`deploy`) for running services
- Configures SSH to use keys only (disables password login)
- Sets up a firewall (UFW) to block everything except SSH
- Installs fail2ban to prevent brute-force attacks
- Installs Docker for running OpenClaw in a container
- Sets up automatic security updates

**When to run:** Once, right after creating a fresh VPS. Run as `root`.

### 2. `oc-configure.sh` — OpenClaw Configuration
**What it does:** Installs and configures OpenClaw with your integrations.
- Prompts for API keys (OpenCode Zen, Telegram, etc.)
- Generates the OpenClaw configuration file
- Deploys OpenClaw as a Docker container
- Sets up email client (Himalaya) for IMAP/SMTP
- Configures the container to restart automatically

**When to run:** After bootstrap completes. Run as `deploy` user (not root).

### 3. `oc-load-secrets.sh` — 1Password Integration (Optional)
**What it does:** Pre-loads your API keys from 1Password so you don't have to type them manually.
- Connects to 1Password CLI
- Fetches credentials from your vault
- Exports them as environment variables
- Used before running `oc-configure.sh` for faster setup

**When to run:** Before `oc-configure.sh` if you have secrets in 1Password.

## Quick Start

Here's how to go from zero to running OpenClaw in about 10 minutes:

```bash
# Step 1: Create a VPS on Hetzner (requires hcloud CLI installed)
# This creates a $5/month server in their Finland datacenter
hcloud server create --name openclaw --type cx22 --image ubuntu-24.04 \
  --location fsn1 --ssh-key your-key

# Step 2: Harden the server (SSH as root, pipe in bootstrap script)
# This sets up security, creates 'deploy' user, installs Docker
ssh root@$(hcloud server ip openclaw) 'bash -s' < oc-bootstrap.sh

# Step 3a: (Optional) Pre-load secrets from 1Password
# If you have secrets in 1Password, load them now to avoid manual typing
source ./oc-load-secrets.sh

# Step 3b: Configure OpenClaw (SSH as 'deploy' user, pipe in config script)
# This installs OpenClaw, prompts for API keys, sets up integrations
ssh deploy@$(hcloud server ip openclaw) 'bash -s' < oc-configure.sh

# Step 4: Open an SSH tunnel to access the gateway
# OpenClaw only listens on localhost for security - tunnel to reach it
ssh -N -L 18789:127.0.0.1:18789 deploy@$(hcloud server ip openclaw)

# Step 5: Open your browser
# Go to http://localhost:18789 and start using OpenClaw
```

**That's it.** Your AI gateway is running, secured, and ready to use.

## Why I Built This

### The Value Proposition

Most "production-ready" AI deployments want you to spend $100-500/month on managed platforms. That's ridiculous for a personal AI gateway that mostly sits idle. Here's what I actually spend:

| Component | Monthly Cost |
|-----------|--------------|
| **Hetzner VPS** (cx22: 2 vCPU, 4GB RAM) | $5 |
| **OpenCode Zen API** (free tier + usage) | $0-15 |
| **Total** | **$5-20/month** |

**How I keep costs low:**
- **OpenCode Zen** gives you free access to Grok Code Fast 1 and GLM 4.7 during beta
- **Heartbeat tuning**: Changed from 30min to 2h intervals (75% fewer API calls)
- **No platform markup**: Direct to providers, no middleman fees
- **Efficient hosting**: Hetzner is 3-5x cheaper than AWS/GCP for equivalent specs

### The Simplicity Principle

**One VPS. Three scripts. That's it.**

I don't use:
- Kubernetes (overkill for a single container)
- Terraform (harder to debug than a bash script)
- Docker Compose (unnecessary abstraction layer)
- Configuration management tools (you have SSH)

Instead:
- Direct `docker run` commands you can understand
- Plain bash scripts you can edit in 5 minutes
- SSH tunnels instead of complex network setups
- Standard Linux tools everyone knows

### Security Without Complexity

I don't compromise on security, but I don't overcomplicate it either:

- **SSH hardening**: Keys only, no passwords, fail2ban watching for attacks
- **Network isolation**: Gateway only accessible via SSH tunnel (never exposed to internet)
- **Secret management**: 1Password integration for credentials (no plaintext files)
- **Firewall**: UFW blocks everything except SSH
- **Auto-updates**: Unattended-upgrades keeps the system patched

The threat model is simple: prevent unauthorized access, protect secrets, keep software updated. You don't need a security team for this.

## Architecture

```
┌─────────────────┐
│   Your Laptop   │
│  (SSH tunnel)   │
└────────┬────────┘
         │
         ▼
┌─────────────────┐     ┌─────────────────┐
│  Hetzner VPS    │────▶│  1Password      │
│  Ubuntu 24.04   │     │  (secrets)      │
│  - Docker       │     └─────────────────┘
│  - UFW firewall │
│  - fail2ban     │     ┌─────────────────┐
└────────┬────────┘────▶│  OpenCode Zen   │
         │              │  (AI models)    │
         ▼              └─────────────────┘
┌─────────────────┐
│ OpenClaw Gateway│     ┌─────────────────┐
│  - Telegram bot │────▶│  Telegram API   │
│  - Email (SMTP) │     └─────────────────┘
│  - Notion API   │
└─────────────────┘     ┌─────────────────┐
                        │  Gmail/Fastmail │
                        │  (IMAP/SMTP)    │
                        └─────────────────┘
```

## What You'll Need

The `oc-configure.sh` script will prompt you for these credentials. Here's what each one does:

### Required Integrations

1. **OpenCode Zen API key** ([get one here](https://opencodezen.com))
   - This is your AI model provider
   - Free tier includes Grok Code Fast 1 and GLM 4.7
   - OpenClaw uses this to power the AI agent

2. **Telegram bot token** (create via [@BotFather](https://t.me/botfather))
   - Lets OpenClaw send you Telegram messages
   - Main interface for notifications and interactions
   - Free to create and use

3. **1Password service account** ([setup guide](https://developer.1password.com/docs/service-accounts/))
   - OpenClaw stores integration secrets securely
   - Better than plaintext config files
   - Optional for initial setup, but recommended

4. **Email account with app password** (Gmail or Fastmail)
   - Lets OpenClaw read and send emails on your behalf
   - You'll need IMAP/SMTP access enabled
   - Use an app-specific password, not your main password

5. **Tailscale auth key** ([generate here](https://login.tailscale.com/admin/settings/keys))
   - Provides secure network access to your VPS
   - Better than exposing SSH to the internet
   - See "Generating a Tailscale Auth Key" section below

### Generating a Tailscale Auth Key

To create a reusable Tailscale auth key:

1. Visit https://login.tailscale.com/admin/settings/keys
2. Click "Generate auth key"
3. Enable "Reusable" option for deploying multiple servers
4. Optionally set an expiration (or leave as ephemeral for testing)
5. Copy the auth key (format: `tskey-auth-xxxxx`)
6. Store it in 1Password or provide it when prompted during configuration

### Optional Integrations

6. **Notion API key** ([create integration](https://www.notion.so/my-integrations))
   - Lets OpenClaw read/write Notion databases
   - Only needed if you use Notion
   - Can skip during setup and add later

## 1Password Integration (Optional but Worth It)

If you're like me and have dozens of API keys, manually typing them during setup gets old. The `oc-load-secrets.sh` script pulls everything from 1Password automatically.

### How to Set It Up

1. **Create a vault** in 1Password called `OpenClaw`
   - You can use a different name by setting `OP_VAULT` environment variable

2. **Add these items** to your vault (exact names matter):
   - **"OpenCode Zen API Key"** — Add field called `credential`
   - **"Telegram Bot Token"** — Add field called `credential`
   - **"1Password Service Account"** — Add field called `credential`
   - **"Tailscale Auth Key"** — Add field called `credential`
   - **"Notion API Key"** — Add field called `credential` (optional)
   - **"Email App Password"** — Add field called `password`

3. **Install 1Password CLI** — [Download here](https://developer.1password.com/docs/cli/get-started/)

4. **Authenticate** — Run `op signin` or set `OP_SERVICE_ACCOUNT_TOKEN`

### How to Use It

```bash
# Load all secrets into environment variables
source ./oc-load-secrets.sh

# Now run configure - it won't prompt you for any secrets
ssh deploy@$(hcloud server ip openclaw) 'bash -s' < oc-configure.sh
```

### Why Bother?

- **Faster setup** — No typing 6 API keys manually
- **Better security** — Secrets in 1Password, not shell history
- **Easy rotation** — Update in 1Password, reload script
- **Team sharing** — Share vault instead of Slack messages

## Repository Structure

```
.
├── oc-bootstrap.sh           # Server hardening and Docker setup
├── oc-configure.sh           # OpenClaw installation and config
├── oc-load-secrets.sh        # 1Password secret loader (optional)
├── openclaw.json.example     # Configuration template
├── run-tests.sh              # Full test suite (runs all checks)
├── lint-scripts.sh           # ShellCheck linter only
├── tests/                    # Bats integration tests
├── AGENTS.md                 # Detailed technical docs
└── .github/workflows/        # CI/CD pipeline
```

## Testing and Development

I include a solid test suite because bash scripts break easily. Before pushing changes, run:

```bash
# Run everything (what GitHub Actions runs)
./run-tests.sh
```

This runs:
- **ShellCheck** — Catches common bash mistakes (undefined variables, quoting issues)
- **Syntax validation** — Ensures scripts are valid bash
- **Permission checks** — Verifies scripts are executable
- **Bats tests** — Integration tests that verify actual functionality

If you just want to check your syntax quickly:

```bash
./lint-scripts.sh           # Fast: just runs ShellCheck
bash -n oc-bootstrap.sh     # Faster: just checks syntax
```

The test suite catches ~90% of issues before they hit production. Worth the 30 seconds.

## More Documentation

- **[AGENTS.md](AGENTS.md)** — Detailed technical guide with troubleshooting
- **[openclaw-hetzner-checklist.md](openclaw-hetzner-checklist.md)** — Step-by-step deployment checklist
- **[OpenClaw Docs](https://docs.openclaw.ai)** — Official OpenClaw documentation

## License

MIT — Do whatever you want with this.

---

## Final Thoughts

This setup reflects my belief that good infrastructure should be:
1. **Understandable** — If you can't explain it, you can't debug it
2. **Affordable** — Cloud bills shouldn't exceed your Netflix subscription
3. **Maintainable** — You should be able to fix it at 2am without Googling

I'm not saying this is the only way to run OpenClaw. If you need high availability, multi-region deployments, or enterprise compliance, you'll need something more complex. But for personal use or small teams? This is plenty.

Feel free to fork, modify, and adapt this to your needs. If you find bugs or have improvements, PRs are welcome.

— Alec
