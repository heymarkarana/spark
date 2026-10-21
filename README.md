# spark

`spark.sh` takes a bare macOS or Ubuntu machine to the point where one repository's own installer takes over. This copy is **v6.1.0**, byte-identical to the `spark.sh` of dotFiles v6.1.0 (SHA-256 `6a476096672513f1cc15d125f243863934ef99b7ba251da4ce2d3be8b9954c44`).

## Run it

Download, verify, run. Never pipe the network straight into a shell when you can avoid it.

```sh
curl -fsSL --proto '=https' --tlsv1.2 -O "<this repository>/raw/tag/v6.1.0/spark.sh" -O "<this repository>/raw/tag/v6.1.0/SHA256SUMS"
sha256sum -c SHA256SUMS            # macOS: shasum -a 256 -c SHA256SUMS
bash spark.sh --base https://<forge>/<owner> [--repo dotFiles] [--ref v6.1.0] [installer arguments...]
```

Run it as your normal user (it uses `sudo` for the few system steps). As root it refuses unless `SPARK_PRIMARY_USER` names the account that is to own everything.

## What it does

1. Makes sure `git`, `curl`, `zsh` and `jq` are present (Ubuntu: apt; macOS: the Command Line Tools for git, the rest is built in). It never installs Homebrew.
2. Installs the **1Password CLI** from 1Password's own distribution (default yes; `--no-op` skips it) and signs you in on the terminal. Optional: everything works without it, with more typing.
3. Makes sure this machine has an **ssh key for your git host**: an existing key or agent is used; otherwise the host's key is restored from 1Password, or a new ed25519 key is generated and registered on the forge when a token is available (else the public key is printed for you to paste).
4. Clones **one** repository (`--repo`, default `dotFiles`) into `/opt/<repo>` at `--ref` (a release tag, verified; unset: the newest release; a branch: development only), over ssh when the key authenticates, else https.
5. Runs that repository's installer: the command in its `.spark` file, else `./install`. The repository resolves its own dependencies (dotFiles installs Trove, then Beskar, then itself).

## Flags and environment

| Flag | Environment twin | Meaning |
|---|---|---|
| `--repo <name>` | `SPARK_REPO` | repository to install (default `dotFiles`) |
| `--base <url>` | `SPARK_REPO_BASE` | `https://host/<owner>`, `ssh://[user@]host[:port]/<owner>`, or an absolute local path |
| `--ref <ref>` | `SPARK_REF` | unset: newest release tag; `vX.Y.Z`: that release; anything else: a branch |
| `--no-op` | `SPARK_NO_OP=1` | do not install the 1Password CLI |
| `--op-vault <name>` | `SPARK_OP_VAULT` | the 1Password vault holding `df_common` (only when several do) |
| `--plan` | | print what would happen, change nothing |

Also: `SPARK_PRIMARY_USER` (as root), `SPARK_NONINTERACTIVE=1`, `SPARK_SSH_HOST_FPR=SHA256:…` (pin the forge's host key; without it only a key already in your `known_hosts` is trusted), `SPARK_SSH_KEY_FILE`, `SPARK_SSH_KEY_OP_REF=op://vault/item/field`, `SPARK_HTTPS_TOKEN_FILE`. The header of `spark.sh` is the full contract. Security refusals exit 3.

## Trust

`SHA256SUMS` comes from the same repository as `spark.sh`, so it detects a corrupted download, not a compromised repository. The hash of each release is also printed in the dotFiles release notes.
