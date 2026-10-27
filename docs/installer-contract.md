# The installer contract

spark gets a bare machine started and then hands over to **one repository's own installer**. This page is what a repository must provide to be installed by spark, and what spark guarantees the installer. The header of `spark.sh` is the full flag reference; this page is the contract between spark and the installer. spark does not read lock files, clone sibling repositories or install a repository's dependencies: the installer owns all of that, including checking every software minimum it needs, so the repository also installs on its own from a plain clone, without spark.

## What a repository provides

A repository may carry a `.spark` file at its root: `key=value` lines, `#` starts a comment.

| Key | Rule |
|---|---|
| `install=` | argv relative to the repository, split on spaces, no shell: plain words, no `..`, the first word starting with neither `/` nor `-` and existing in the repository. Required when `.spark` exists (else exit 3). **The first word must contain a slash** (`./install.sh`, `bin/tool`): spark runs it as `cd <repo> && env <word> <args>`, and `env` looks a bare name up on `PATH` instead of in the repository (exit 127). |
| `args=` | flags spark passes on to the installer, from the allow-list `machine-name` (anything else is exit 3). With `args=machine-name`, a machine name spark settled (`--machine-name`, or asked at the terminal) is appended as `--machine-name <name>`, so the installer does not ask again. Without it the name is used for the ssh key only and not passed on. |
| `needs=` | tools the installer needs on PATH before it starts, from the allow-list `zsh jq git curl gnupg age` (anything else is exit 3). Missing ones are installed with apt on Ubuntu and stop spark on macOS. |

Without `.spark`, spark runs `./install` (it must be executable). A release is a tag `vX.Y.Z` on the repository's `main`, whose `VERSION` file contains exactly `X.Y.Z`; spark verifies both before it installs a release (`--ref` unset or a tag). Any other `--ref` is a branch install: development only, nothing verified.

## What spark gives the installer

- **Where and who.** The checkout is `/opt/<repo>`, owned by the primary user. The installer runs there, as that user (never root; as root spark runs it through `sudo -u <owner>`).
- **Arguments.** spark's remaining arguments are appended to the `install=` argv. `--answers <file>` is made absolute and checked readable first; `--skip-interview` and `--no-interview` pass through.
- **Non-interactive.** Without a terminal, or with `--skip-interview`, `--no-interview` or `SPARK_NONINTERACTIVE=1`, the installer gets `TROVE_NONINTERACTIVE=1`.
- **A pinned environment.** All `DF_*`, `ATLAS_*`, `TROVE_*`, `BESKAR_*`, `GIT_*`, `SUDO_*` and `SPARK_*` variables are removed; `TROVE_HOME`, `BESKAR_HOME` and `DF_HOME` are pinned under `/opt`; `/usr/local/bin` is on PATH; the operator's `LC_ALL` is restored. `OP_*` and proxy variables pass through. The one `DF_*` value that crosses is `DF_INSTALL_OPTIONAL` (`all`, `none` or a comma-separated list), after a grammar check.
- **The 1Password CLI.** When it is installed and signed in, `op` works for the installer, and `--op-vault <name>` is passed on.
- **The machine's name.** The ssh key, the forge key title and the 1Password item `df_machine-<name>` are named after it, so it is settled before the key step: `--machine-name`, or asked at the terminal (default `DF_HOSTNAME` when set, else `hostname -s`; unattended, a valid default is used and an invalid one stops the run). It reaches the installer only through `args=machine-name`.
- **A trusted forge key.** After the clone, the pinned host key of the forge is kept in the owner's `~/.ssh/known_hosts` as a managed block, so the installer's later ssh calls are strict about the same key.

## What spark never does

It never uses Homebrew, never installs the repository's dependencies, never reads `df.env` or a lock file, never prints the answers file (it passes the path), and never accepts a first-seen host key unless the key matches a pin or a person at a terminal checks the fingerprint and says yes (unattended, it refuses; `accept-new` is never used).

## Exit codes

0 done · 1 a failure (named) · 3 a security or verification refusal · 130, 143 and 129 on INT, TERM and HUP after cleanup. An installer's non-zero exit stops spark with exit 1, naming that code.

## Names that are still dotFiles' own

spark still carries a few names from the project it was written for: the default `--repo dotFiles`, the 1Password items `df_common` and `df_machine-<host>`, and the fields `DF_FORGEJO_API_TOKEN`, `DF_FORGEJO_URL` and `DF_FORGE_SSH_HOST_FPR`. Making them configurable is planned work; until then they are the defaults and the only supported values.
