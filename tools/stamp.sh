#!/bin/sh
# tools/stamp.sh vX.Y.Z — pin index.html to the release tag and the SHA-256 of this repository's spark.sh.
# Run after a new spark.sh is published; tests/run.sh fails while the stamp is stale.
set -eu
cd "$(dirname "$0")/.."
tag="${1:-}"
printf '%s' "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || { echo "usage: tools/stamp.sh vX.Y.Z" >&2; exit 2; }
if command -v sha256sum >/dev/null 2>&1; then sum="$(sha256sum spark.sh | cut -d' ' -f1)"; else sum="$(shasum -a 256 spark.sh | cut -d' ' -f1)"; fi
sed -i.bak -e "s|\(<meta name=\"spark-tag\" content=\"\)[^\"]*\(\">\)|\1$tag\2|" -e "s|\(<meta name=\"spark-sha256\" content=\"\)[^\"]*\(\">\)|\1$sum\2|" index.html
rm -f index.html.bak
echo "index.html pinned to $tag ($sum)"
