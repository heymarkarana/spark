#!/bin/sh
# tests/run.sh — checks index.html against the spark.sh next to it. Needs node and bash.
#   sh tests/run.sh              the development check
#   sh tests/run.sh --release    the release check, run by hand before tagging (RELEASING.md)
# 1. the page's pinned tag and SHA-256 are the ones of this repository's spark.sh. Under --release a stale stamp FAILS; in development
#    it is a note, because the page stays pinned to the last release until the next one is stamped (tools/stamp.sh);
# 2. the page's patterns equal spark.sh's, bash and JS agree on fixtures, and the generated command is safe (tests/spark_page_check.js);
# 3. under --release also: VERSION names the pinned tag, SHA256SUMS verifies spark.sh, CHANGELOG.md has a dated section for the version.
set -eu
cd "$(dirname "$0")/.."
release=0
case "${1:-}" in
    "") ;;
    --release) release=1 ;;
    *) echo "usage: sh tests/run.sh [--release]" >&2; exit 2 ;;
esac
meta() { sed -n "s/.*<meta name=\"$1\" content=\"\([^\"]*\)\">.*/\1/p" index.html; }
tag="$(meta spark-tag)"; pin="$(meta spark-sha256)"
if command -v sha256sum >/dev/null 2>&1; then have="$(sha256sum spark.sh | cut -d' ' -f1)"; else have="$(shasum -a 256 spark.sh | cut -d' ' -f1)"; fi
if [ "$pin" != "$have" ]; then
    if [ "$release" = 1 ]; then echo "FAIL: index.html pins $pin but spark.sh is $have (run tools/stamp.sh vX.Y.Z, see RELEASING.md)" >&2; exit 1; fi
    echo "note: index.html still pins $tag ($pin); spark.sh has changed since. tools/stamp.sh re-stamps it at release time, and --release requires that." >&2
fi
printf '%s' "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || { echo "FAIL: index.html tag '$tag' is not vX.Y.Z" >&2; exit 1; }
if grep -q '{{' index.html; then echo "FAIL: index.html still has unstamped {{ }} tokens" >&2; exit 1; fi
[ -n "$(git tag --list "$tag" 2>/dev/null)" ] || echo "note: tag $tag is not in this clone yet (tag it after this commit)" >&2
if [ "$release" = 1 ]; then
    [ "v$(tr -d '[:space:]' < VERSION)" = "$tag" ] || { echo "FAIL: VERSION is $(cat VERSION) but index.html pins $tag" >&2; exit 1; }
    # An exact comparison, not `sha256sum -c`: macOS's own sha256sum -c exits 0 on a malformed or empty file.
    [ "$(cat SHA256SUMS)" = "$have  spark.sh" ] || { echo "FAIL: SHA256SUMS does not verify spark.sh (it must be exactly '<sha256>  spark.sh')" >&2; exit 1; }
    grep -Eq "^## \\[${tag#v}\\] - [0-9]{4}-[0-9]{2}-[0-9]{2}\$" CHANGELOG.md || { echo "FAIL: CHANGELOG.md has no dated section for ${tag#v}" >&2; exit 1; }
fi
node tests/spark_page_check.js index.html spark.sh
