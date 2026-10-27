# Releasing spark

spark is versioned and released on its own. A release is a tag `vX.Y.Z` on `main`. Work lands on `next`; `main` only receives pull requests from `next`. Versions continue from the first public release, v6.1.0, and a published tag never moves: live one-line installers pin its hash.

## Day to day

Commit on `next`. Put each change under `## [Unreleased]` in `CHANGELOG.md`. Before committing a change to `spark.sh`, run `bash tests/static.sh`, `bash tests/machine_name.sh` and `sh tests/run.sh`.

## Trying a change before a release

`spark.sh` runs with sudo and installs software, and nothing here exercises that behaviour: try the change on a throwaway machine or VM first. Clone this repository, switch to `next` and run `spark.sh` from the checkout:

```sh
git clone <this repository> spark && cd spark && git switch next
bash spark.sh --base https://<forge>/<owner> [--repo dotFiles] [--ref next] [installer arguments...]
```

Clone over https (or from a mirror): a bare machine has no trusted ssh host key for the forge yet, which is the very thing spark sets up. The checkout is what you trust here, not a pinned digest, so this is development and UAT only. The generator page (`index.html`) can build the command too: its "spark version" menu offers `main` or `next` and the command downloads the tip of that branch, unchecked. `--ref` chooses the branch of the repository spark *installs*; the `spark.sh` that runs is the one in your checkout.

## Cutting a release (X.Y.Z)

1. On `next`, tree clean, `bash tests/static.sh`, `bash tests/machine_name.sh` and `sh tests/run.sh` pass.
2. Write `X.Y.Z` into `VERSION`. In `CHANGELOG.md` rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` and add a new empty `## [Unreleased]` above it.
3. Write the checksum: `printf '%s  spark.sh\n' "$(shasum -a 256 spark.sh | cut -d' ' -f1)" > SHA256SUMS`.
4. `sh tests/run.sh --release` must pass (`VERSION`, `SHA256SUMS`, dated changelog section). Commit it as `release: vX.Y.Z`.
5. Open the pull request `next` to `main` and merge it. Never use the forge's "Update Branch" button on that pull request.
6. On `main`: `git fetch && git merge --ff-only origin/main`, then `git tag -a vX.Y.Z -m "spark vX.Y.Z"` and `git push origin refs/tags/vX.Y.Z` (and to any mirror). Tag only main's merge commit, and never move or reuse a tag.

If the 1Password CLI pin has to move, do it with a working commit before step 1: `tools/bump-op-pin.zsh <X.Y.Z> --write` (macOS only; it downloads the package and checks its signature chain first).

## Protect on the forge

Protect `main` and the `v*` tags: spark's release verification assumes only reviewed commits reach `main` and a tag is never moved.
