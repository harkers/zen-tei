#!/usr/bin/env bash
# scripts/uninstall.sh — stop + bootout all three TEI LaunchAgents and remove the plists.
#
# Preserves the binary (`~/.cargo/bin/text-embeddings-router`), the source clone
# (`~/llm/src/text-embeddings-inference/`), and the cached models. Re-run
# ./scripts/install.sh to bring everything back without re-downloading anything.
set -uo pipefail

for svc in com.tei.rerank com.tei.embed com.tei.watchdog; do
    launchctl bootout "gui/$(id -u)/$svc" 2>/dev/null && echo "bootout: $svc" \
        || echo "$svc: not loaded"
done

for plist in com.tei.rerank.plist com.tei.embed.plist com.tei.watchdog.plist; do
    if [ -f "$HOME/Library/LaunchAgents/$plist" ]; then
        rm -v "$HOME/Library/LaunchAgents/$plist"
    fi
done

echo
echo "Binary, source clone, and model cache preserved."
echo "Re-install: ./scripts/install.sh"
