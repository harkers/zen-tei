# CLAUDE.md — zen-tei

Operator context for Claude Code sessions in this repo.

## What this is

Two HuggingFace TEI (Text Embeddings Inference) processes supervised on **zen**
(MacBook Pro M5 Pro Max) by user-level LaunchAgents. Built from Rust source
with `--features metal` so reranks/embeds get Apple Silicon Metal acceleration.

Companion design + plan in [`docs/`](docs/). Parent project at
[`harkers/macbookm5promax`](https://github.com/harkers/macbookm5promax).

## Pinned versions (`VERSIONS`)

The `VERSIONS` file at the repo root is shell-sourceable and the single
source of truth for: TEI source SHA, Rust toolchain, HuggingFace model
revisions, and a last-smoke marker. `scripts/install.sh` sources it
during the TEI clone + build step (T2/T3 of the Phase A plan).

Bump procedure:

1. Edit `VERSIONS` with the new pin(s).
2. Run `./scripts/install.sh` — it will check out the new SHA, rebuild,
   re-pull models, re-bootstrap.
3. Run `./scripts/verify.sh` — must pass 9/9.
4. Update `LAST_SMOKE_DATE` and `LAST_SMOKE_RESULT` in `VERSIONS`.
5. Commit `VERSIONS` (and any other changed files) together.

If `./scripts/verify.sh` fails after a bump, revert the `VERSIONS` edit
and re-run install.sh — you're back to the previous pinned state in
one minute.

## What runs

| Component | Detail |
|---|---|
| `text-embeddings-router` v1.9.3 | Built once via `cargo install --path router --features metal`. Binary at `~/.cargo/bin/text-embeddings-router`, symlinked to `~/llm/bin/`. |
| Rerank LaunchAgent (`com.tei.rerank`) | `~/Library/LaunchAgents/com.tei.rerank.plist`. Binds `0.0.0.0:8084`, model `BAAI/bge-reranker-large` (~1.1 GB on disk, ~2 GB resident). |
| Embed LaunchAgent (`com.tei.embed`) | `~/Library/LaunchAgents/com.tei.embed.plist`. Binds `0.0.0.0:8085`, model `BAAI/bge-m3` (~2.3 GB on disk, ~3 GB resident, 1024-dim multilingual). |
| Models | Pulled to `~/models/mlx/` (the shared HF cache the rest of zen's stack uses, set via `HF_HUB_CACHE` in com.mlx-broker.plist). |
| Logs | `~/llm/logs/tei-rerank.{out,err}.log`, `~/llm/logs/tei-embed.{out,err}.log`. |

## Why this is its own repo (not a subdir of macbookm5promax)

Same reasoning as the [mlx-broker extraction](https://github.com/harkers/mlx-broker): scoped install/upgrade story, clearer
boundary for cross-machine sharing (other tailnet hosts could deploy this), and
smaller blast radius when iterating on plists or rebuilding the binary.

## Plist shape (matches the working com.mlx-broker pattern)

Both plists invoke the router binary directly (no shell wrapper) with the model
id, the shared HF cache, hostname `0.0.0.0`, and the port as separate
`ProgramArguments` entries. Telemetry env vars live in `EnvironmentVariables`:

```xml
<key>EnvironmentVariables</key>
<dict>
    <key>ANONYMIZED_TELEMETRY</key><string>false</string>
    <key>DO_NOT_TRACK</key><string>true</string>
    <key>HF_HUB_DISABLE_TELEMETRY</key><string>1</string>
</dict>

<key>KeepAlive</key>
<dict>
    <key>SuccessfulExit</key><false/>
</dict>

<key>ProcessType</key>
<string>Standard</string>
```

Three earlier plist variants didn't get auto-respawn working under macOS Tahoe;
this one matches `com.mlx-broker.plist` exactly. See [`docs/design.md`](docs/design.md)
and the commit log for the diagnosis chain.

## Known wrinkle — macOS Tahoe respawn throttle

macOS 26.x's launchd applies a `pended nondemand spawn = inefficient/semaphore`
throttle that prevents auto-respawn after `kill -9` (or a crash). Other
LaunchAgents on the same Mac (com.mlx-broker, com.litellm.server) don't hit
this — root cause is murky.

`RunAtLoad` fires on user login, so reboot recovery works. Mid-session, recover
with:

```bash
launchctl kickstart "gui/$(id -u)/com.tei.rerank"
launchctl kickstart "gui/$(id -u)/com.tei.embed"
```

Not a fix target; tracked here so the next operator doesn't re-diagnose.

### Watchdog (com.tei.watchdog)

The macOS Tahoe throttle is papered over by `scripts/watchdog.sh`, a
long-lived loop launched by `plist/com.tei.watchdog.plist` (KeepAlive,
RunAtLoad). Every 90 s it curls each `/health` endpoint and
`launchctl kickstart`s any service that doesn't respond. Each recovery
is logged with an ISO timestamp to `~/llm/logs/tei-watchdog.log`.

Inspect recent recoveries:

```bash
tail -20 ~/llm/logs/tei-watchdog.log
```

Why a long-lived loop instead of `StartInterval`: launchd's 10-second
minimum-runtime backoff stalls `StartInterval` jobs that exit fast on
the happy path. Keeping the process alive with an internal `sleep`
sidesteps the throttle entirely — and the same `KeepAlive` mechanism
respawns the watchdog if it ever crashes.

Tune the interval by editing the `INTERVAL=90` constant at the top of
`scripts/watchdog.sh` (larger for less launchctl noise, smaller for
faster recovery). Then `launchctl kickstart "gui/$(id -u)/com.tei.watchdog"`
to pick up the new value.

## Verify

```bash
./scripts/verify.sh
```

Or piecemeal:

```bash
# Endpoints
curl -s http://127.0.0.1:8084/health       # rerank
curl -s http://127.0.0.1:8085/health       # embed

# Functional rerank
curl -s -X POST http://127.0.0.1:8084/rerank \
  -H "Content-Type: application/json" \
  -d '{"query":"q","texts":["a","q","b"]}' | jq .

# Embed via LiteLLM (1024-dim)
source ~/llm/configs/secrets.env
curl -s -X POST http://127.0.0.1:4000/v1/embeddings \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"embed","input":"ping"}' | jq '.data[0].embedding | length'
```

## Upgrade

Bumping TEI = bumping the pin in `VERSIONS`, then re-running install.
The pin file is the contract; do NOT `git pull` the TEI source directly
or you'll un-pin the binary silently. Full procedure in the
[Pinned versions](#pinned-versions-versions) section above.

Short form:

```bash
$EDITOR VERSIONS                         # bump TEI_SOURCE_SHA + TEI_ROUTER_VERSION
./scripts/install.sh                     # re-checks out the SHA, rebuilds, re-bootstraps
./scripts/verify.sh                      # must pass 9/9
$EDITOR VERSIONS                         # refresh LAST_SMOKE_DATE + LAST_SMOKE_RESULT
git add VERSIONS && git commit -m "bump TEI to <sha>"
```

The symlink at `~/llm/bin/text-embeddings-router` auto-resolves to the
new build; the LaunchAgents pick it up on the next `launchctl kickstart`
that install.sh runs at the end.

## Wired into

| Stack piece | How it talks to TEI |
|---|---|
| `LiteLLM` (`harkers/macbookm5promax` → `03-router/litellm.yaml`) | `embed` alias points at `http://127.0.0.1:8085/v1` with `model: openai/BAAI/bge-m3`. |
| `Continue` (VS Code extension, `harkers/macbookm5promax` → `04-clients/continue-config.json`) | `reranker.name = huggingface-tei`, `apiBase = http://127.0.0.1:8084`. |

## Conventions inherited from parent project

- Telemetry env vars off (`HF_HUB_DISABLE_TELEMETRY=1`, `DO_NOT_TRACK=true`,
  `ANONYMIZED_TELEMETRY=false`).
- Tailnet-bind by default (`0.0.0.0`), not loopback. Ingress filtered at
  pfSense + Little Snitch; only Tailscale reaches the Mac.
- HF model cache at `~/models/mlx/`, not the default `~/.cache/huggingface/`.

See [`harkers/macbookm5promax/CLAUDE.md`](https://github.com/harkers/macbookm5promax/blob/main/CLAUDE.md#conventions)
for the canonical statement of these conventions.

## Layout

```
zen-tei/
├── README.md             # human-facing intro
├── CLAUDE.md             # this file — operator context for Claude Code
├── VERSIONS              # pinned TEI SHA + Rust toolchain + model revisions
├── rust-toolchain.toml   # cargo honors this automatically
├── plist/
│   ├── com.tei.rerank.plist
│   ├── com.tei.embed.plist
│   └── com.tei.watchdog.plist
├── scripts/
│   ├── install.sh        # cargo + model pull + plist install + bootstrap + kickstart
│   ├── verify.sh         # 9-check smoke (endpoints, dim, tailnet, LiteLLM hop)
│   ├── uninstall.sh      # bootout + remove plists (binary + models stay)
│   ├── lint.sh           # shellcheck scripts/*.sh + plutil plist/*.plist
│   └── watchdog.sh       # long-lived loop; kickstart on dead /health
└── docs/
    ├── design.md         # the original design spec (2026-05-21)
    ├── plan.md           # the 14-task implementation plan that produced this
    ├── backlog-design-v1.md # Phase A/B/C improvements design (2026-05-22; current is highest -vN.md)
    └── phase-a-plan.md   # Phase A executed plan (2026-05-22)
```
