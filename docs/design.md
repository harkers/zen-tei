# TEI rerank + embed on zen — design

## Goal

Run two HuggingFace Text Embeddings Inference (TEI) processes on zen, supervised in
the existing LaunchAgent pattern, serving a CrossEncoder reranker and a multilingual
embedding model. Wire Continue's `huggingface-tei` reranker at the rerank server.
Re-route LiteLLM's existing `embed` alias from LM Studio's nomic-embed to TEI's
bge-m3. Retire the LM Studio embed LaunchAgent.

All services bind to the tailnet (per the [project convention added 2026-05-21](../../../CLAUDE.md#conventions))
so any other tailnet device (titan, workstation, future iPad) can reach them.

## Why TEI vs alternatives

The current rerank path is Continue's `llm` reranker pointed at the `mini-tools`
alias (Hermes-4-14B). It works but is slow (5–20 s per 20-candidate rerank) and
competes with chat models for broker RAM. TEI is purpose-built:

- Dedicated CrossEncoder model, sub-second reranks.
- Native Metal acceleration on Apple Silicon when built with `--features metal`.
- Single Rust binary, small surface area, no telemetry.
- Continue ships a first-class `huggingface-tei` provider that hits TEI's
  `/rerank` API directly.

Alternatives considered: Docker (no Metal in the Linux VM on Apple Silicon — slow),
custom FastAPI shim (lighter but not canonical), vLLM (heavier, decoder-only path
needed if we used Qwen3-Reranker — which TEI can't serve anyway). Rust + Metal won.

## Architecture

```
VS Code Continue ──HTTP /rerank──► TEI rerank (zen :8084) ──Metal──► bge-reranker-large
       │
       └─ HTTP /v1/embeddings ──► LiteLLM (:4000)
                                       │
                                       └─► TEI embed (zen :8085) ──Metal──► bge-m3

Both TEI processes:
  - bind 0.0.0.0 (tailnet-reachable as zen.tail1a2109.ts.net:{8084,8085})
  - supervised by user LaunchAgent (com.tei.rerank, com.tei.embed)
  - logs at ~/llm/logs/tei-{rerank,embed}.{out,err}.log
  - model weights at ~/.cache/huggingface/hub/
  - telemetry env vars off (HF_HUB_DISABLE_TELEMETRY=1, DO_NOT_TRACK=true,
    ANONYMIZED_TELEMETRY=false)

Separate from mlx-broker / LiteLLM / LM Studio — own processes, own RAM budget.
```

## Components

| Component | What | Where on disk |
|---|---|---|
| Rust toolchain | `rustup` install (per-user, no sudo). `cargo` + `rustc`. ~1.5 GB. | `~/.cargo`, `~/.rustup` |
| TEI source | `git clone https://github.com/huggingface/text-embeddings-inference` | `~/llm/src/text-embeddings-inference/` |
| TEI binary | `cargo install --path router --features metal` builds `text-embeddings-router`. | `~/.cargo/bin/text-embeddings-router` (symlinked to `~/llm/bin/text-embeddings-router`) |
| Rerank model | `BAAI/bge-reranker-large` (~1.1 GB disk, ~2 GB resident) | pulled by TEI to `~/.cache/huggingface/hub/` |
| Embed model | `BAAI/bge-m3` (~2.3 GB disk, ~3 GB resident, 1024-dim multilingual) | same |
| Rerank launcher | `tei-rerank-launch.sh` — telemetry-off env, exec router for rerank | `04-clients/tei-rerank-launch.sh` (repo) → `~/llm/bin/` (deployed) |
| Embed launcher | `tei-embed-launch.sh` — sibling | `04-clients/tei-embed-launch.sh` |
| Rerank LaunchAgent | `com.tei.rerank.plist` — `RunAtLoad=true`, `KeepAlive` on crash, logs to `~/llm/logs/tei-rerank.{out,err}.log` | `04-clients/com.tei.rerank.plist` (repo) → `~/Library/LaunchAgents/` |
| Embed LaunchAgent | `com.tei.embed.plist` — sibling | `04-clients/com.tei.embed.plist` |
| Continue reranker | `huggingface-tei` provider, `url: http://127.0.0.1:8084` (Mac-local; titan-side clients use `zen.tail1a2109.ts.net:8084` once the titan-DNS issue is durable, or the IP today) | `~/.continue/config.json` + `04-clients/continue-config.json` |
| LiteLLM `embed` alias | swaps backend from `http://127.0.0.1:1234/v1` to `http://127.0.0.1:8085/v1` (TEI exposes OpenAI-compatible `/v1/embeddings`) | `03-router/litellm.yaml` + `~/llm/configs/litellm.yaml` |
| LM Studio nomic-embed LaunchAgent | retire (`launchctl bootout`, plist preserved in repo for history) | `04-clients/com.lmstudio.server.plist` documented as deprecated |

## Ports

| Port | Service | Bind |
|---|---|---|
| 4000 | LiteLLM | `0.0.0.0` (already) |
| 8084 | TEI rerank | `0.0.0.0` (new) |
| 8085 | TEI embed | `0.0.0.0` (new) |
| 8090 | mlx-broker | `127.0.0.1` (existing; convention-violation flagged in root CLAUDE.md, out of scope here) |
| 1234 | LM Studio chat | `127.0.0.1` (existing; convention-violation flagged) |

`:8084` and `:8085` chosen as adjacent free ports beside the broker.

## Data flow

**Rerank (Continue → TEI direct, no proxy):**

1. Continue retrieves N candidate chunks from `@codebase` via its vector store
   (Lance, backed by the embed result).
2. Continue POSTs `{query, texts: [...N]}` to `http://127.0.0.1:8084/rerank`.
3. TEI returns `[{index, score}, …]` ordered by relevance.
4. Continue reorders chunks, takes top-K, injects into prompt.

**Embed (Continue → LiteLLM → TEI):**

1. Continue POSTs `{model: "embed", input: [...]}` to LiteLLM `:4000/v1/embeddings`.
2. LiteLLM resolves the `embed` alias to `openai/<tei-model-id>` at
   `http://127.0.0.1:8085/v1`.
3. TEI returns the embedding vectors. LiteLLM forwards.

The LiteLLM hop on embed costs ~1 ms and keeps the alias indirection (so future
embed-backend swaps don't touch any client config — only `litellm.yaml`).

## Privacy

- Both TEI processes bind `0.0.0.0` but the Mac's only ingress paths are
  Tailscale (verified) and Wi-Fi (pfSense filters; Little Snitch denies inbound
  by default). Net effect: tailnet-reachable, LAN/WAN-invisible.
- Telemetry env vars set in each launch script:
  `HF_HUB_DISABLE_TELEMETRY=1`, `DO_NOT_TRACK=true`, `ANONYMIZED_TELEMETRY=false`.
- TEI itself doesn't phone home; only the first-launch model pull from HF goes
  outbound. After that, fully offline.

## Sequencing (writing-plans expands this)

1. Install Rust toolchain via `rustup-init` (per-user, no sudo).
2. Clone TEI into `~/llm/src/text-embeddings-inference`.
3. `cargo install --path router --features metal` (~5–10 min, one-time).
4. Symlink the binary into `~/llm/bin/`.
5. Pre-pull both models via `huggingface-cli download` so first launch doesn't
   block on download (~3.4 GB total).
6. Smoke-test the rerank server in the foreground:
   `~/llm/bin/text-embeddings-router --model-id BAAI/bge-reranker-large
   --hostname 0.0.0.0 --port 8084` → `curl :8084/rerank` returns scores.
7. Smoke-test the embed server similarly on `:8085`.
8. Write the two launch scripts + two plists.
9. `launchctl bootstrap` both, verify `KeepAlive` by killing one and watching
   it respawn.
10. Confirm tailnet reach from titan: `curl http://zen.tail1a2109.ts.net:8084/`
    returns TEI's health JSON (with fallback to `100.82.76.20` if DNS still drifts).
11. Update `03-router/litellm.yaml` + sync to `~/llm/configs/litellm.yaml`.
12. Restart LiteLLM (`launchctl kickstart -k`).
13. Verify `curl -H "Authorization: Bearer $KEY" :4000/v1/embeddings` against the
    `embed` alias still returns valid vectors — but now 1024-dim (was 768) so the
    response shape changes.
14. Update Continue's `reranker` config (both runtime and repo template).
15. Operator action: delete `~/.continue/index/` so Continue re-indexes against
    the new embedding dim. (Optional; Continue should auto-reindex on dim
    mismatch.)
16. Operator validation: open Continue in VS Code, run an `@codebase` query,
    eyeball relevance + latency.
17. Retire LM Studio nomic-embed: `launchctl bootout gui/$(id -u)/com.lmstudio.server`
    and document deprecation in `04-clients/CLAUDE.md`.

## Testing

- **Standalone rerank smoke:**
  ```bash
  curl -s -X POST http://127.0.0.1:8084/rerank \
    -H "Content-Type: application/json" \
    -d '{"query":"how do I add an alias to mlx-broker",
         "texts":["unrelated about sparse bundles",
                  "add alias to mlx-broker yaml under aliases",
                  "git commit style"]}'
  # Expect the middle text scoring highest.
  ```

- **Standalone embed smoke:**
  ```bash
  source ~/llm/configs/secrets.env
  curl -s -X POST http://127.0.0.1:4000/v1/embeddings \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model":"embed","input":"hello world"}' \
    | jq '.data[0].embedding | length'
  # Expect 1024 (was 768 with nomic).
  ```

- **Tailnet reach (from titan):**
  ```bash
  ssh titan curl -s http://zen.tail1a2109.ts.net:8084/health
  # OR via IP fallback: http://100.82.76.20:8084/health
  # Expect 200 OK.
  ```

- **Continue integration:** open VS Code, `@codebase` query, observe relevance
  + latency vs the previous `llm` reranker baseline.

## Risks + fallbacks

| Risk | Fallback |
|---|---|
| TEI's `metal` feature has a build error on macOS Tahoe 26.4 | Drop `--features metal` → CPU build. bge-reranker-large on CPU ≈ 200–500 ms; still 10× faster than the LLM reranker. |
| `bge-m3` 3 GB resident + `bge-reranker-large` 2 GB resident = 5 GB always-warm | Acceptable for this Mac. If pressure rises, swap embed model to mxbai-embed-large-v1 (~1.7 GB) or back to nomic (768-dim) — config-only change. |
| Continue's `@codebase` index incompatible with new 1024-dim embeddings | Delete `~/.continue/index/` to force re-index. One-time cost on the first query post-cutover. |
| Tailscale serve / DNS regression (titan can't resolve `zen` reliably) | Use the Mac's Tailscale IP `100.82.76.20` from titan; documented in `docs/titan-dns-resolver-fix.md`. |
| LiteLLM crashes on embed-backend swap | LM Studio LaunchAgent stays installed (just bootout, plist preserved) — `launchctl bootstrap` to revive within seconds. |
| Rust toolchain breaks on a future macOS upgrade | rustup is well-maintained; `rustup update` resolves nearly all cases. If TEI build breaks, pin to a known-good Rust version in the launch doc. |

## Out of scope

- Multi-model TEI hosting in one process (TEI is single-model per binary by design).
- Rerank result caching at the TEI layer (Continue does some retrieval caching;
  TEI itself doesn't need it for this workload).
- Bringing mlx-broker and LM Studio chat onto the tailnet — that's the follow-up
  audit flagged in the root CLAUDE.md convention note.
- Exposing TEI through LiteLLM's `/rerank` endpoint (LiteLLM supports rerank
  routing but Continue's `huggingface-tei` provider talks to TEI directly, so
  the LiteLLM hop adds no value here).
- Cross-machine rerank: titan / workstation / future iPad can hit TEI directly
  if they want; no Continue config there to update right now.

## Files touched

```
NEW   docs/superpowers/specs/2026-05-21-tei-rerank-embed-design.md  (this doc)
NEW   04-clients/tei-rerank-launch.sh
NEW   04-clients/tei-embed-launch.sh
NEW   04-clients/com.tei.rerank.plist
NEW   04-clients/com.tei.embed.plist
MOD   04-clients/CLAUDE.md           (add "TEI rerank + embed" section; note LM Studio embed retirement)
MOD   04-clients/continue-config.json (reranker stanza)
MOD   03-router/litellm.yaml          (embed-alias backend swap)
MOD   ~/.continue/config.json         (runtime mirror)
MOD   ~/llm/configs/litellm.yaml      (runtime mirror)
MOD   CLAUDE.md                       (already committed e795211 — convention)
```

## Acceptance criteria

- `curl :8084/rerank` returns ordered scores (smoke test passes).
- `curl :4000/v1/embeddings` returns 1024-dim vectors with `model=embed`.
- titan → zen TEI reachable via tail-name or IP.
- Continue's @codebase query returns visibly more relevant top-3 chunks than
  the previous llm-reranker baseline (operator eyeball test).
- Both LaunchAgents survive a `launchctl kickstart -k` and respawn cleanly.
- LM Studio nomic-embed LaunchAgent bootout'd; only LM Studio chat UI remains
  (and it's still loopback — follow-up audit territory).
