#!/usr/bin/env bash
# scripts/lint.sh — local lint pass: shellcheck on scripts, plutil on plists.
#
# Run before committing changes that touch scripts/ or plist/. Exits non-zero
# on any failure so a future pre-commit hook (or CI in Phase B) can gate.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
FAIL=0

echo "── shellcheck scripts/*.sh ──"
if ! command -v shellcheck >/dev/null 2>&1; then
    echo "  shellcheck not found; brew install shellcheck" >&2
    exit 2
fi
for f in scripts/*.sh; do
    if shellcheck "$f"; then
        echo "  ✓ $f"
    else
        FAIL=$((FAIL + 1))
    fi
done

echo
echo "── plutil -lint plist/*.plist ──"
for f in plist/*.plist; do
    if plutil -lint "$f" >/dev/null; then
        echo "  ✓ $f"
    else
        plutil -lint "$f"
        FAIL=$((FAIL + 1))
    fi
done

echo
if [ "$FAIL" -eq 0 ]; then
    echo "═════ lint clean ═════"
    exit 0
else
    echo "═════ lint failed: $FAIL files ═════" >&2
    exit 1
fi
