#!/usr/bin/env bash
# scripts/watchdog.sh — one pass through both TEI services; kickstart on dead /health.
#
# Invoked every 90 s by ~/Library/LaunchAgents/com.tei.watchdog.plist.
# Idempotent. Side-effect-free unless something is down.
#
# Workaround for the macOS Tahoe launchd respawn throttle documented in
# CLAUDE.md "Known wrinkle". `launchctl kickstart` reliably forces respawn
# even when KeepAlive's auto-recovery has been throttled.
set -uo pipefail

LOG="$HOME/llm/logs/tei-watchdog.log"
mkdir -p "$(dirname "$LOG")"
TS=$(date -Iseconds)

for entry in com.tei.rerank:8084 com.tei.embed:8085; do
    svc=${entry%:*}
    port=${entry#*:}
    if ! curl -s -m 3 -o /dev/null "http://127.0.0.1:${port}/health"; then
        echo "[${TS}] ${svc} on :${port} not responding — launchctl kickstart" >> "$LOG"
        launchctl kickstart "gui/$(id -u)/${svc}" >> "$LOG" 2>&1 || \
            echo "[${TS}]   kickstart failed: $?" >> "$LOG"
    fi
done
