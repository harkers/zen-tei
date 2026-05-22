# TEI rerank + embed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy two HuggingFace TEI (Text Embeddings Inference) processes on zen — bge-reranker-large on :8084 and bge-m3 on :8085 — both built from Rust source with Metal acceleration, bound to the tailnet, supervised by LaunchAgents, wired into Continue (reranker) and LiteLLM (embed alias).

**Architecture:** TEI built once via `cargo install --features metal`. Two single-model TEI processes, separate LaunchAgents and logs, mirroring the existing `com.lmstudio.server` LaunchAgent pattern. Continue's reranker switches from `llm` to `huggingface-tei` direct-to-:8084. LiteLLM's `embed` alias swaps its OpenAI-style upstream from LM Studio's :1234 to TEI's :8085 (transparent to Continue's `embeddingsProvider`). LM Studio's nomic-embed LaunchAgent retires.

**Tech Stack:** Rust (rustup + cargo), HuggingFace TEI (`text-embeddings-router`), Apple Silicon Metal, macOS LaunchAgents, LiteLLM proxy, Continue VS Code extension.

**Companion spec:** [`docs/superpowers/specs/2026-05-21-tei-rerank-embed-design.md`](../specs/2026-05-21-tei-rerank-embed-design.md).

---

## File structure (created or modified)

| File | Role | Created/Modified |
|---|---|---|
| `04-clients/tei-rerank-launch.sh` | Launch script for rerank server (telemetry-off env + exec router) | Create |
| `04-clients/tei-embed-launch.sh` | Same shape for embed server | Create |
| `04-clients/com.tei.rerank.plist` | LaunchAgent for rerank | Create |
| `04-clients/com.tei.embed.plist` | LaunchAgent for embed | Create |
| `04-clients/CLAUDE.md` | Phase 4 doc — add "TEI rerank + embed" section, note LM Studio nomic deprecation | Modify |
| `04-clients/continue-config.json` | Continue config template — reranker stanza changes from `llm` to `huggingface-tei` | Modify |
| `03-router/litellm.yaml` | LiteLLM router — `embed` alias backend swap from LM Studio to TEI | Modify |
| `~/.continue/config.json` | Runtime mirror of `04-clients/continue-config.json` | Modify (deployed copy) |
| `~/llm/configs/litellm.yaml` | Runtime mirror of `03-router/litellm.yaml` | Modify (deployed copy) |
| `~/llm/bin/tei-rerank-launch.sh` | Installed copy of the rerank launcher | Install |
| `~/llm/bin/tei-embed-launch.sh` | Installed copy of the embed launcher | Install |
| `~/Library/LaunchAgents/com.tei.rerank.plist` | Installed LaunchAgent | Install |
| `~/Library/LaunchAgents/com.tei.embed.plist` | Installed LaunchAgent | Install |
| `~/llm/src/text-embeddings-inference/` | Source clone | External (not in repo) |
| `~/.cargo/bin/text-embeddings-router` | Built TEI binary | External |
| `~/.cache/huggingface/hub/models--BAAI--bge-reranker-large/` | Rerank model | External (~1.1 GB) |
| `~/.cache/huggingface/hub/models--BAAI--bge-m3/` | Embed model | External (~2.3 GB) |

The repo tracks the source of truth in `04-clients/` and `03-router/`; runtime copies under `~/llm/` and `~/Library/LaunchAgents/` are deploy-from-repo.

---

## Task 1: Install Rust toolchain

**Files:**
- External: `~/.cargo/`, `~/.rustup/` (created by installer; not in repo)

This task is the only one in the plan that runs an interactive installer. `rustup-init` defaults are fine (stable toolchain, default profile, modify PATH in shell init files). No sudo required — it's a per-user install.

- [ ] **Step 1: Check Rust isn't already installed**

```bash
which rustup cargo rustc 2>/dev/null || echo "(none — proceed to install)"
```

Expected: prints "(none — proceed to install)". If rustup IS present, skip to Step 4.

- [ ] **Step 2: Install rustup**

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile default
```

Expected: ~30 s download + install; ends with "Rust is installed now. Great!". Disk usage ~1.5 GB under `~/.rustup/`.

- [ ] **Step 3: Make `cargo` discoverable in this shell**

```bash
source "$HOME/.cargo/env"
```

Expected: silent. `~/.cargo/bin` is now on PATH.

- [ ] **Step 4: Verify versions**

```bash
rustc --version && cargo --version
```

Expected: both report a `1.x.x` stable build dated within the last 12 months.

- [ ] **Step 5: No commit needed — toolchain lives outside the repo**

Move on to Task 2.

---

## Task 2: Clone and build TEI with Metal feature

**Files:**
- External: `~/llm/src/text-embeddings-inference/` (clone)
- External: `~/.cargo/bin/text-embeddings-router` (built binary)
- External: `~/llm/bin/text-embeddings-router` (symlink)

- [ ] **Step 1: Pre-create directory + clone**

```bash
mkdir -p ~/llm/src ~/llm/bin
git clone --depth=1 https://github.com/huggingface/text-embeddings-inference.git ~/llm/src/text-embeddings-inference
```

Expected: clone completes; HEAD on `main`. Size ~50 MB.

- [ ] **Step 2: Build the router with the Metal feature**

```bash
cd ~/llm/src/text-embeddings-inference
cargo install --path router --features metal
```

Expected: 5–10 minute compile. Final line: `Installed package \`text-embeddings-router v...\``. Binary lands at `~/.cargo/bin/text-embeddings-router`.

**If the build fails with a Metal-related error** (rare but possible on early Tahoe), retry without the feature: `cargo install --path router`. CPU-only build still works — note the regression and move on; bge-reranker-large on CPU is ~200–500 ms per rerank, still ~10× faster than the LLM reranker.

- [ ] **Step 3: Symlink the binary into ~/llm/bin**

```bash
ln -sf "$HOME/.cargo/bin/text-embeddings-router" ~/llm/bin/text-embeddings-router
```

Expected: silent.

- [ ] **Step 4: Verify the binary runs**

```bash
~/llm/bin/text-embeddings-router --version
```

Expected: prints `text-embeddings-router 1.x.x` (or similar).

- [ ] **Step 5: No commit needed — binary lives outside the repo**

---

## Task 3: Pre-pull both HF models

**Files:**
- External: `~/.cache/huggingface/hub/models--BAAI--bge-reranker-large/` (~1.1 GB)
- External: `~/.cache/huggingface/hub/models--BAAI--bge-m3/` (~2.3 GB)

Pre-pulling lets us catch any HF errors before the LaunchAgents try to load. TEI would pull on first launch anyway, but blocking startup on a 3.4 GB download is bad UX.

- [ ] **Step 1: Pull the rerank model**

```bash
export HF_HUB_DISABLE_TELEMETRY=1
~/llm/podcast-env/bin/huggingface-cli download BAAI/bge-reranker-large
```

Expected: progress bars, ~2–4 min. Returns the local snapshot path on success.

- [ ] **Step 2: Pull the embed model**

```bash
export HF_HUB_DISABLE_TELEMETRY=1
~/llm/podcast-env/bin/huggingface-cli download BAAI/bge-m3
```

Expected: progress bars, ~4–8 min.

- [ ] **Step 3: Verify both models on disk**

```bash
ls -la ~/.cache/huggingface/hub/models--BAAI--bge-reranker-large/snapshots/*/ | head -10
ls -la ~/.cache/huggingface/hub/models--BAAI--bge-m3/snapshots/*/ | head -10
```

Expected: both directories show `config.json`, `tokenizer*`, and `model.safetensors` (or sharded `model-*.safetensors`).

- [ ] **Step 4: No commit needed — models live in HF cache**

---

## Task 4: Foreground smoke-test the rerank server

**Files:** none

- [ ] **Step 1: Start rerank in the foreground (separate terminal works too)**

```bash
HF_HUB_DISABLE_TELEMETRY=1 DO_NOT_TRACK=true ANONYMIZED_TELEMETRY=false \
  ~/llm/bin/text-embeddings-router \
    --model-id BAAI/bge-reranker-large \
    --hostname 0.0.0.0 \
    --port 8084 &
TEI_RERANK_PID=$!
sleep 8  # warmup
```

Expected: logs show "Ready" within ~5 s, "Listening on 0.0.0.0:8084".

- [ ] **Step 2: Hit `/rerank` with three texts; expect the middle one wins**

```bash
curl -s -X POST http://127.0.0.1:8084/rerank \
  -H "Content-Type: application/json" \
  -d '{"query":"how do I add an alias to mlx-broker",
       "texts":["unrelated about sparse bundles",
                "add alias to mlx-broker yaml under aliases",
                "git commit style"]}' | python3 -m json.tool
```

Expected: JSON array of `{index, score}` objects ordered by descending score. `index: 1` (the middle text — "add alias to mlx-broker yaml under aliases") should have the highest score.

- [ ] **Step 3: Verify tailnet bind by hitting via the Tailscale IP**

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://100.82.76.20:8084/health
```

Expected: `HTTP 200`.

- [ ] **Step 4: Stop the foreground server**

```bash
kill $TEI_RERANK_PID
wait $TEI_RERANK_PID 2>/dev/null
```

- [ ] **Step 5: No commit needed — smoke only**

---

## Task 5: Foreground smoke-test the embed server

**Files:** none

- [ ] **Step 1: Start embed in the foreground**

```bash
HF_HUB_DISABLE_TELEMETRY=1 DO_NOT_TRACK=true ANONYMIZED_TELEMETRY=false \
  ~/llm/bin/text-embeddings-router \
    --model-id BAAI/bge-m3 \
    --hostname 0.0.0.0 \
    --port 8085 &
TEI_EMBED_PID=$!
sleep 12  # bge-m3 is bigger, slower to warm
```

Expected: "Ready" + "Listening on 0.0.0.0:8085" within ~10 s.

- [ ] **Step 2: Hit `/embed` directly**

```bash
curl -s -X POST http://127.0.0.1:8085/embed \
  -H "Content-Type: application/json" \
  -d '{"inputs":["hello world"]}' \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('dim:', len(d[0])); print('first 5:', d[0][:5])"
```

Expected: `dim: 1024` and 5 floats.

- [ ] **Step 3: Hit the OpenAI-compatible endpoint (matches LiteLLM's wiring)**

```bash
curl -s -X POST http://127.0.0.1:8085/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"model":"any","input":"hello"}' \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('dim:', len(d['data'][0]['embedding']))"
```

Expected: `dim: 1024`.

- [ ] **Step 4: Stop the foreground server**

```bash
kill $TEI_EMBED_PID
wait $TEI_EMBED_PID 2>/dev/null
```

- [ ] **Step 5: No commit needed — smoke only**

---

## Task 6: Write the rerank launcher + LaunchAgent (repo-side)

**Files:**
- Create: `04-clients/tei-rerank-launch.sh`
- Create: `04-clients/com.tei.rerank.plist`

- [ ] **Step 1: Write the rerank launcher**

Create `04-clients/tei-rerank-launch.sh`:

```bash
#!/usr/bin/env bash
# 04-clients/tei-rerank-launch.sh — boot-time startup for the TEI rerank server.
# Started by ~/Library/LaunchAgents/com.tei.rerank.plist on user login.
# Idempotent: KeepAlive in the plist will respawn if killed.

set -euo pipefail

# Make sure cargo's bin is on PATH (TEI binary is symlinked into ~/llm/bin
# but we keep ~/.cargo/bin for fallback if the symlink is missing).
export PATH="$HOME/llm/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# Telemetry off — non-negotiable per macbookm5promax conventions.
export HF_HUB_DISABLE_TELEMETRY=1
export DO_NOT_TRACK=true
export ANONYMIZED_TELEMETRY=false

LOG_DIR="$HOME/llm/logs"
mkdir -p "$LOG_DIR"

# Per macbookm5promax convention: bind 0.0.0.0 (tailnet-reachable).
# Egress is gated upstream by pfSense + Little Snitch.
exec ~/llm/bin/text-embeddings-router \
    --model-id BAAI/bge-reranker-large \
    --hostname 0.0.0.0 \
    --port 8084
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x 04-clients/tei-rerank-launch.sh
```

- [ ] **Step 3: Write the rerank LaunchAgent plist**

Create `04-clients/com.tei.rerank.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.tei.rerank</string>

    <key>ProgramArguments</key>
    <array>
        <string>/Users/stu/llm/bin/tei-rerank-launch.sh</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
        <key>Crashed</key>
        <true/>
    </dict>

    <key>StandardOutPath</key>
    <string>/Users/stu/llm/logs/tei-rerank.out.log</string>

    <key>StandardErrorPath</key>
    <string>/Users/stu/llm/logs/tei-rerank.err.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>/Users/stu</string>
    </dict>
</dict>
</plist>
```

- [ ] **Step 4: Validate the plist XML**

```bash
plutil -lint 04-clients/com.tei.rerank.plist
```

Expected: `OK`.

- [ ] **Step 5: Commit**

```bash
git add 04-clients/tei-rerank-launch.sh 04-clients/com.tei.rerank.plist
git commit -m "$(cat <<'EOF'
phase-4(tei): rerank launcher + LaunchAgent

Boots BAAI/bge-reranker-large under text-embeddings-router on
0.0.0.0:8084. KeepAlive on crash (Crashed=true, SuccessfulExit=false).
Telemetry env vars set per project convention; PATH plus ~/llm/bin
+ ~/.cargo/bin so the router symlink resolves.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Write the embed launcher + LaunchAgent (repo-side)

**Files:**
- Create: `04-clients/tei-embed-launch.sh`
- Create: `04-clients/com.tei.embed.plist`

- [ ] **Step 1: Write the embed launcher**

Create `04-clients/tei-embed-launch.sh`:

```bash
#!/usr/bin/env bash
# 04-clients/tei-embed-launch.sh — boot-time startup for the TEI embed server.
# Started by ~/Library/LaunchAgents/com.tei.embed.plist on user login.
# Idempotent: KeepAlive in the plist will respawn if killed.

set -euo pipefail

export PATH="$HOME/llm/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

export HF_HUB_DISABLE_TELEMETRY=1
export DO_NOT_TRACK=true
export ANONYMIZED_TELEMETRY=false

LOG_DIR="$HOME/llm/logs"
mkdir -p "$LOG_DIR"

exec ~/llm/bin/text-embeddings-router \
    --model-id BAAI/bge-m3 \
    --hostname 0.0.0.0 \
    --port 8085
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x 04-clients/tei-embed-launch.sh
```

- [ ] **Step 3: Write the embed LaunchAgent plist**

Create `04-clients/com.tei.embed.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.tei.embed</string>

    <key>ProgramArguments</key>
    <array>
        <string>/Users/stu/llm/bin/tei-embed-launch.sh</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
        <key>Crashed</key>
        <true/>
    </dict>

    <key>StandardOutPath</key>
    <string>/Users/stu/llm/logs/tei-embed.out.log</string>

    <key>StandardErrorPath</key>
    <string>/Users/stu/llm/logs/tei-embed.err.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>/Users/stu</string>
    </dict>
</dict>
</plist>
```

- [ ] **Step 4: Validate the plist XML**

```bash
plutil -lint 04-clients/com.tei.embed.plist
```

Expected: `OK`.

- [ ] **Step 5: Commit**

```bash
git add 04-clients/tei-embed-launch.sh 04-clients/com.tei.embed.plist
git commit -m "$(cat <<'EOF'
phase-4(tei): embed launcher + LaunchAgent

Boots BAAI/bge-m3 (1024-dim multilingual) under text-embeddings-router
on 0.0.0.0:8085. Same launcher/plist shape as com.tei.rerank.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Install + bootstrap both LaunchAgents

**Files:**
- Install: `04-clients/tei-rerank-launch.sh` → `~/llm/bin/tei-rerank-launch.sh`
- Install: `04-clients/tei-embed-launch.sh` → `~/llm/bin/tei-embed-launch.sh`
- Install: `04-clients/com.tei.rerank.plist` → `~/Library/LaunchAgents/com.tei.rerank.plist`
- Install: `04-clients/com.tei.embed.plist` → `~/Library/LaunchAgents/com.tei.embed.plist`

- [ ] **Step 1: Copy launchers into ~/llm/bin and ensure executable**

```bash
cp 04-clients/tei-rerank-launch.sh ~/llm/bin/tei-rerank-launch.sh
cp 04-clients/tei-embed-launch.sh ~/llm/bin/tei-embed-launch.sh
chmod +x ~/llm/bin/tei-rerank-launch.sh ~/llm/bin/tei-embed-launch.sh
```

- [ ] **Step 2: Copy plists into LaunchAgents**

```bash
cp 04-clients/com.tei.rerank.plist ~/Library/LaunchAgents/com.tei.rerank.plist
cp 04-clients/com.tei.embed.plist  ~/Library/LaunchAgents/com.tei.embed.plist
```

- [ ] **Step 3: Bootstrap rerank into launchd**

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.tei.rerank.plist
```

Expected: silent on success. If it errors with "Bootstrap failed: 17" the agent is already loaded — `launchctl bootout` first, then bootstrap again.

- [ ] **Step 4: Bootstrap embed into launchd**

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.tei.embed.plist
```

- [ ] **Step 5: Wait for both servers ready (cold load: rerank ~5 s, embed ~10 s)**

```bash
for port in 8084 8085; do
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if curl -s -m 2 "http://127.0.0.1:${port}/health" > /dev/null; then
      echo "port ${port} ready after $((i*2))s"
      break
    fi
    sleep 2
  done
done
```

Expected: both ports report ready within ~25 s.

- [ ] **Step 6: Confirm processes are alive**

```bash
launchctl print "gui/$(id -u)/com.tei.rerank" 2>&1 | grep -E "state|program|pid" | head -4
launchctl print "gui/$(id -u)/com.tei.embed"  2>&1 | grep -E "state|program|pid" | head -4
```

Expected: both report `state = running` with a non-zero `pid`.

- [ ] **Step 7: No commit — installation is operator action; the source files are already committed in Task 6 + 7**

---

## Task 9: Verify supervision (KeepAlive respawn)

**Files:** none

- [ ] **Step 1: Capture current PIDs**

```bash
RERANK_PID=$(launchctl print gui/$(id -u)/com.tei.rerank 2>&1 | awk '/pid/ {print $3; exit}')
EMBED_PID=$(launchctl print gui/$(id -u)/com.tei.embed  2>&1 | awk '/pid/ {print $3; exit}')
echo "rerank=$RERANK_PID  embed=$EMBED_PID"
```

Expected: two non-empty integers.

- [ ] **Step 2: Kill rerank and watch it respawn**

```bash
kill -9 "$RERANK_PID"
sleep 6
NEW_RERANK_PID=$(launchctl print gui/$(id -u)/com.tei.rerank 2>&1 | awk '/pid/ {print $3; exit}')
echo "rerank pid was $RERANK_PID now $NEW_RERANK_PID"
test -n "$NEW_RERANK_PID" && test "$NEW_RERANK_PID" != "$RERANK_PID" && echo OK
```

Expected: `OK` printed. New PID different from old. Wait up to 10 s if cold reload is slow.

- [ ] **Step 3: Same for embed**

```bash
kill -9 "$EMBED_PID"
sleep 12  # bge-m3 reload is slower
NEW_EMBED_PID=$(launchctl print gui/$(id -u)/com.tei.embed 2>&1 | awk '/pid/ {print $3; exit}')
echo "embed pid was $EMBED_PID now $NEW_EMBED_PID"
test -n "$NEW_EMBED_PID" && test "$NEW_EMBED_PID" != "$EMBED_PID" && echo OK
```

Expected: `OK`.

- [ ] **Step 4: Re-verify both endpoints respond**

```bash
curl -s -o /dev/null -w "rerank: %{http_code}\n" http://127.0.0.1:8084/health
curl -s -o /dev/null -w "embed:  %{http_code}\n" http://127.0.0.1:8085/health
```

Expected: both `200`.

- [ ] **Step 5: No commit — verification only**

---

## Task 10: Tailnet reach from titan

**Files:** none

- [ ] **Step 1: From titan via the Mac's Tailscale IP**

```bash
ssh titan 'curl -s -o /dev/null -w "rerank via IP: %{http_code}\n" http://100.82.76.20:8084/health
            curl -s -o /dev/null -w "embed  via IP: %{http_code}\n" http://100.82.76.20:8085/health'
```

Expected: both `200`.

- [ ] **Step 2: From titan via the tail-name (works if titan DNS is healthy; falls back is fine)**

```bash
ssh titan 'curl -s -m 5 -o /dev/null -w "rerank via name: %{http_code}\n" http://zen.tail1a2109.ts.net:8084/health
            curl -s -m 5 -o /dev/null -w "embed  via name: %{http_code}\n" http://zen.tail1a2109.ts.net:8085/health'
```

Expected: both `200`. If `000` (DNS broken on titan), see [`docs/titan-dns-resolver-fix.md`](../../titan-dns-resolver-fix.md) — IP fallback in Step 1 is the documented workaround.

- [ ] **Step 3: Functional rerank from titan**

```bash
ssh titan 'curl -s -X POST http://100.82.76.20:8084/rerank \
  -H "Content-Type: application/json" \
  -d "{\"query\":\"x\",\"texts\":[\"a\",\"x\",\"b\"]}" | python3 -m json.tool'
```

Expected: 3 `{index, score}` records, `index: 1` (text "x") scoring highest.

- [ ] **Step 4: No commit — verification only**

---

## Task 11: Swap LiteLLM `embed` alias to TEI

**Files:**
- Modify: `03-router/litellm.yaml`
- Modify: `~/llm/configs/litellm.yaml` (deployed mirror; sync from repo)

- [ ] **Step 1: Edit the repo's `litellm.yaml`**

Find this block in `03-router/litellm.yaml`:

```yaml
  - model_name: embed             # nomic-embed-text-v1.5 via LM Studio (was ollama/bge-m3; 768-dim, was 1024)
    litellm_params:
      model: openai/text-embedding-nomic-embed-text-v1.5
      api_base: http://127.0.0.1:1234/v1
      api_key: not-required
```

Replace with:

```yaml
  - model_name: embed             # bge-m3 via TEI on :8085 (1024-dim multilingual; restored from the original Ollama-era model)
    litellm_params:
      model: openai/BAAI/bge-m3
      api_base: http://127.0.0.1:8085/v1
      api_key: not-required
```

- [ ] **Step 2: Sync the runtime copy**

```bash
cp 03-router/litellm.yaml ~/llm/configs/litellm.yaml
diff -q 03-router/litellm.yaml ~/llm/configs/litellm.yaml && echo "(synced)"
```

Expected: `(synced)`.

- [ ] **Step 3: Restart LiteLLM**

```bash
launchctl kickstart -k gui/$(id -u)/com.litellm.server
for i in 1 2 3 4 5; do
  resp=$(curl -s -m 3 http://127.0.0.1:4000/health/liveliness 2>/dev/null)
  if [[ -n "$resp" ]]; then echo "litellm ready after $((i*2))s"; break; fi
  echo -n "."
  sleep 2
done
```

Expected: `litellm ready after Ns` within ~10 s.

- [ ] **Step 4: Probe the `embed` alias end-to-end via LiteLLM**

```bash
source ~/llm/configs/secrets.env
curl -s -X POST http://127.0.0.1:4000/v1/embeddings \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"embed","input":"hello via litellm into tei"}' \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('dim:', len(d['data'][0]['embedding']))"
```

Expected: `dim: 1024` (was 768 with nomic). If 0 / error, check the LiteLLM err log and the TEI embed err log.

- [ ] **Step 5: Commit**

```bash
git add 03-router/litellm.yaml
git commit -m "$(cat <<'EOF'
router(litellm): swap `embed` alias backend from LM Studio to TEI bge-m3

Was: openai/text-embedding-nomic-embed-text-v1.5 at LM Studio :1234
     (768-dim).
Now: openai/BAAI/bge-m3 at TEI :8085 (1024-dim multilingual; restores
     the original Ollama-era embedding model).

Continue's embeddingsProvider still talks to LiteLLM unchanged. Any
existing @codebase index will re-embed on next query because dim
changed (768 → 1024).

Companion to spec docs/superpowers/specs/2026-05-21-tei-rerank-embed-design.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Switch Continue reranker to `huggingface-tei`

**Files:**
- Modify: `04-clients/continue-config.json`
- Modify: `~/.continue/config.json` (deployed mirror)

- [ ] **Step 1: Edit the repo template's reranker block**

Find in `04-clients/continue-config.json`:

```json
  "reranker": {
    "name": "llm",
    "params": {
      "modelTitle": "Mini-tools (Hermes-4-14B function-calling)"
    }
  },
```

Replace with:

```json
  "reranker": {
    "name": "huggingface-tei",
    "params": {
      "apiBase": "http://127.0.0.1:8084"
    }
  },
```

- [ ] **Step 2: Mirror to the runtime config**

The runtime `~/.continue/config.json` has the same block with the real API key elsewhere. Apply the identical reranker swap:

```bash
python3 - <<'PY'
import json
from pathlib import Path
p = Path.home() / ".continue" / "config.json"
cfg = json.loads(p.read_text())
cfg["reranker"] = {
    "name": "huggingface-tei",
    "params": {"apiBase": "http://127.0.0.1:8084"},
}
p.write_text(json.dumps(cfg, indent=2) + "\n")
print("updated runtime config — reranker:", cfg["reranker"])
PY
```

Expected: prints the new reranker block.

- [ ] **Step 3: JSON sanity**

```bash
python3 -m json.tool ~/.continue/config.json > /dev/null && echo "runtime OK"
python3 -m json.tool 04-clients/continue-config.json > /dev/null && echo "repo OK"
```

Expected: both `OK`.

- [ ] **Step 4: Reload VS Code window so Continue picks up the new reranker**

This is an operator-side action in VS Code:

```
Cmd+Shift+P → "Developer: Reload Window"
```

After reload, the Continue settings panel should no longer show the "Setup Rerank model" banner; the rerank entry should read something like `huggingface-tei`.

- [ ] **Step 5: Commit**

```bash
git add 04-clients/continue-config.json
git commit -m "$(cat <<'EOF'
phase-4(continue): switch reranker from `llm` to `huggingface-tei`

Was: llm provider, modelTitle="Mini-tools (Hermes-4-14B function-calling)"
     via LiteLLM → mlx-broker. ~5-20 s per 20-candidate rerank because
     it's a 14B LLM scoring relevance by chat completion.
Now: huggingface-tei provider, apiBase=http://127.0.0.1:8084. Direct
     to TEI's /rerank endpoint, sub-second responses, dedicated
     CrossEncoder model (bge-reranker-large).

Runtime config at ~/.continue/config.json mirrored.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Retire the LM Studio nomic-embed LaunchAgent + doc update

**Files:**
- Modify: `04-clients/CLAUDE.md` (add TEI section, note LM Studio nomic deprecation)
- External: `~/Library/LaunchAgents/com.lmstudio.server.plist` (`launchctl bootout`)

The LM Studio chat UI itself stays on the Mac; only the LaunchAgent that auto-loads `text-embedding-nomic-embed-text-v1.5` gets retired. The plist file stays in the repo (`04-clients/com.lmstudio.server.plist`) and on disk; we just unload it from launchd so it doesn't auto-start.

- [ ] **Step 1: Bootout the LM Studio LaunchAgent**

```bash
launchctl bootout gui/$(id -u)/com.lmstudio.server 2>&1 | head -3 || echo "(already unloaded)"
```

Expected: silent success or "(already unloaded)".

- [ ] **Step 2: Stop LM Studio's lingering server process if any**

```bash
~/.lmstudio/bin/lms server stop 2>&1 | tail -2
```

Expected: "Server is not running" or "Stopped".

- [ ] **Step 3: Verify the `embed` alias still works (now backed only by TEI; LM Studio not in the path at all)**

```bash
source ~/llm/configs/secrets.env
curl -s -X POST http://127.0.0.1:4000/v1/embeddings \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"embed","input":"post-retire check"}' \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('dim:', len(d['data'][0]['embedding']))"
```

Expected: `dim: 1024`.

- [ ] **Step 4: Update `04-clients/CLAUDE.md` — add the TEI section + deprecation note**

Find the existing "LM Studio server LaunchAgent (load-bearing for `embed`)" subsection in `04-clients/CLAUDE.md` and replace it with this consolidated block:

```markdown
### TEI rerank + embed LaunchAgents (load-bearing for `embed` and Continue rerank)

Two TEI processes — built from Rust source in `~/llm/src/text-embeddings-inference` with `--features metal` — supervise `BAAI/bge-reranker-large` (rerank, `:8084`) and `BAAI/bge-m3` (embed, 1024-dim, `:8085`). Both bind `0.0.0.0` per the tailnet convention in the root `CLAUDE.md`.

LiteLLM's `embed` alias routes to TEI's `:8085`. Continue's `reranker` block hits TEI's `:8084` directly via the `huggingface-tei` provider.

Files in this folder:
- `tei-rerank-launch.sh` + `com.tei.rerank.plist` — rerank server
- `tei-embed-launch.sh` + `com.tei.embed.plist` — embed server

Install:

```bash
cp ./tei-rerank-launch.sh ./tei-embed-launch.sh ~/llm/bin/
chmod +x ~/llm/bin/tei-rerank-launch.sh ~/llm/bin/tei-embed-launch.sh
cp ./com.tei.rerank.plist ./com.tei.embed.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.tei.rerank.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.tei.embed.plist
```

Verify:

```bash
curl -s http://127.0.0.1:8084/health   # rerank
curl -s http://127.0.0.1:8085/health   # embed
source ~/llm/configs/secrets.env
curl -s -X POST http://127.0.0.1:4000/v1/embeddings \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"model":"embed","input":"ping"}' | jq '.data[0].embedding | length'   # expect 1024
```

### LM Studio nomic-embed LaunchAgent — RETIRED 2026-05-21

The `com.lmstudio.server` LaunchAgent previously loaded `text-embedding-nomic-embed-text-v1.5` and backed the `embed` alias on `:1234`. Replaced 2026-05-21 by TEI bge-m3 on `:8085` (1024-dim, multilingual). The plist file stays in this folder for history; the LaunchAgent was bootout'd from launchd. LM Studio's *chat UI* still works on the Mac when launched interactively; just no auto-loaded embed model.

To re-enable temporarily (e.g. fallback if TEI is down):

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.lmstudio.server.plist
# Then point litellm.yaml's `embed` alias back at openai/text-embedding-nomic-embed-text-v1.5 on :1234.
```
```

- [ ] **Step 5: Commit**

```bash
git add 04-clients/CLAUDE.md
git commit -m "$(cat <<'EOF'
phase-4(docs): TEI rerank + embed section; retire LM Studio nomic note

Replaces the "LM Studio server LaunchAgent (load-bearing for embed)"
subsection with a TEI-focused section covering both rerank and embed
servers, plus an install + verify recipe. Adds a "LM Studio nomic
LaunchAgent RETIRED 2026-05-21" tombstone with the rollback recipe
in case TEI ever needs to step aside.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: Final acceptance — verify all 5 criteria from the spec

**Files:** none

This task is a single end-to-end pass against every acceptance criterion the spec lists.

- [ ] **Step 1: AC#1 — `curl :8084/rerank` returns ordered scores**

```bash
curl -s -X POST http://127.0.0.1:8084/rerank \
  -H "Content-Type: application/json" \
  -d '{"query":"how do I add an alias to mlx-broker",
       "texts":["unrelated about sparse bundles",
                "add alias to mlx-broker yaml under aliases",
                "git commit style"]}' \
  | python3 -c "import json,sys; d=json.load(sys.stdin); s=sorted(d, key=lambda x:-x['score']); print('top:', s[0])"
```

Expected: top score's `index` is `1`.

- [ ] **Step 2: AC#2 — `curl :4000/v1/embeddings` returns 1024-dim with model=embed**

```bash
source ~/llm/configs/secrets.env
curl -s -X POST http://127.0.0.1:4000/v1/embeddings \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"embed","input":"AC2"}' \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('dim:', len(d['data'][0]['embedding']))"
```

Expected: `dim: 1024`.

- [ ] **Step 3: AC#3 — titan can reach zen's TEI**

```bash
ssh titan 'curl -s -o /dev/null -w "%{http_code}\n" http://100.82.76.20:8084/health
            curl -s -o /dev/null -w "%{http_code}\n" http://100.82.76.20:8085/health'
```

Expected: two `200` lines.

- [ ] **Step 4: AC#4 — Continue @codebase eyeball test**

This is a manual operator step in VS Code:

1. Open the macbookm5promax repo in VS Code.
2. Open the Continue panel (Cmd+L).
3. Type `@codebase tell me what the mlx-broker static table format looks like`.
4. Look at the top-3 chunks Continue retrieves before generating its answer.

Expected: top-3 chunks should include `~/projects/mlx-broker/config/mlx-broker.sample.yaml` and/or the broker `config.py`. Latency to top-3 should feel sub-second-to-the-rerank step (vs the 5–20 s the `llm` reranker was taking).

- [ ] **Step 5: AC#5 — both LaunchAgents survive `kickstart -k` and respawn**

```bash
launchctl kickstart -k gui/$(id -u)/com.tei.rerank
launchctl kickstart -k gui/$(id -u)/com.tei.embed
sleep 12
curl -s -o /dev/null -w "rerank: %{http_code}\n" http://127.0.0.1:8084/health
curl -s -o /dev/null -w "embed:  %{http_code}\n" http://127.0.0.1:8085/health
```

Expected: both `200`.

- [ ] **Step 6: AC#6 — LM Studio nomic-embed LaunchAgent is bootout'd**

```bash
launchctl print gui/$(id -u)/com.lmstudio.server 2>&1 | grep -E "state|Could not find" | head -2
```

Expected: either `Could not find service ...` or `state = not running` — both indicate the agent isn't supervising anything right now. LM Studio chat UI is unaffected.

- [ ] **Step 7: Tick the corresponding Notion items (#27–34)**

Per the project's update-on-completion workflow, open the Notion tracker (https://www.notion.so/364bb54b0db681028121f736b8b74195) and tick items 27 through 34 in the P8 section. One-line note per item is fine.

- [ ] **Step 8: No final commit — every component task already committed**

---

## Self-review (writing-plans skill checklist)

**Spec coverage.** Each section of the spec maps to at least one task:

| Spec section | Covered by |
|---|---|
| Goal + Why TEI | Tasks 1–2 (build), 11 (LiteLLM swap), 12 (Continue swap), 13 (retire LM Studio) |
| Architecture | Implicit across all tasks; verified end-to-end in Task 14 |
| Components table | Tasks 1–3 (toolchain + binary + models), 6–8 (launchers + LaunchAgents) |
| Ports table | Task 4/5 (foreground), Task 8 (LaunchAgent bind), Task 10 (tailnet) |
| Data flow (rerank, embed) | Task 11 (embed via LiteLLM), Task 12 (rerank direct), Task 14 (end-to-end) |
| Privacy | Task 6 + 7 (env vars in launchers), Task 10 (tailnet verified, no LAN/WAN check needed — pfSense + Little Snitch outside scope) |
| Sequencing | 1:1 with task order |
| Testing (3 smokes + Continue) | Task 4 (rerank smoke), Task 5 (embed smoke), Task 11 (LiteLLM smoke), Task 14 (full AC sweep) |
| Risks/fallbacks | Metal fallback in Task 2 Step 2; LM Studio rollback in Task 13 doc |
| Out of scope | Plan respects: no multi-model TEI, no /rerank through LiteLLM, no titan/Continue config (loopback config only) |
| Acceptance criteria | Task 14 walks all six AC bullets |

**Placeholder scan.** Searched for `TBD|TODO|FIXME|fill in|similar to`. None present in the plan body.

**Type consistency.** Reranker name `huggingface-tei` (Task 12) matches the Continue provider name. Alias name `embed` (Task 11) matches the litellm.yaml model_name. Plist labels `com.tei.rerank` and `com.tei.embed` match consistently between Tasks 6/7 (write), Tasks 8/9 (bootstrap/verify), Task 13 (rollback note), Task 14 (kickstart).

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-05-21-tei-rerank-embed-plan.md`.** Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Best fit for a 14-task plan with mostly mechanical config + smoke-test steps.
2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints. Suits if you want to watch each step in this conversation.

Which approach?
