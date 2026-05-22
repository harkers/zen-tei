# zen-tei Phase A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land Phase A of the backlog at [`docs/backlog-design-v1.md`](backlog-design-v1.md) — pinned TEI source + Rust toolchain, pinned HF model revisions, a local lint script, and a watchdog LaunchAgent that auto-recovers from the macOS Tahoe respawn-throttle wrinkle. Phase B + C are out of scope.

**Architecture:** Additive only. Existing `plist/com.tei.{rerank,embed}.plist` are unchanged. `scripts/install.sh` becomes pin-aware (sources a new shell-format `VERSIONS` file). New `scripts/lint.sh`, `scripts/watchdog.sh`, and `plist/com.tei.watchdog.plist`. New `rust-toolchain.toml`.

**Tech Stack:** Bash, plutil, shellcheck, macOS LaunchAgents, Hugging Face hf-hub CLI, Cargo + rustup.

**Companion spec:** [`docs/backlog-design-v1.md`](backlog-design-v1.md).

**Acceptance criteria (from the spec):**

1. `scripts/lint.sh` exits 0.
2. Fresh `scripts/install.sh` run produces the pinned-SHA TEI binary and pinned-snapshot models from `VERSIONS`.
3. `kill -9 $(pgrep -f 'text-embeddings-router.*8084')` → `:8084/health` returns 200 again within ≤180 s (2× watchdog interval).
4. `scripts/verify.sh` keeps passing 9/9.

---

## File structure (created or modified)

| File | Role | Created/Modified |
|---|---|---|
| `VERSIONS` | Shell-format pin file. Single source of truth for SHAs the install script and humans consult. | Create |
| `rust-toolchain.toml` | Rustup-honored toolchain pin. `cargo install` respects it automatically. | Create |
| `scripts/install.sh` | Sources `VERSIONS`, clones TEI at the pinned SHA, passes `--revision` to model pulls, installs the watchdog plist. | Modify |
| `scripts/uninstall.sh` | Bootouts the watchdog plist alongside the existing two. | Modify |
| `scripts/lint.sh` | shellcheck `scripts/*.sh` + plutil-lint `plist/*.plist`. | Create |
| `scripts/watchdog.sh` | One pass through both services; kickstart on /health failure. | Create |
| `plist/com.tei.watchdog.plist` | LaunchAgent running watchdog.sh every 90 s. | Create |
| `README.md` | "Quick install" section mentions the pin file + lint. | Modify |
| `CLAUDE.md` | "Pinned versions" + "Watchdog" subsections added. | Modify |
| External: `~/Library/LaunchAgents/com.tei.watchdog.plist` | Installed copy. | Install (in T8) |
| External: `~/llm/logs/tei-watchdog.log` | Watchdog log. | Created on first run |

---

## Task 1: Capture pins to `VERSIONS` + `rust-toolchain.toml`

**Files:**
- Create: `/Users/stu/projects/zen-tei/VERSIONS`
- Create: `/Users/stu/projects/zen-tei/rust-toolchain.toml`

- [ ] **Step 1: Confirm the values from the live system**

```bash
cd /Users/stu/projects/zen-tei
echo "tei sha:  $(git -C ~/llm/src/text-embeddings-inference rev-parse HEAD)"
echo "rust:     $(source ~/.cargo/env && rustc --version | awk '{print $2}')"
echo "router:   $(~/llm/bin/text-embeddings-router --version | awk '{print $2}')"
for m in bge-reranker-large bge-m3; do
  echo "$m:  $(ls -1 /Users/stu/models/mlx/models--BAAI--${m}/snapshots/ | head -1)"
done
```

Expected:

```
tei sha:  5bc4d889c38cf9c75e63617d62779bc0f6628b23
rust:     1.95.0
router:   1.9.3
bge-reranker-large:  55611d7bca2a7133960a6d3b71e083071bbfc312
bge-m3:  5617a9f61b028005a4858fdac845db406aefb181
```

- [ ] **Step 2: Write `VERSIONS`**

```bash
cat > /Users/stu/projects/zen-tei/VERSIONS <<'EOF'
# zen-tei pinned versions — bump intentionally, smoke before commit.
#
# scripts/install.sh sources this file. Humans treat it as the contract
# for "what does a clean install produce?" Bump = edit + commit + run
# scripts/install.sh + run scripts/verify.sh + update LAST_SMOKE_*.

# TEI source we build from. SHA, not branch — TEI doesn't ship release tags.
TEI_SOURCE_SHA=5bc4d889c38cf9c75e63617d62779bc0f6628b23
TEI_ROUTER_VERSION=1.9.3   # text-embeddings-router --version output

# Rust toolchain — also pinned in rust-toolchain.toml so `cargo install` honors it.
RUST_TOOLCHAIN=1.95.0

# HuggingFace model snapshot SHAs — passed to hf-cli --revision so re-installs
# get the exact weights we smoked against.
BGE_RERANKER_LARGE_REV=55611d7bca2a7133960a6d3b71e083071bbfc312
BGE_M3_REV=5617a9f61b028005a4858fdac845db406aefb181

# Last verified-good state.
LAST_SMOKE_DATE=2026-05-22
LAST_SMOKE_RESULT="9/9 verify checks"
EOF
```

- [ ] **Step 3: Write `rust-toolchain.toml`**

```bash
cat > /Users/stu/projects/zen-tei/rust-toolchain.toml <<'EOF'
# rustup honors this when a cargo command runs in any subdir of the repo.
# Bump together with RUST_TOOLCHAIN in VERSIONS.
[toolchain]
channel = "1.95.0"
profile = "default"
EOF
```

- [ ] **Step 4: Verify both files parse**

```bash
cd /Users/stu/projects/zen-tei
( set -a; source ./VERSIONS; set +a; \
  echo "TEI=$TEI_SOURCE_SHA"; \
  echo "RUST=$RUST_TOOLCHAIN"; \
  echo "BGE_M3=$BGE_M3_REV" )
```

Expected (no errors; the three echo lines):

```
TEI=5bc4d889c38cf9c75e63617d62779bc0f6628b23
RUST=1.95.0
BGE_M3=5617a9f61b028005a4858fdac845db406aefb181
```

- [ ] **Step 5: Commit**

```bash
cd /Users/stu/projects/zen-tei
git add VERSIONS rust-toolchain.toml
git commit -m "$(cat <<'EOF'
phase-A/T1: pin TEI source + Rust toolchain + model SHAs

VERSIONS is the shell-format single source of truth scripts/install.sh
will source. rust-toolchain.toml makes cargo honor the pin
automatically in any subdir of the repo.

Pins captured from the live system on 2026-05-22:
- TEI source SHA 5bc4d889 (text-embeddings-router 1.9.3)
- Rust 1.95.0
- BAAI/bge-reranker-large 55611d7b
- BAAI/bge-m3 5617a9f6

Last smoke: 9/9 verify checks (carried over from the original
2026-05-21 install).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Make `scripts/install.sh` pin TEI source

**Files:**
- Modify: `/Users/stu/projects/zen-tei/scripts/install.sh`

- [ ] **Step 1: Read the current install.sh head to confirm what to replace**

```bash
sed -n '1,40p' /Users/stu/projects/zen-tei/scripts/install.sh
```

Expected to find the existing block under "── 2/5 Clone + build TEI ──" that does `git clone --depth=1 https://...` without checking out a specific SHA.

- [ ] **Step 2: Replace the TEI-clone block**

In `scripts/install.sh`, find this block:

```bash
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
```

Replace with:

```bash
echo "── 2/5 Clone + build TEI at pinned SHA ──"
# shellcheck disable=SC1091
source "$REPO_DIR/VERSIONS"
mkdir -p "$(dirname "$SRC_DIR")" "$BIN_DIR"
if [ ! -d "$SRC_DIR" ]; then
    # Full clone (not --depth=1) so we can check out arbitrary SHAs later.
    git clone https://github.com/huggingface/text-embeddings-inference.git "$SRC_DIR"
fi
(
    cd "$SRC_DIR"
    if [ "$(git rev-parse HEAD)" != "$TEI_SOURCE_SHA" ]; then
        git fetch origin
        git checkout "$TEI_SOURCE_SHA"
    fi
    cargo install --path router --features metal
)
ln -sf "$HOME/.cargo/bin/text-embeddings-router" "$BIN_DIR/text-embeddings-router"
INSTALLED_VERSION=$("$BIN_DIR/text-embeddings-router" --version | awk '{print $2}')
if [ "$INSTALLED_VERSION" != "$TEI_ROUTER_VERSION" ]; then
    echo "  WARN: built router $INSTALLED_VERSION but VERSIONS says $TEI_ROUTER_VERSION" >&2
fi
echo "  built: text-embeddings-router $INSTALLED_VERSION"
```

- [ ] **Step 3: Dry-validate the change**

```bash
shellcheck /Users/stu/projects/zen-tei/scripts/install.sh
```

Expected: no errors. (Warnings about `$REPO_DIR` from outside the sourced VERSIONS scope are OK if shellcheck reports them; they're false positives.)

- [ ] **Step 4: Smoke the install path locally**

The TEI source already exists at `~/llm/src/text-embeddings-inference` from the original install. Running the new block should:
- detect existing directory → skip clone
- check HEAD matches pin → skip checkout
- run `cargo install` (no-op rebuild; ~10 s)
- symlink (no-op)
- print "built: text-embeddings-router 1.9.3"

Run only the TEI section of the new install:

```bash
cd /Users/stu/projects/zen-tei && source VERSIONS && (
    cd ~/llm/src/text-embeddings-inference
    test "$(git rev-parse HEAD)" = "$TEI_SOURCE_SHA" && echo "  HEAD matches pin (skip checkout)"
    source ~/.cargo/env && cargo install --path router --features metal 2>&1 | tail -3
)
~/llm/bin/text-embeddings-router --version
```

Expected:

```
  HEAD matches pin (skip checkout)
  Replacing ... v1.9.3 (already installed)  # or similar fast-path
text-embeddings-router 1.9.3
```

- [ ] **Step 5: Commit**

```bash
cd /Users/stu/projects/zen-tei
git add scripts/install.sh
git commit -m "$(cat <<'EOF'
phase-A/T2: scripts/install.sh pins TEI source via VERSIONS

The clone step is no longer `--depth=1` (we need real history to check
out arbitrary SHAs). After clone or already-cloned, the script checks
HEAD against $TEI_SOURCE_SHA from VERSIONS and `git checkout`s only
if mismatched. Built version is verified against $TEI_ROUTER_VERSION
and warns (doesn't fail) on drift.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Pin HF model revisions in `scripts/install.sh`

**Files:**
- Modify: `/Users/stu/projects/zen-tei/scripts/install.sh`

- [ ] **Step 1: Locate the model-pull block**

```bash
grep -n 'huggingface-cli download' /Users/stu/projects/zen-tei/scripts/install.sh
```

Expected: two matches, one for each model, around line 40-50.

- [ ] **Step 2: Add `--revision` arguments**

Find:

```bash
"$HF_CLI" download BAAI/bge-reranker-large
"$HF_CLI" download BAAI/bge-m3
```

Replace with:

```bash
"$HF_CLI" download BAAI/bge-reranker-large --revision "$BGE_RERANKER_LARGE_REV"
"$HF_CLI" download BAAI/bge-m3            --revision "$BGE_M3_REV"
```

`VERSIONS` was already sourced earlier in the script during the TEI step (Task 2), so the variables are in scope.

- [ ] **Step 3: shellcheck**

```bash
shellcheck /Users/stu/projects/zen-tei/scripts/install.sh
```

Expected: no errors.

- [ ] **Step 4: Smoke the model-pull path**

The models are already at the pinned SHAs (we sourced them from disk in T1). Re-running the pull should be a no-op:

```bash
cd /Users/stu/projects/zen-tei && source VERSIONS
HF_HUB_DISABLE_TELEMETRY=1 ~/llm/podcast-env/bin/huggingface-cli \
    download BAAI/bge-reranker-large --revision "$BGE_RERANKER_LARGE_REV" 2>&1 | tail -2
HF_HUB_DISABLE_TELEMETRY=1 ~/llm/podcast-env/bin/huggingface-cli \
    download BAAI/bge-m3 --revision "$BGE_M3_REV" 2>&1 | tail -2
```

Expected: both report the snapshot dir path (no progress bars; nothing new downloaded).

- [ ] **Step 5: Commit**

```bash
cd /Users/stu/projects/zen-tei
git add scripts/install.sh
git commit -m "$(cat <<'EOF'
phase-A/T3: scripts/install.sh pins HF model revisions via VERSIONS

`huggingface-cli download --revision <sha>` ensures re-installs grab
the exact snapshot we smoked against, even if BAAI ever force-pushes
the `main` ref on either repo. SHAs sourced from VERSIONS (already
in scope after T2's source).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `scripts/lint.sh` — shellcheck + plutil

**Files:**
- Create: `/Users/stu/projects/zen-tei/scripts/lint.sh`
- (Possibly fix any issues the linter flags in existing files)

- [ ] **Step 1: Confirm shellcheck is available (brew or already)**

```bash
which shellcheck || brew install shellcheck
```

Expected: a path like `/opt/homebrew/bin/shellcheck`. Install if not present.

- [ ] **Step 2: Write `scripts/lint.sh`**

```bash
cat > /Users/stu/projects/zen-tei/scripts/lint.sh <<'EOF'
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
EOF
chmod +x /Users/stu/projects/zen-tei/scripts/lint.sh
```

- [ ] **Step 3: Run it; expect issues to surface**

```bash
cd /Users/stu/projects/zen-tei && ./scripts/lint.sh
```

Expected: probable shellcheck nits in `install.sh`, `verify.sh`, `uninstall.sh` (unquoted vars, SC2086, etc.). Plist lints should pass (we use plutil-lint regularly).

- [ ] **Step 4: Fix flagged issues inline**

For each shellcheck finding, either fix the underlying issue (quote a variable, use `[[ ]]` over `[ ]`, etc.) or add a targeted `# shellcheck disable=SCxxxx` with a one-line reason. Don't disable globally.

Re-run `./scripts/lint.sh` after each fix until it exits 0.

If a finding is high-effort to fix and tangential to Phase A, defer with a tracked comment in `scripts/lint.sh` listing exclusions and link to a future cleanup task. (Prefer fixing.)

- [ ] **Step 5: Re-run, expect clean**

```bash
cd /Users/stu/projects/zen-tei && ./scripts/lint.sh
echo "exit: $?"
```

Expected: ends with `═════ lint clean ═════` and `exit: 0`.

- [ ] **Step 6: Commit**

```bash
cd /Users/stu/projects/zen-tei
git add scripts/
git commit -m "$(cat <<'EOF'
phase-A/T4: scripts/lint.sh — shellcheck + plutil locally

One command for "is the repo lint-clean?" Runs shellcheck across
scripts/*.sh and plutil -lint across plist/*.plist. Exits non-zero if
anything fails; designed to be the contract a future pre-commit hook
or CI lint job (Phase B) will run.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Watchdog script

**Files:**
- Create: `/Users/stu/projects/zen-tei/scripts/watchdog.sh`

- [ ] **Step 1: Write `scripts/watchdog.sh`**

```bash
cat > /Users/stu/projects/zen-tei/scripts/watchdog.sh <<'EOF'
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
EOF
chmod +x /Users/stu/projects/zen-tei/scripts/watchdog.sh
```

- [ ] **Step 2: Manual smoke — happy path (both services up)**

```bash
cd /Users/stu/projects/zen-tei
./scripts/watchdog.sh
echo "exit: $?"
wc -l ~/llm/logs/tei-watchdog.log 2>/dev/null || echo "(no log yet — good)"
```

Expected: silent exit 0; log file either doesn't exist or has 0 new lines (both services were healthy).

- [ ] **Step 3: Manual smoke — failure path**

```bash
# Kill one TEI, run watchdog, watch it recover
RPID=$(pgrep -f 'text-embeddings-router.*8084' | head -1)
echo "killing rerank pid=$RPID"
kill -9 "$RPID"
sleep 2
./scripts/watchdog.sh
echo "watchdog exit: $?"
sleep 8   # give kickstart time
curl -s -o /dev/null -w "rerank :8084 → %{http_code}\n" http://127.0.0.1:8084/health
tail -3 ~/llm/logs/tei-watchdog.log
```

Expected:
- watchdog logs the kickstart
- after the 8 s sleep, `:8084` returns 200 again
- last line of watchdog log is the kickstart entry

- [ ] **Step 4: shellcheck**

```bash
cd /Users/stu/projects/zen-tei && ./scripts/lint.sh
```

Expected: `═════ lint clean ═════`.

- [ ] **Step 5: Commit**

```bash
cd /Users/stu/projects/zen-tei
git add scripts/watchdog.sh
git commit -m "$(cat <<'EOF'
phase-A/T5: scripts/watchdog.sh — recover from launchd throttle

One pass through com.tei.rerank + com.tei.embed: curl /health, and if
HTTP 000, launchctl kickstart the service. Logs each recovery attempt
to ~/llm/logs/tei-watchdog.log with an ISO timestamp.

Designed to be invoked every 90 s by the LaunchAgent in T6. Manual
smoke confirms it recovers a SIGKILL'd TEI process within ~8 s of
being invoked.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Watchdog LaunchAgent + install/uninstall wiring

**Files:**
- Create: `/Users/stu/projects/zen-tei/plist/com.tei.watchdog.plist`
- Modify: `/Users/stu/projects/zen-tei/scripts/install.sh`
- Modify: `/Users/stu/projects/zen-tei/scripts/uninstall.sh`

- [ ] **Step 1: Write the watchdog plist**

```bash
cat > /Users/stu/projects/zen-tei/plist/com.tei.watchdog.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key><string>/Users/stu</string>
    </dict>

    <key>Label</key>
    <string>com.tei.watchdog</string>

    <key>ProgramArguments</key>
    <array>
        <string>/Users/stu/projects/zen-tei/scripts/watchdog.sh</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>StartInterval</key>
    <integer>90</integer>

    <key>StandardOutPath</key>
    <string>/Users/stu/llm/logs/tei-watchdog.out.log</string>

    <key>StandardErrorPath</key>
    <string>/Users/stu/llm/logs/tei-watchdog.err.log</string>
</dict>
</plist>
EOF
```

- [ ] **Step 2: plutil -lint**

```bash
plutil -lint /Users/stu/projects/zen-tei/plist/com.tei.watchdog.plist
```

Expected: `OK`.

- [ ] **Step 3: Wire into `scripts/install.sh`**

Find the existing block under "── 4/5 Install LaunchAgents ──" that does:

```bash
cp "$REPO_DIR/plist/com.tei.rerank.plist" "$HOME/Library/LaunchAgents/"
cp "$REPO_DIR/plist/com.tei.embed.plist"  "$HOME/Library/LaunchAgents/"
launchctl bootout "gui/$(id -u)/com.tei.rerank" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.tei.embed"  2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.tei.rerank.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.tei.embed.plist"
```

Add the watchdog alongside:

```bash
cp "$REPO_DIR/plist/com.tei.rerank.plist"   "$HOME/Library/LaunchAgents/"
cp "$REPO_DIR/plist/com.tei.embed.plist"    "$HOME/Library/LaunchAgents/"
cp "$REPO_DIR/plist/com.tei.watchdog.plist" "$HOME/Library/LaunchAgents/"
launchctl bootout "gui/$(id -u)/com.tei.rerank"   2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.tei.embed"    2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.tei.watchdog" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.tei.rerank.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.tei.embed.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.tei.watchdog.plist"
```

Then the existing kickstart block:

```bash
launchctl kickstart "gui/$(id -u)/com.tei.rerank"
launchctl kickstart "gui/$(id -u)/com.tei.embed"
```

becomes:

```bash
launchctl kickstart "gui/$(id -u)/com.tei.rerank"
launchctl kickstart "gui/$(id -u)/com.tei.embed"
launchctl kickstart "gui/$(id -u)/com.tei.watchdog"
```

- [ ] **Step 4: Wire into `scripts/uninstall.sh`**

Find:

```bash
for svc in com.tei.rerank com.tei.embed; do
    launchctl bootout "gui/$(id -u)/$svc" 2>/dev/null && echo "bootout: $svc" \
        || echo "$svc: not loaded"
done

for plist in com.tei.rerank.plist com.tei.embed.plist; do
```

Replace both lists with three entries each:

```bash
for svc in com.tei.rerank com.tei.embed com.tei.watchdog; do
    launchctl bootout "gui/$(id -u)/$svc" 2>/dev/null && echo "bootout: $svc" \
        || echo "$svc: not loaded"
done

for plist in com.tei.rerank.plist com.tei.embed.plist com.tei.watchdog.plist; do
```

- [ ] **Step 5: shellcheck + plutil**

```bash
cd /Users/stu/projects/zen-tei && ./scripts/lint.sh
```

Expected: clean.

- [ ] **Step 6: Commit**

```bash
cd /Users/stu/projects/zen-tei
git add plist/com.tei.watchdog.plist scripts/install.sh scripts/uninstall.sh
git commit -m "$(cat <<'EOF'
phase-A/T6: watchdog LaunchAgent + install/uninstall wiring

plist/com.tei.watchdog.plist: StartInterval=90s, RunAtLoad=true, no
KeepAlive (each invocation is independent — launchd fires it on its
schedule). Runs scripts/watchdog.sh.

scripts/install.sh and scripts/uninstall.sh extended in parallel to
bootstrap/bootout the watchdog alongside the existing two TEI
LaunchAgents. Kickstart loop also extended so the watchdog's first
tick happens at install time, not 90 s later.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: README + CLAUDE.md updates

**Files:**
- Modify: `/Users/stu/projects/zen-tei/README.md`
- Modify: `/Users/stu/projects/zen-tei/CLAUDE.md`

- [ ] **Step 1: README — add lint + VERSIONS callouts to the install section**

In `README.md`, find the "Quick install" section. After the `./scripts/verify.sh` line, add:

```markdown

`VERSIONS` (at the repo root) is the single source of truth for the
TEI source SHA, Rust toolchain, and HuggingFace model revisions the
install will produce. Bump = edit VERSIONS + re-run install.sh +
re-run verify.sh + commit.

Before committing changes that touch `scripts/` or `plist/`, run:

```bash
./scripts/lint.sh
```

(shellcheck + plutil; pre-commit-friendly.)
```

- [ ] **Step 2: CLAUDE.md — add a "Pinned versions" subsection**

In `CLAUDE.md`, find "## What runs" and add a subsection BEFORE it:

```markdown
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
```

- [ ] **Step 3: CLAUDE.md — add a "Watchdog" subsection under the existing "Known wrinkle"**

Find the "## Known wrinkle — macOS Tahoe respawn throttle" section. After its existing content, add:

```markdown
### Watchdog (com.tei.watchdog)

The macOS Tahoe throttle is papered over by `scripts/watchdog.sh`,
invoked every 90 s by `plist/com.tei.watchdog.plist`. The watchdog
curls each `/health` endpoint and `launchctl kickstart`s any service
that doesn't respond. Each recovery is logged with an ISO timestamp to
`~/llm/logs/tei-watchdog.log`.

Inspect recent recoveries:

```bash
tail -20 ~/llm/logs/tei-watchdog.log
```

Tune the interval by editing `plist/com.tei.watchdog.plist`'s
`StartInterval` (90 → larger for less launchd noise, smaller for
faster recovery). 60 s is the floor before launchd starts complaining;
30 s is the absolute minimum allowed by launchd.
```

- [ ] **Step 4: lint**

```bash
cd /Users/stu/projects/zen-tei && ./scripts/lint.sh
```

Expected: clean. (Lint doesn't touch markdown, but confirm the scripts/plists weren't touched accidentally.)

- [ ] **Step 5: Commit**

```bash
cd /Users/stu/projects/zen-tei
git add README.md CLAUDE.md
git commit -m "$(cat <<'EOF'
phase-A/T7: README + CLAUDE.md — Pinned versions + Watchdog sections

README: short pointer to VERSIONS and the lint contract in the install
section so an outside operator sees them on first read.

CLAUDE.md: new "Pinned versions" section above "What runs" describes
the VERSIONS file + bump procedure. New "Watchdog" subsection inside
the existing "Known wrinkle" section documents the throttle workaround.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Deploy + final acceptance

**Files:** none modified. Operator runs the install + acceptance commands.

- [ ] **Step 1: Re-run install to deploy the watchdog**

```bash
cd /Users/stu/projects/zen-tei && ./scripts/install.sh 2>&1 | tail -10
```

Expected: install reaches the "── Wait for both endpoints ──" line, both ports report ready, watchdog bootstrap'd + kickstarted. No errors.

- [ ] **Step 2: Confirm watchdog is registered + running on schedule**

```bash
launchctl print "gui/$(id -u)/com.tei.watchdog" 2>&1 | grep -E "state|runs|interval|program" | head -6
```

Expected:

```
    state = waiting (or running if just fired)
    runs = ≥ 1
    interval = 90 (or similar)
    program = /Users/stu/projects/zen-tei/scripts/watchdog.sh
```

- [ ] **Step 3: AC#1 — `scripts/lint.sh` exits 0**

```bash
cd /Users/stu/projects/zen-tei && ./scripts/lint.sh
echo "exit: $?"
```

Expected: `═════ lint clean ═════` and `exit: 0`.

- [ ] **Step 4: AC#2 — fresh install produces pinned artefacts**

```bash
cd /Users/stu/projects/zen-tei && source VERSIONS
echo "router version installed:  $(~/llm/bin/text-embeddings-router --version | awk '{print $2}')"
echo "router version pinned:     $TEI_ROUTER_VERSION"
echo "tei source HEAD:           $(git -C ~/llm/src/text-embeddings-inference rev-parse HEAD)"
echo "tei source pinned:         $TEI_SOURCE_SHA"
echo "bge-reranker-large HEAD:   $(ls -1 /Users/stu/models/mlx/models--BAAI--bge-reranker-large/snapshots/ | head -1)"
echo "bge-reranker-large pinned: $BGE_RERANKER_LARGE_REV"
echo "bge-m3 HEAD:               $(ls -1 /Users/stu/models/mlx/models--BAAI--bge-m3/snapshots/ | head -1)"
echo "bge-m3 pinned:             $BGE_M3_REV"
```

Expected: each "installed" / "HEAD" value matches the corresponding "pinned" value.

- [ ] **Step 5: AC#3 — kill -9 auto-recovers within ≤180 s**

```bash
RPID=$(pgrep -f 'text-embeddings-router.*8084' | head -1)
EPID=$(pgrep -f 'text-embeddings-router.*8085' | head -1)
echo "before: rerank=$RPID embed=$EPID"
kill -9 "$RPID" "$EPID"
echo "killed at $(date +%H:%M:%S); waiting up to 180 s for both endpoints..."
START=$(date +%s)
for port in 8084 8085; do
    while ! curl -s -m 2 -o /dev/null "http://127.0.0.1:${port}/health"; do
        sleep 5
        if [ $(($(date +%s) - START)) -gt 180 ]; then
            echo "  TIMEOUT: $port still down after 180 s" >&2
            break
        fi
    done
    if curl -s -m 2 -o /dev/null "http://127.0.0.1:${port}/health"; then
        echo "  $port recovered after $(($(date +%s) - START)) s"
    fi
done
echo ""
echo "watchdog log (recovery entries):"
tail -5 ~/llm/logs/tei-watchdog.log 2>/dev/null
```

Expected: both ports recover well within 180 s (watchdog runs every 90 s, kickstart + warmup ~10 s, so worst-case is ~100 s). Watchdog log shows the recovery entries.

- [ ] **Step 6: AC#4 — `scripts/verify.sh` keeps passing 9/9**

```bash
cd /Users/stu/projects/zen-tei && ./scripts/verify.sh
echo "exit: $?"
```

Expected: `═════ 9 passed, 0 failed ═════` and `exit: 0`.

- [ ] **Step 7: Update LAST_SMOKE_* in VERSIONS + commit**

```bash
cd /Users/stu/projects/zen-tei
# After all 4 ACs pass, refresh the last-smoke marker
TODAY=$(date +%Y-%m-%d)
sed -i.bak \
    -e "s/^LAST_SMOKE_DATE=.*/LAST_SMOKE_DATE=${TODAY}/" \
    -e 's/^LAST_SMOKE_RESULT=.*/LAST_SMOKE_RESULT="9\/9 verify checks + 9\/9 acceptance"/' \
    VERSIONS
rm VERSIONS.bak
git diff VERSIONS
git add VERSIONS
git commit -m "$(cat <<'EOF'
phase-A/T8: refresh LAST_SMOKE_* after Phase A acceptance

Phase A landed: pinned TEI source + Rust + model SHAs (T1-T3), lint
script (T4), watchdog script + LaunchAgent (T5-T6), docs (T7).

All 4 spec acceptance criteria pass on the live system:
1. scripts/lint.sh exits 0
2. fresh install produces pinned-SHA binary + pinned-snapshot models
3. kill -9 → endpoint recovers well within 180 s (watchdog interval 90 s)
4. scripts/verify.sh continues to pass 9/9

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 8: Push**

```bash
cd /Users/stu/projects/zen-tei && git push origin main 2>&1 | tail -3
```

Expected: 8 commits land on `harkers/zen-tei` main.

---

## Self-review (writing-plans skill checklist)

**Spec coverage:**

| Spec section | Covered by |
|---|---|
| A1 (pin TEI source + Rust) | T1 (VERSIONS + rust-toolchain.toml) + T2 (install.sh edits) |
| A2 (pin model revisions) | T1 (VERSIONS) + T3 (install.sh edits) |
| A3 (scripts/lint.sh) | T4 |
| A4 (watchdog) | T5 (script) + T6 (plist + install/uninstall wiring) |
| Phase A acceptance #1-4 | T8 walks all four AC bullets |
| Documentation | T7 (README + CLAUDE.md) |

No gaps.

**Placeholder scan:** searched for `TBD|FIXME|fill in|similar to|implement later`. The only `TODO`-adjacent text is in T4 Step 4's guidance to "fix or disable inline" — that's intentional (the lint-fix iteration loop). No real placeholders.

**Type consistency:** `VERSIONS` variable names (`TEI_SOURCE_SHA`, `TEI_ROUTER_VERSION`, `RUST_TOOLCHAIN`, `BGE_RERANKER_LARGE_REV`, `BGE_M3_REV`, `LAST_SMOKE_DATE`, `LAST_SMOKE_RESULT`) used consistently across T1 (write), T2 (source + use), T3 (use), T7 (CLAUDE.md mention), T8 (verify-against + update). Service labels `com.tei.rerank`, `com.tei.embed`, `com.tei.watchdog` consistent across T5-T8. Ports `8084` / `8085` consistent throughout.

---

## Execution Handoff

**Plan complete and saved to `/Users/stu/projects/zen-tei/docs/phase-a-plan.md`.** Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, two-stage review between, fast iteration. Best for 8 tasks of mostly mechanical shell + plist work.
2. **Inline Execution** — execute tasks in this session using executing-plans, batched with checkpoints. Visible step-by-step.

Which approach?
