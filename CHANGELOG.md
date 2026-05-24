# Changelog

All notable changes to this repo's shipped configs / scripts / plists
are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: see [`VERSIONING.md`](VERSIONING.md). Upstream-pin tracking
lives separately in [`VERSIONS`](VERSIONS).

## [Unreleased]

### Added
- `VERSIONING.md` documenting the repo-release tag scheme + the
  `VERSIONS` pinned-deps discipline.
- `CHANGELOG.md` (this file).

## [0.1.0] - 2026-05-23

Initial tagged release. State as of commit `7b8d0c2` (immediately after
adopting the iterated-version filename convention).

### Added
- TEI rerank + embed stack carved out of the Mac install plan
  (`harkers/macbookm5promax/04-clients/`) into a standalone repo.
- `scripts/install.sh` sources `VERSIONS` for clean reproducible installs.
- `scripts/verify.sh` end-to-end acceptance (9/9 verify checks + 4/4 acceptance per `LAST_SMOKE_RESULT`).
- `plist/` launchd configs for `text-embeddings-router` (rerank + embed
  endpoints) with `KeepAlive` watchdog (Phase A — fixed in `bb15857`).
- `rust-toolchain.toml` pinning Rust 1.95.0 to match `VERSIONS`.
- Phase A architecture docs under `docs/`.

[Unreleased]: https://github.com/harkers/zen-tei/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/harkers/zen-tei/releases/tag/v0.1.0
