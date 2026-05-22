# zen-tei improvements backlog — design (v1)

**Status:** approved 2026-05-22. Phase A is the immediate writing-plans target;
B + C remain as backlog entries to be planned later.

## Version history

This document is iterated as discrete versions under
`docs/<topic>-design-v<N>.md`. "Current" = highest `-v<N>.md`. New
iteration = `cp` to `-v<N+1>.md`, edit, prepend a row here, commit.
Frozen versions are never edited after they ship.

| Version | Date | Commit | Summary |
|---|---|---|---|
| v1 | 2026-05-22 | `d41add8` (drafted) → renamed in this commit | Initial brainstorm output: 3 phases (A essential, B discipline, C polish) with 10 improvement items, sequencing rationale, explicit non-goals, locked defaults (90s watchdog, SHA-pin strategy, CI block-merge). Phase A executed via [`phase-a-plan.md`](phase-a-plan.md). |

**Goal.** Take zen-tei from "extracted files that work" to "thin deployment
repo I can hand to a teammate, bump TEI in, and ignore for months at a time."
Don't redesign the LaunchAgents; add the scaffolding around them.

## Phase A — essential (writing-plans target)

Pays for itself immediately. Each item is small, atomic, low-risk.

### A1. Pin TEI source + Rust toolchain

`scripts/install.sh` currently does `git clone --depth=1` of TEI's HEAD and
relies on whatever `rustup` defaults to. Reinstalling weeks from now is
guaranteed to produce a different binary.

**Change:**

- `scripts/install.sh`: clone a specific SHA (TEI doesn't ship release tags
  — verified 2026-05-22). The pin lives in a top-level `VERSIONS` file
  alongside the model SHAs from A2.
- Add `rust-toolchain.toml` at repo root with the exact Rust version that
  built the current binary. `cargo install` honors this automatically.

**Pin source:** TEI commit `5bc4d889c38cf9c75e63617d62779bc0f6628b23`
(2026-04-15) — that's HEAD at the time of the original build.

**`VERSIONS` shape:**

```
# zen-tei pinned versions — bump intentionally, smoke before commit
tei_source = 5bc4d889c38cf9c75e63617d62779bc0f6628b23   # 2026-04-15 HEAD
tei_router_version = 1.9.3                              # built version
rust_toolchain = stable                                 # use rust-toolchain.toml for exact
bge_reranker_large_revision = <fill from HF snapshot>
bge_m3_revision = <fill from HF snapshot>
last_smoke = 2026-05-22 (9/9 verify checks)
```

### A2. Pin model revisions

`huggingface-cli download` without `--revision` grabs `main`. HF repos can be
force-pushed (rare but possible) or have their `main` branch moved.

**Change:**

- `scripts/install.sh`: append `--revision <sha>` to both `huggingface-cli
  download` calls. SHAs sourced once at install-time from
  `~/models/mlx/models--BAAI--bge-{reranker-large,m3}/snapshots/<sha>/` and
  written to `VERSIONS`.

### A3. `scripts/lint.sh` — shellcheck + plutil

Both tools are macOS-builtin or 1-line brew installs. Catches the obvious
mistakes (unset vars, wrong plist syntax) before they hit launchd.

**Change:**

- New `scripts/lint.sh`: runs `shellcheck scripts/*.sh` and `plutil -lint
  plist/*.plist`. Exits non-zero on any failure.
- Document in README: "before committing, run `./scripts/lint.sh`".
- Optional follow-up (not in Phase A): a `pre-commit` hook that runs it.

### A4. Watchdog — auto-kickstart on health drop

The biggest "this isn't really self-healing" gap. Currently a mid-session crash
leaves TEI down until the operator manually `launchctl kickstart`s.

**Change:**

- New `plist/com.tei.watchdog.plist` — LaunchAgent with `StartInterval = 90`
  (every 90 s).
- New `scripts/watchdog.sh` — for each of `:8084` and `:8085`, `curl -s -m 3
  /health`. If `HTTP 000`, `launchctl kickstart "gui/$(id -u)/com.tei.<svc>"`
  and log to `~/llm/logs/tei-watchdog.log`.
- Wired into `scripts/install.sh` (alongside the other two plists) and
  `scripts/uninstall.sh` (bootout when removing).

**Interval rationale:** 90 s is the compromise — 60 s feels responsive but
spams launchd; 300 s leaves long enough dropouts to be noticeable. Single
constant at the top of the script so operators can tune.

### Phase A acceptance criteria

1. `scripts/lint.sh` exits 0 (and is enforced by anyone working in the repo).
2. Re-running `scripts/install.sh` on a fresh machine produces a `text-embeddings-router` binary built from the exact SHA pinned in `VERSIONS`, and downloads bge-m3 + bge-reranker-large at the exact snapshot SHAs pinned in `VERSIONS`.
3. `kill -9 $(pgrep -f 'text-embeddings-router.*8084')` → endpoint returns 200 again within 2 × watchdog-interval (≤ 180 s).
4. `scripts/verify.sh` continues to pass 9/9 throughout.

## Phase B — discipline

Ships once Phase A has proven itself in real use. Implementation deferred;
planned later.

### B1. `tests/` directory with fixtures

Plain bash + plutil + curl — no test framework. Each test exits 0 on pass.

Tests:
- `test_plist_shape.sh` — assert required keys exist, `ProcessType=Standard`,
  `KeepAlive.SuccessfulExit=false`, `ProgramArguments` first element is the
  router binary path
- `test_install_idempotent.sh` — `install.sh` can be re-run without breaking
  existing state (LaunchAgents already bootstrapped, models already cached)
- `test_verify_passes_when_up.sh` + `test_verify_fails_when_down.sh` —
  contracts on the verify-script behaviour

### B2. GitHub Actions: lint on every push

`.github/workflows/lint.yml`:
- runs-on: ubuntu-latest (cheaper than macos)
- installs `shellcheck` + a Python plistlib check (no plutil on Linux, but
  Python can validate plist XML)
- runs `scripts/lint.sh` equivalent

Branch protection: required to pass before merge to `main`. Block, don't
advisory — anyone editing this repo is editing live deployment config.

### B3. `scripts/upgrade.sh` — automated TEI bump

Concretely:
1. Read current pinned SHA from `VERSIONS`
2. `git -C ~/llm/src/text-embeddings-inference fetch && git checkout <new-sha>`
3. `cargo install --path router --features metal`
4. Run `./scripts/verify.sh`
5. If verify ✓ → update `VERSIONS` and commit the bump
6. If verify ✗ → checkout the OLD sha, rebuild, restart, fail loud

Bumping is then `./scripts/upgrade.sh <new-sha>`.

## Phase C — operational hygiene

Ships when bored. Implementation deferred; planned later.

### C1. Log rotation via newsyslog

macOS native log-rotation. Drop a snippet at
`config/newsyslog/zen-tei.conf` (installed to `/etc/newsyslog.d/` by
`install.sh` with sudo). Cap each TEI log at 10 MB, keep 5 generations,
gzip rotated ones.

Without this, `~/llm/logs/tei-{rerank,embed}.{out,err}.log` grow unbounded.

### C2. Prometheus metrics expose

TEI ships with `--prometheus-port 9000` available. Currently we don't pass
it, so the metrics endpoint is off.

Document in CLAUDE.md how to enable + what metrics it surfaces (request
rate, p50/p99 latency, queue depth). Add `scripts/metrics.sh` for one-shot
dumps.

Not exposing it on tailnet by default — would require coordinating ports
across services and isn't needed without a Grafana on the other end.

### C3. Stack-overview health command

`scripts/stack-status.sh` — pings broker, litellm, TEI ×2 in parallel,
prints a one-screen table. Mirrors the `verify-broker.sh` shape from
`harkers/mlx-broker`.

```
$ ./scripts/stack-status.sh
broker      :8090   ✓ 14 aliases live
litellm     :4000   ✓ healthy (1024-dim embed verified)
tei-rerank  :8084   ✓ healthy
tei-embed   :8085   ✓ healthy (1024-dim)
watchdog    :--     ✓ ran 12 m ago, no recovery actions
```

## Explicitly not in any phase

- **Full macOS-runner CI** that does fresh `install.sh` end-to-end. Possible
  (`macos-latest` runner exists) but burns GH-Actions minutes and the macOS
  environment isn't representative of zen anyway (no Apple-account, no
  Tailscale, different Mac). Lint CI is sufficient.
- **Generalize beyond zen** (parameterize ports, models, paths via env vars
  or a config file). YAGNI until there's a second machine to deploy to.
- **Open-source polish** — badges, contribution guide, issue templates. Repo
  is public but the expectation is "personal infra you can read" not
  "community project you can contribute to."
- **Bearer-auth wrapper** for TEI. Tailscale ACL is the auth boundary;
  adding HTTP auth duplicates that. Documented in CLAUDE.md.
- **macOS Tahoe launchd-throttle root-cause investigation.** The watchdog in
  A4 papers over it; chasing the actual cause is open-ended.

## Sequencing rationale

- **Phase A:** stop the silent breakage. Pins prevent "install.sh produces
  a different binary tomorrow"; lint catches edits-that-shouldn't-have-merged;
  watchdog solves the macOS Tahoe wrinkle that's currently a manual chore.
  Highest pain-per-hour-invested.
- **Phase B:** lock in the discipline. Tests + CI prove changes don't break;
  `upgrade.sh` automates the routine. Pays off on the 2nd, 10th, 50th TEI
  bump.
- **Phase C:** make it pleasant. Log rotation + metrics + a status command
  are operational nice-to-haves you'd add on a quiet afternoon — they don't
  prevent failure, just polish the day-to-day.

## Files this design will touch / create

```
NEW   VERSIONS                                     (A1, A2)
NEW   rust-toolchain.toml                          (A1)
MOD   scripts/install.sh                           (A1, A2; A4 wiring)
NEW   scripts/lint.sh                              (A3)
NEW   scripts/watchdog.sh                          (A4)
NEW   plist/com.tei.watchdog.plist                 (A4)
MOD   scripts/uninstall.sh                         (A4 wiring)
MOD   README.md                                    (Phase-A pointers)
MOD   CLAUDE.md                                    (Phase-A pointers)
```

Phase B / C files itemised in their sections; no commits needed until those
phases are planned.

## Open questions (already answered with defaults)

- **Watchdog interval:** 90 s (top-of-script constant; tune per taste)
- **Pin strategy:** SHA (TEI doesn't ship release tags)
- **CI policy:** block merge on lint failure (Phase B item)

## Companion plan

`docs/superpowers/plans/2026-05-22-zen-tei-phase-a-plan.md` — the
writing-plans output for Phase A only. B and C will get their own design +
plan when they're picked up.

Wait — the plan lands in `~/projects/macbookm5promax/docs/superpowers/plans/`
(the project's plan directory) NOT in `zen-tei/docs/` because the planning
workflow lives in the parent project. Confirm before writing.
