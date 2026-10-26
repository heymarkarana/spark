#!/bin/sh
# tests/run.sh — checks the generator page against spark.sh. Needs node and bash.
#   sh tests/run.sh              the development check
#   sh tests/run.sh --release    the release check, run by hand before tagging (RELEASING.md)
# 1. the page's patterns equal spark.sh's, bash and JS agree on fixtures, and the generated command is safe (tests/spark_page_check.js);
# 2. under --release also: VERSION is X.Y.Z, SHA256SUMS is exactly '<sha256>  spark.sh' for this spark.sh, and CHANGELOG.md has a
#    dated section for VERSION. (The page pins nothing: it downloads the tip of a branch, so there is no stamp to compare.)
set -eu
cd "$(dirname "$0")/.."
release=0
case "${1:-}" in
    "") ;;
    --release) release=1 ;;
    *) echo "usage: sh tests/run.sh [--release]" >&2; exit 2 ;;
esac
if [ "$release" = 1 ]; then
    ver="$(tr -d '[:space:]' < VERSION)"
    printf '%s' "$ver" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "FAIL: VERSION '$ver' is not X.Y.Z" >&2; exit 1; }
    if command -v sha256sum >/dev/null 2>&1; then have="$(sha256sum spark.sh | cut -d' ' -f1)"; else have="$(shasum -a 256 spark.sh | cut -d' ' -f1)"; fi
    # An exact comparison, not `sha256sum -c`: macOS's own sha256sum -c exits 0 on a malformed or empty file.
    [ "$(cat SHA256SUMS)" = "$have  spark.sh" ] || { echo "FAIL: SHA256SUMS does not verify spark.sh (it must be exactly '<sha256>  spark.sh')" >&2; exit 1; }
    grep -Eq "^## \\[${ver}\\] - [0-9]{4}-[0-9]{2}-[0-9]{2}\$" CHANGELOG.md || { echo "FAIL: CHANGELOG.md has no dated section for ${ver}" >&2; exit 1; }
fi
node tests/spark_page_check.js index.html spark.sh
