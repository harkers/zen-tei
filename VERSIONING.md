# Versioning policy

This repo is **not a Python package** — it ships configs (`plist/`),
scripts (`scripts/`), and documentation that get copied/sourced on the
deployment host. Two version axes coexist:

## 1. Pinned dependencies (`VERSIONS`)

The `VERSIONS` file at the repo root is the source of truth for what a
clean install of zen-tei produces:

- TEI source SHA + router binary version
- Rust toolchain (also pinned in `rust-toolchain.toml`)
- HuggingFace model snapshot SHAs (passed to `hf-cli --revision`)
- `LAST_SMOKE_*` markers — what state the install last verified against

**Bump rules for `VERSIONS`:**

| Change                                             | Discipline                  |
|----------------------------------------------------|-----------------------------|
| TEI router upgrade (new SHA / version)             | Edit + reinstall + smoke    |
| Model weights upgrade (new revision SHA)           | Edit + reinstall + smoke    |
| Rust toolchain bump                                | Edit + rebuild + smoke      |
| `LAST_SMOKE_*` refresh after a verified-good state | Edit + commit, no reinstall |

**Discipline:** "bump intentionally, smoke before commit". The pattern
already used here — `scripts/install.sh` sources `VERSIONS`,
`scripts/verify.sh` proves the pinned state still works, the
`LAST_SMOKE_*` markers record when verification last passed. Keep that.

## 2. Repo release version (semver-ish)

For the configs/scripts/plists themselves, this repo follows semver-flavoured
tagging so consumers (the Mac install plan at `harkers/macbookm5promax`,
operator runbooks) can pin to a known-good zen-tei revision.

**Format:** `MAJOR.MINOR.PATCH` git tags as `vMAJOR.MINOR.PATCH`. No
`pyproject.toml` (this isn't a wheel); the tag is the version.

**Bump rules:**

| Change to shipped configs/scripts/plists                   | Bump  |
|------------------------------------------------------------|-------|
| Breaking change a deploy depends on: launchd plist label rename, env var rename, port change, removed script, removed model | MAJOR |
| Additive: new script, new optional env var, new model alias, new plist  | MINOR |
| Bugfix to an existing script, doc-only changes inside `docs/`, comment-only edits in `plist/` | PATCH |

**Pre-1.0 (0.x.y) waiver:** while `MAJOR == 0`, configs are provisional.
Bump MINOR for breaking *or* additive; bump PATCH for bugfixes. Bump
to `1.0.0` only when the deployed surface (plist labels, ports, script
flags) is committed-to.

**Release process:**

1. Make the change. Update `VERSIONS` if any pinned dep moved.
2. Run `scripts/verify.sh` and refresh the `LAST_SMOKE_*` markers if
   verification passes.
3. Update `CHANGELOG.md` (Keep-a-Changelog format).
4. Tag: `git tag -a v<MAJOR>.<MINOR>.<PATCH> -m "release"` then
   `git push --tags`.
5. Never force-push tags. To retract a bad release: tag the next patch
   with the revert.

## Cross-repo coordination

zen-tei is consumed by:

- [harkers/macbookm5promax](https://github.com/harkers/macbookm5promax) — Mac install plan; references zen-tei plist labels + port conventions in `04-clients/CLAUDE.md`.
- [harkers/dsar-orchestrator](https://github.com/harkers/dsar-orchestrator) — indirectly via TEI HTTP clients (rerank + embed) that conductor adapters call.

Coordination rules:

- Plist label rename or port change is a MAJOR bump — the Mac install
  plan and dsar-orchestrator's TEI client URLs are downstream of those.
- New model alias / new plist is MINOR — additive, no consumer break.
- Breaking changes get coordinated via a GitHub issue on consumers
  before the tag lands.

## What does NOT count as a tag bump

- Changes only in `README.md` at the repo root, unless they document a
  behaviour change.
- Comment-only edits in `CLAUDE.md` (this is an internal-context file).
- Re-formatting / lint-only commits.
- Bumping `LAST_SMOKE_*` markers without any actual config change.

## CHANGELOG.md

Keep-a-Changelog format. One `## [Unreleased]` section accumulates entries
between releases; release process moves them under
`## [<version>] - <date>`.
