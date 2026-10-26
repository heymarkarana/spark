# Changelog

All notable changes to spark are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/). Versions follow `vX.Y.Z`; a release is a tag on `main`.

## [Unreleased]

### Added
- **The forge's host-key pin can come from the fleet's 1Password.** A new machine has no `known_hosts` entry for the forge, so spark stopped until `SPARK_SSH_HOST_FPR` was typed. When none is given, spark now reads the pin from 1Password (`df_common/DF_FORGE_SSH_HOST_FPR`) and compares it exactly, with the same grammar as `SPARK_SSH_HOST_FPR`; a malformed value is ignored with a warning.
- **A person at the terminal can confirm the forge's host key.** With no pin and no known key, spark shows the fingerprints the forge presents and pins the ed25519 one only on an explicit yes (Enter is no), then prints the `op item edit` command that stores it for the next machine. Unattended it still refuses; `accept-new` stays forbidden.
- **spark is its own project.** `spark.sh` is no longer published from dotFiles: this repository holds the source, the 1Password pin tool (`tools/bump-op-pin.zsh`), two quick checks (`tests/static.sh` for the invariants of `spark.sh`, `tests/run.sh` for the generator page) and the release steps (`RELEASING.md`). Versions are spark's own and continue from v6.1.0. The installer contract any repository can meet is written down in `docs/installer-contract.md`. The large dotFiles-era test suites were not carried over; they remain in the dotFiles history (commit `7b594ed`).

### Changed
- `tests/run.sh --release` is the strict form of the page check (stamp, `VERSION`, `SHA256SUMS` compared exactly, dated changelog section); the plain form notes a stale stamp instead of failing, because the page stays pinned to the last release while `next` moves.

## [6.1.0] - 2026-10-21

### Added
- The first public release: `spark.sh`, `SHA256SUMS` and the generator page (`index.html`), cut from dotFiles v6.1.0.
