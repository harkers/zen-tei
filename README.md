# zen-tei

HuggingFace **Text Embeddings Inference** (TEI) running on **zen**, a MacBook Pro
M5 Pro Max set up for offline LLM work in privacy-consulting workflows.

Two supervised LaunchAgents:

| Port | Model | Role |
|---|---|---|
| `:8084` | `BAAI/bge-reranker-large` | CrossEncoder reranker. Backs Continue's `huggingface-tei` provider for `@codebase` / `@docs` retrieval. Sub-second per 20-candidate batch. |
| `:8085` | `BAAI/bge-m3` | 1024-dim multilingual embeddings. Backs the `embed` alias in LiteLLM, used by Continue's `embeddingsProvider`. |

Both bind `0.0.0.0` so the tailnet (titan, workstation, iPad) can reach them
without exposing anything on LAN/WAN. Built from Rust source with `--features
metal` for native Apple Silicon acceleration.

## Why TEI on this Mac

Before TEI:

- `embed` was served by LM Studio's headless `text-embedding-nomic-embed-text-v1.5`
  (768-dim, ~80 MB) on `:1234`. Worked, but locked into LM Studio's lifecycle.
- Rerank was via Continue's `llm` provider against `mini-tools` (Hermes-4-14B) —
  using a 14B chat model to score relevance was 5–20 s per query and competed
  with chat models for broker RAM.

TEI gives:

- Dedicated CrossEncoder rerank → 100–500 ms per batch.
- Higher-dim embeddings (1024 vs 768), restored from the original Ollama-era
  `bge-m3` from before [Ollama was deprecated](https://github.com/harkers/macbookm5promax/blob/main/02-inference/CLAUDE.md).
- Own process, own RAM budget — doesn't fight mlx-broker's 80 GB cap.
- Smaller surface area than carrying LM Studio just for embeddings.

## Quick install

```bash
git clone https://github.com/harkers/zen-tei ~/projects/zen-tei
cd ~/projects/zen-tei
./scripts/install.sh        # rustup + cargo build + model pull + LaunchAgents
./scripts/verify.sh         # smoke both endpoints + tailnet reach
```

See [`CLAUDE.md`](CLAUDE.md) for the full operator context (architecture,
configuration, troubleshooting) and [`docs/`](docs/) for the design + plan.

## Wiring into the rest of zen's stack

- `LiteLLM` (`harkers/macbookm5promax` → `03-router/litellm.yaml`): `embed` alias
  routes to TEI's `:8085/v1/embeddings`.
- `Continue` (`harkers/macbookm5promax` → `04-clients/continue-config.json`):
  `reranker.name = huggingface-tei`, `apiBase = http://127.0.0.1:8084`.

Cross-machine clients hit TEI via the Mac's Tailscale IP (`100.82.76.20`,
tail-name `zen.tail1a2109.ts.net`).

## Related repos

- [`harkers/mlx-broker`](https://github.com/harkers/mlx-broker) — supervises the
  MLX chat/code/heavy/etc. backends on `:8090`. Sibling pattern; this repo
  extracted using the same model.
- [`harkers/macbookm5promax`](https://github.com/harkers/macbookm5promax) — the
  parent install plan for zen.
