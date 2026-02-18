#!/usr/bin/env bash
# OpenClaw Health Monitor - Runs every 5 minutes via cron
# Sends email alerts on failure

set -euo pipefail

EMAIL="alec.brunelle@icloud.com"
LOG_FILE="/var/log/openclaw-monitor.log"
GATEWAY_URL="http://127.0.0.1:18789"

# Load environment variables
set -a; source ~/openclaw/.env; set +a

log() {
    echo "$(date -Iseconds) $1" >> "$LOG_FILE"
}

send_alert() {
    local subject="$1"
    local body="$2"
    log "ALERT: $subject"
    
    # Send via Telegram bot (more reliable than email)
    curl -sf "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=6441399804" \
        -d "text=[OpenClaw Alert] ${subject}%0A%0A${body}" \
        >/dev/null 2>&1 || log "Failed to send Telegram alert"
}

check_gateway() {
    # Check if gateway container is running
    if ! docker compose -f ~/openclaw/docker-compose.yml ps openclaw-gateway 2>/dev/null | grep -q "Up"; then
        return 1
    fi
    
    # Check if gateway responds to HTTP
    if ! curl -sf "${GATEWAY_URL}/" >/dev/null 2>&1; then
        return 2
    fi
    
    return 0
}

check_heartbeat() {
    # Check last heartbeat time (should be within 2h + buffer)
    local last_heartbeat
    last_heartbeat=$(docker compose -f ~/openclaw/docker-compose.yml logs --since=3h openclaw-gateway 2>/dev/null | grep -i "heartbeat" | tail -1 || true)
    
    if [[ -z "$last_heartbeat" ]]; then
        return 1
    fi
    return 0
}

# Main checks
ERRORS=()

if ! check_gateway; then
    ERRORS+=("Gateway not responding")
    
    # Try to restart
    log "Attempting gateway restart..."
    cd ~/openclaw && docker compose restart openclaw-gateway
    sleep 30
    
    if check_gateway; then
        ERRORS+=("(Auto-recovered after restart)")
    fi
fi

if ! check_heartbeat; then
    ERRORS+=("No heartbeat in last 3 hours")
fi

# Send alert if there are errors
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    BODY="Host: $(hostname)%0ATime: $(date)%0A%0AIssues:%0A"
    for err in "${ERRORS[@]}"; do
        BODY+="  - $err%0A"
    done
    
    send_alert "OpenClaw Health Check Failed" "$BODY"
else
    log "All checks passed"
fi

exit 0
