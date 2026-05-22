#!/usr/bin/env bash
# scripts/watchdog.sh — continuous loop; check both TEI /health every 90 s.
#
# Runs as a long-lived process via com.tei.watchdog.plist (KeepAlive=true).
# Sleeping inside the loop avoids the macOS Tahoe StartInterval throttle that
# kills short-exit jobs before their next scheduled firing.
#
# Workaround for the macOS Tahoe launchd respawn throttle documented in
# CLAUDE.md "Known wrinkle". `launchctl kickstart` reliably forces respawn
# even when KeepAlive's auto-recovery has been throttled.
set -uo pipefail

LOG="$HOME/llm/logs/tei-watchdog.log"
INTERVAL=90

mkdir -p "$(dirname "$LOG")"

while true; do
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
    sleep "$INTERVAL"
done
