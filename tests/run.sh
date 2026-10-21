#!/bin/sh
# tests/run.sh — checks index.html against the spark.sh next to it. Needs node and bash.
#   sh tests/run.sh
# 1. the page's pinned tag and SHA-256 are the ones of this repository's spark.sh (a stale stamp fails here);
# 2. the page's patterns equal spark.sh's, bash and JS agree on fixtures, and the generated command is safe (tests/spark_page_check.js).
set -eu
cd "$(dirname "$0")/.."
meta() { sed -n "s/.*<meta name=\"$1\" content=\"\([^\"]*\)\">.*/\1/p" index.html; }
tag="$(meta spark-tag)"; pin="$(meta spark-sha256)"
if command -v sha256sum >/dev/null 2>&1; then have="$(sha256sum spark.sh | cut -d' ' -f1)"; else have="$(shasum -a 256 spark.sh | cut -d' ' -f1)"; fi
[ "$pin" = "$have" ] || { echo "FAIL: index.html pins $pin but spark.sh is $have (run tools/stamp.sh)" >&2; exit 1; }
printf '%s' "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || { echo "FAIL: index.html tag '$tag' is not vX.Y.Z" >&2; exit 1; }
if grep -q '{{' index.html; then echo "FAIL: index.html still has unstamped {{ }} tokens" >&2; exit 1; fi
[ -n "$(git tag --list "$tag" 2>/dev/null)" ] || echo "note: tag $tag is not in this clone yet (tag it after this commit)" >&2
node tests/spark_page_check.js index.html spark.sh
