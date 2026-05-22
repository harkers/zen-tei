#!/usr/bin/env bash
# scripts/install.sh — full TEI install on zen.
#
# Idempotent: re-running skips steps that are already done. After running,
# both TEI LaunchAgents are bootstrapped and serving on :8084 + :8085.
#
# Mirror of the recipe in CLAUDE.md "Install" section.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$HOME/llm/src/text-embeddings-inference"
BIN_DIR="$HOME/llm/bin"
HF_CACHE="$HOME/models/mlx"  # shared with mlx-broker; matches HF_HUB_CACHE override

echo "── 1/5 Rust toolchain ──"
if ! command -v rustup >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- \
        -y --default-toolchain stable --profile default
fi
# shellcheck disable=SC1090
source "$HOME/.cargo/env"
rustc --version
cargo --version

echo
echo "── 2/5 Clone + build TEI ──"
mkdir -p "$(dirname "$SRC_DIR")" "$BIN_DIR"
if [ ! -d "$SRC_DIR" ]; then
    git clone --depth=1 \
        https://github.com/huggingface/text-embeddings-inference.git \
        "$SRC_DIR"
fi
(cd "$SRC_DIR" && cargo install --path router --features metal)
ln -sf "$HOME/.cargo/bin/text-embeddings-router" "$BIN_DIR/text-embeddings-router"
"$BIN_DIR/text-embeddings-router" --version

echo
echo "── 3/5 Pull HF models into shared cache ──"
export HF_HUB_DISABLE_TELEMETRY=1
HF_CLI="$HOME/llm/podcast-env/bin/huggingface-cli"
if [ ! -x "$HF_CLI" ]; then
    HF_CLI="$(command -v huggingface-cli || true)"
fi
if [ -z "$HF_CLI" ]; then
    echo "  huggingface-cli not found in podcast-env or PATH;" >&2
    echo "  install via uv or pip, then re-run this step." >&2
    exit 1
fi
"$HF_CLI" download BAAI/bge-reranker-large
"$HF_CLI" download BAAI/bge-m3

echo
echo "── 4/5 Install LaunchAgents ──"
cp "$REPO_DIR/plist/com.tei.rerank.plist" "$HOME/Library/LaunchAgents/"
cp "$REPO_DIR/plist/com.tei.embed.plist"  "$HOME/Library/LaunchAgents/"
launchctl bootout "gui/$(id -u)/com.tei.rerank" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.tei.embed"  2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.tei.rerank.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.tei.embed.plist"

echo
echo "── 5/5 Kickstart (macOS Tahoe wrinkle — bootstrap alone doesn't fire RunAtLoad) ──"
launchctl kickstart "gui/$(id -u)/com.tei.rerank"
launchctl kickstart "gui/$(id -u)/com.tei.embed"

echo
echo "── Wait for both endpoints ──"
for port in 8084 8085; do
    for i in $(seq 1 30); do
        if curl -s -m 2 "http://127.0.0.1:${port}/health" > /dev/null 2>&1; then
            echo "  :$port ready after $((i * 2))s"
            break
        fi
        sleep 2
    done
done

echo
echo "── Done ──"
echo "Run ./scripts/verify.sh for a full smoke."
echo "Wire LiteLLM \`embed\` alias + Continue \`reranker\` per CLAUDE.md \"Wired into\" table."
echo "Cache used:        $HF_CACHE"
