# spark

`spark.sh` takes a bare macOS or Ubuntu machine to the point where one repository's own installer takes over. It is a generic bootstrap: it makes sure the minimum tools are present, optionally installs the 1Password CLI, makes sure the machine has an ssh key for your git host, clones **one** repository and runs that repository's installer. The repository's installer checks everything else it needs. spark is versioned and released on its own; see `CHANGELOG.md`.

## Run it

Download, verify, run. Never pipe the network straight into a shell when you can avoid it.

```sh
curl -fsSL --proto '=https' --tlsv1.2 -O "<this repository>/raw/tag/vX.Y.Z/spark.sh" -O "<this repository>/raw/tag/vX.Y.Z/SHA256SUMS"
sha256sum -c SHA256SUMS            # macOS: shasum -a 256 -c SHA256SUMS
bash spark.sh --base https://<forge>/<owner> [--repo dotFiles] [--ref <tag or branch of that repository>] [installer arguments...]
```

Run it as your normal user (it uses `sudo` for the few system steps). As root it refuses unless `SPARK_PRIMARY_USER` names the account that is to own everything.

## What it does

1. Makes sure `git`, `curl`, `zsh` and `jq` are present (Ubuntu: apt; macOS: the Command Line Tools for git, the rest is built in). It never installs Homebrew.
2. Installs the **1Password CLI** from 1Password's own distribution (default yes; `--no-op` skips it) and signs you in on the terminal. Optional: everything works without it, with more typing.
3. Makes sure this machine has an **ssh key for your git host**: an existing key or agent is used; otherwise the host's key is restored from 1Password, or a new ed25519 key is generated and registered on the forge when a token is available (else the public key is printed for you to paste).
4. Clones **one** repository (`--repo`, default `dotFiles`) into `/opt/<repo>` at `--ref` (a release tag, verified; unset: the newest release; a branch: development only), over ssh when the key authenticates, else https.
5. Runs that repository's installer: the command in its `.spark` file, else `./install`. The repository resolves and checks its own dependencies and minimums (see `docs/installer-contract.md`).

## Flags and environment

| Flag | Environment twin | Meaning |
|---|---|---|
| `--repo <name>` | `SPARK_REPO` | repository to install (default `dotFiles`) |
| `--base <url>` | `SPARK_REPO_BASE` | `https://host/<owner>`, `ssh://[user@]host[:port]/<owner>`, or an absolute local path |
| `--ref <ref>` | `SPARK_REF` | unset: newest release tag; `vX.Y.Z`: that release; anything else: a branch |
| `--no-op` | `SPARK_NO_OP=1` | do not install the 1Password CLI |
| `--op-vault <name>` | `SPARK_OP_VAULT` | the 1Password vault holding `df_common` (only when several do) |
| `--machine-name <name>` | `SPARK_MACHINE_NAME` | this machine's name: the ssh key's comment, the forge key's title and the 1Password item `df_machine-<name>`. Without it spark asks, offering `DF_HOSTNAME` when set, else the short hostname (Enter keeps it) |
| `--plan` | | print what would happen, change nothing |

Also: `SPARK_PRIMARY_USER` (as root), `SPARK_NONINTERACTIVE=1`, `SPARK_SSH_HOST_FPR=SHA256:…` (pin the forge's host key; without it only a key already in your `known_hosts` is trusted), `SPARK_SSH_KEY_FILE`, `SPARK_SSH_KEY_OP_REF=op://vault/item/field`, `SPARK_HTTPS_TOKEN_FILE`. The header of `spark.sh` is the full contract. Security refusals exit 3.

## Trust

`SHA256SUMS` comes from the same repository as `spark.sh`, so it detects a corrupted download, not a compromised repository. A release is verified by downloading its tag and comparing the checksum, as in "Run it" above.

The generator page (`index.html`) is a convenience and pins nothing: its command downloads the newest `spark.sh` of the branch you pick (`main`, or `next` for development) and runs it, so you are trusting the repository's current state and TLS to GitHub. Use it for machines you are setting up on purpose; for anything you want verified, use a release.

## Developing and releasing

Five quick checks, all in seconds: `bash tests/static.sh` (the invariants `spark.sh` must keep: it parses, no `eval` or Homebrew, one sudo wrapper, balanced guard markers, well-formed pins), `bash tests/machine_name.sh`, `bash tests/op_signin.sh` and `bash tests/key_collision.sh` (the machine-name step, the 1Password sign-in and the advice on a key-title collision, run against the real function bodies with a scripted terminal, a scripted `op` and real ssh keys) and `sh tests/run.sh` (the generator page agrees with `spark.sh`). Releasing is a handful of manual steps in `RELEASING.md`. The contract a repository meets to be installed by spark is `docs/installer-contract.md`.
