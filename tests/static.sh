#!/bin/bash
# tests/static.sh — the invariants spark.sh must keep, checked in well under a second.
#   bash tests/static.sh [path/to/spark.sh]       (default: spark.sh at the repository root)
# spark.sh runs with sudo, installs packages and decides which ssh host key to trust, so these rules are what stand between an
# edit and a mistake nobody sees: it parses; no `eval`, no Homebrew; sudo is called in exactly one wrapper (an absolute path, argv
# only, never through a shell string); every `# GUARD: id` has exactly one `# GUARD-END: id` and ids are unique; the 1Password
# pins are well-formed. Behaviour is not tested here: try a change on a throwaway machine before a release (RELEASING.md).
set -u
cd "$(dirname "$0")/.."
sh_file="${1:-spark.sh}"
[ -f "$sh_file" ] || { echo "static: no such file: $sh_file" >&2; exit 2; }
fail=0
bad() { echo "FAIL: $1" >&2; fail=1; }
code="$(grep -v '^[[:space:]]*#' "$sh_file")"   # code lines only: comments and the header may name what they forbid

bash -n "$sh_file" || bad "$sh_file does not parse"

if printf '%s\n' "$code" | grep -q 'eval'; then bad "eval in a code line"; fi
if printf '%s\n' "$code" | grep -qiw 'brew'; then bad "Homebrew named in a code line (spark never uses it)"; fi
if printf '%s\n' "$code" | grep -qi 'cask'; then bad "a Homebrew cask named in a code line"; fi

n="$(printf '%s\n' "$code" | grep -cE '(^|[;&|(`]|\$\()[[:space:]]*sudo[[:space:]]')"
[ "$n" = 0 ] || bad "a raw sudo command in a code line ($n): sudo goes through the one wrapper"
n="$(printf '%s\n' "$code" | grep -c '/usr/bin/sudo')"
[ "$n" = 1 ] || bad "/usr/bin/sudo must appear exactly once, in the wrapper (found $n)"
if printf '%s\n' "$code" | grep -q 'bash -c'; then bad "bash -c in a code line: no shell strings"; fi

guards="$(grep -o '# GUARD: [A-Za-z0-9-]*' "$sh_file" | sed 's/# GUARD: //')"
dup="$(printf '%s\n' "$guards" | sort | uniq -d)"
[ -z "$dup" ] || bad "GUARD ids used twice: $(echo $dup)"
for id in $guards; do
    [ "$(grep -c "# GUARD-END: ${id}\$" "$sh_file")" = 1 ] || bad "GUARD ${id} has no single GUARD-END"
done
ends="$(grep -c '# GUARD-END: ' "$sh_file")"; starts="$(grep -c '# GUARD: ' "$sh_file")"
[ "$ends" = "$starts" ] || bad "GUARD ($starts) and GUARD-END ($ends) lines do not pair up"

sha="$(sed -n 's/^_SPARK_OP_PKG_SHA256="\(.*\)"$/\1/p' "$sh_file")"
fpr="$(sed -n 's/^_SPARK_OP_SIGNING_FPR="\(.*\)"$/\1/p' "$sh_file")"
printf '%s' "$sha" | grep -Eq '^[0-9a-f]{64}$' || bad "the 1Password .pkg pin is not a SHA-256: '$sha'"
printf '%s' "$fpr" | grep -Eq '^[0-9A-F]{40}$' || bad "the 1Password apt key pin is not a fingerprint: '$fpr'"

[ "$fail" = 0 ] && echo "static: ok ($starts guards)"
exit "$fail"
