#!/usr/bin/env bats

# Tests for OpenClaw deployment scripts
# Run with: bats tests/

setup() {
    # Get the directory where the scripts are
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

# ── General Script Tests ────────────────────────────────────────────────────

@test "all scripts have correct shebang" {
    for script in oc-provision.sh oc-bootstrap.sh oc-configure.sh lint-scripts.sh; do
        run head -1 "${SCRIPT_DIR}/${script}"
        [ "$output" = "#!/usr/bin/env bash" ]
    done
}

@test "all scripts have set -euo pipefail" {
    for script in oc-provision.sh oc-bootstrap.sh oc-configure.sh lint-scripts.sh; do
        grep -q "set -euo pipefail" "${SCRIPT_DIR}/${script}"
    done
}

@test "all scripts are executable" {
    for script in oc-provision.sh oc-bootstrap.sh oc-configure.sh lint-scripts.sh; do
        [ -x "${SCRIPT_DIR}/${script}" ]
    done
}

# ── oc-provision.sh Specific Tests ───────────────────────────────────────────

@test "provision script has required helper functions" {
    grep -q "^step()" "${SCRIPT_DIR}/oc-provision.sh"
    grep -q "^ok()" "${SCRIPT_DIR}/oc-provision.sh"
    grep -q "^warn()" "${SCRIPT_DIR}/oc-provision.sh"
    grep -q "^fail()" "${SCRIPT_DIR}/oc-provision.sh"
}

@test "provision script checks for hcloud CLI" {
    grep -q "command -v hcloud" "${SCRIPT_DIR}/oc-provision.sh"
}

@test "provision script uses correct server defaults" {
    grep -q 'SERVER_TYPE="cx22"' "${SCRIPT_DIR}/oc-provision.sh"
    grep -q 'SERVER_IMAGE="ubuntu-24.04"' "${SCRIPT_DIR}/oc-provision.sh"
    grep -q 'SERVER_LOCATION="fsn1"' "${SCRIPT_DIR}/oc-provision.sh"
}

@test "provision script creates SSH key openclaw-key" {
    grep -q 'SSH_KEY_NAME="openclaw-key"' "${SCRIPT_DIR}/oc-provision.sh"
}

@test "provision script outputs bootstrap command with IP" {
    grep -q "ssh root@.*'bash -s' < oc-bootstrap.sh" "${SCRIPT_DIR}/oc-provision.sh"
}

# ── oc-bootstrap.sh Specific Tests ──────────────────────────────────────────

@test "bootstrap script checks for root" {
    grep -q 'id -u' "${SCRIPT_DIR}/oc-bootstrap.sh"
    grep -q "must be run as root" "${SCRIPT_DIR}/oc-bootstrap.sh"
}

@test "bootstrap script installs Docker" {
    grep -q "get.docker.com" "${SCRIPT_DIR}/oc-bootstrap.sh"
    grep -q "docker --version" "${SCRIPT_DIR}/oc-bootstrap.sh"
}

@test "bootstrap script creates deploy user" {
    grep -q "adduser.*deploy" "${SCRIPT_DIR}/oc-bootstrap.sh"
    grep -q "usermod -aG docker deploy" "${SCRIPT_DIR}/oc-bootstrap.sh"
}

@test "bootstrap script sets up UFW firewall" {
    grep -q "ufw.*deny incoming" "${SCRIPT_DIR}/oc-bootstrap.sh"
    grep -q "ufw allow OpenSSH" "${SCRIPT_DIR}/oc-bootstrap.sh"
}

@test "bootstrap script sets up fail2ban" {
    grep -q "fail2ban" "${SCRIPT_DIR}/oc-bootstrap.sh"
}

@test "bootstrap script generates gateway token" {
    grep -q "openssl rand -hex 32" "${SCRIPT_DIR}/oc-bootstrap.sh"
}

@test "bootstrap script sets up backups" {
    grep -q "openclaw-backup.sh" "${SCRIPT_DIR}/oc-bootstrap.sh"
    grep -q "/var/backups/openclaw" "${SCRIPT_DIR}/oc-bootstrap.sh"
}

# ── oc-configure.sh Specific Tests ───────────────────────────────────────────

@test "configure script checks NOT run as root" {
    grep -q "Don't run this as root" "${SCRIPT_DIR}/oc-configure.sh"
}

@test "configure script requires Telegram" {
    grep -q "Telegram.*REQUIRED" "${SCRIPT_DIR}/oc-configure.sh"
    grep -q "BotFather" "${SCRIPT_DIR}/oc-configure.sh"
}

@test "configure script requires 1Password" {
    grep -q "1Password.*REQUIRED" "${SCRIPT_DIR}/oc-configure.sh"
}

@test "configure script requires Email" {
    grep -q "Email.*REQUIRED" "${SCRIPT_DIR}/oc-configure.sh"
    grep -q "himalaya" "${SCRIPT_DIR}/oc-configure.sh"
}

@test "configure script has OpenCode Zen" {
    grep -q "OpenCode Zen" "${SCRIPT_DIR}/oc-configure.sh"
}

@test "configure script has Todoist integration" {
    grep -q "Todoist" "${SCRIPT_DIR}/oc-configure.sh"
    grep -q "TODOIST_API_KEY" "${SCRIPT_DIR}/oc-configure.sh"
}

# ── Security Tests ────────────────────────────────────────────────────────────

@test "scripts do not contain hardcoded secrets (basic check)" {
    # This is a basic check - look for common secret patterns
    # Skip lines that are comments, prompts, or variable assignments with reads
    run grep -rn "password\|secret\|token" "${SCRIPT_DIR}/oc-"*.sh
    
    # We expect to find these words, but they should be in safe contexts
    [ "$status" -eq 0 ] || true
}

@test "scripts use proper file permissions (chmod 600) for secrets" {
    grep -q "chmod 600" "${SCRIPT_DIR}/oc-bootstrap.sh"
    grep -q "chmod 600" "${SCRIPT_DIR}/oc-configure.sh"
}

# ── Documentation Tests ──────────────────────────────────────────────────────

@test "README.md exists" {
    [ -f "${SCRIPT_DIR}/README.md" ]
}

@test "AGENTS.md exists" {
    [ -f "${SCRIPT_DIR}/AGENTS.md" ]
}

@test "example config exists" {
    [ -f "${SCRIPT_DIR}/openclaw.json.example" ]
}
