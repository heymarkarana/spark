# Changelog

All notable changes to spark are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/). Versions follow `vX.Y.Z`; a release is a tag on `main`.

## [Unreleased]

### Changed
- **A failed 1Password sign-in is offered again.** A typo in the sign-in address, the email, the Secret Key, the password or the authentication code made `op` stop, and spark went on without 1Password and failed much later, at the clone of a private forge. It now asks "Try again?" (default yes, three attempts at most) and says what will be asked again: the whole `op account add` (address, email, Secret Key, password, code) until an account is registered, then only the sign-in (password, code). A no, or the third failure, continues without 1Password as before; with no terminal nothing is attempted. `tests/op_signin.sh` runs `ensure_op` against a scripted `op` and terminal.

### Fixed
- **A key-title collision no longer tells you to delete the registered key.** When the forge already held a different key under `df_machine-<name>`, spark said "delete it in Settings → SSH Keys". On a rebuilt host that entry is the registered copy of the key stored in 1Password, so following the advice destroyed the good key. spark now reads the vault item of the same name: if 1Password holds another key than the one on this disk it names both fingerprints, says not to delete the forge entry, and gives the `rm` of the LOCAL key (it is restored on the next run); if the vault holds this very key the forge entry is stale and deleting it is the advice; with nothing readable in the vault the old advice stays, behind a caution. `tests/key_collision.sh` runs it with real ssh keys.

### Added
- **spark asks for the machine's name, and `--machine-name` sets it.** The name was whatever `hostname -s` said at the moment spark ran, so a fresh VM called `ubuntu` got a key, a forge key title and a 1Password item named `df_machine-ubuntu`, and a rebuilt host looked for the wrong item. It now asks before the key step (default `DF_HOSTNAME` when set, else the short hostname; Enter keeps it; three tries), takes `--machine-name` / `SPARK_MACHINE_NAME` as the answer, and unattended uses a valid default or stops. A repository's `.spark` can say `args=machine-name` to receive the settled name as `--machine-name <name>`, so it is not asked twice. `tests/machine_name.sh` runs the step against the real function bodies; `docs/installer-contract.md` also now says that the first word of `install=` must contain a slash (`env` looks a bare name up on `PATH`).
- **The forge's host-key pin can come from the fleet's 1Password.** A new machine has no `known_hosts` entry for the forge, so spark stopped until `SPARK_SSH_HOST_FPR` was typed. When none is given, spark now reads the pin from 1Password (`df_common/DF_FORGE_SSH_HOST_FPR`) and compares it exactly, with the same grammar as `SPARK_SSH_HOST_FPR`; a malformed value is ignored with a warning.
- **A person at the terminal can confirm the forge's host key.** With no pin and no known key, spark shows the fingerprints the forge presents and pins the ed25519 one only on an explicit yes (Enter is no), then prints the `op item edit` command that stores it for the next machine. Unattended it still refuses; `accept-new` stays forbidden.
- **spark is its own project.** `spark.sh` is no longer published from dotFiles: this repository holds the source, the 1Password pin tool (`tools/bump-op-pin.zsh`), two quick checks (`tests/static.sh` for the invariants of `spark.sh`, `tests/run.sh` for the generator page) and the release steps (`RELEASING.md`). Versions are spark's own and continue from v6.1.0. The installer contract any repository can meet is written down in `docs/installer-contract.md`. The large dotFiles-era test suites were not carried over; they remain in the dotFiles history (commit `7b594ed`).

### Changed
- **The generator page is no longer pinned to a release.** It built a command for one tag with that release's hash stamped into the page, so it kept handing out the old `spark.sh` after every fix. It now has a "spark version" menu, `main` (the default) or `next`, and the command downloads the newest `spark.sh` of that branch. Nothing pins or checks the download: for a verified install, download a release and compare its checksum, as the README says. The project's own `--ref` field is separate and unchanged. A link can select `main` or `next` and nothing else.
- `tests/run.sh` checks the page's patterns and command safety against `spark.sh`; `--release` is the strict form (`VERSION`, `SHA256SUMS` compared exactly, dated changelog section).

### Removed
- `tools/stamp.sh` and the page's `spark-tag` and `spark-sha256` meta tags: there is nothing left to stamp.

## [6.1.0] - 2026-10-21

### Added
- The first public release: `spark.sh`, `SHA256SUMS` and the generator page (`index.html`), cut from dotFiles v6.1.0.
