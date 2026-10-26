#!/usr/bin/env zsh
# bump-op-pin — compute the pins spark.sh carries for the 1Password CLI, after the same checks spark makes (D097).
#
# Downloads the macOS universal .pkg of the given version from 1Password's CDN over https, checks its signature chain (pkgutil:
# exit 0 and chain entry 1 exactly "Developer ID Installer: AgileBits Inc. (2BUA8C4S2C)"), prints the lines to put at the top of
# spark.sh, and, with --write, edits them in place. Never run on a release tag's checkout: the pin changes with a working commit.
# macOS only (pkgutil). The apt signing-key fingerprint is not computed here: it changes only if 1Password rotates its key
# (compare with Beskar's BESKAR_OP_SIGNING_FPR when it does).
#
#   tools/bump-op-pin.zsh <version, e.g. 2.41.0> [--write]
set -euo pipefail
_root="${0:A:h:h}"
_ver="${1:-}"; _write=0
[[ "${2:-}" == --write ]] && _write=1
[[ "$_ver" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 "usage: tools/bump-op-pin.zsh <X.Y.Z> [--write]"; exit 2; }
command -v pkgutil >/dev/null 2>&1 || { print -u2 "bump-op-pin: pkgutil is needed (macOS)"; exit 1; }
_signer="Developer ID Installer: AgileBits Inc. (2BUA8C4S2C)"
_url="https://cache.agilebits.com/dist/1P/op2/pkg/v${_ver}/op_apple_universal_v${_ver}.pkg"
_tmp="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/op-pin.XXXXXX")"
trap 'rm -rf -- "$_tmp"' EXIT
curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --max-redirs 3 -o "${_tmp}/op.pkg" "$_url"
_sig="$(LC_ALL=C pkgutil --check-signature "${_tmp}/op.pkg")" || { print -u2 "bump-op-pin: the package signature does not verify"; exit 1; }
printf '%s\n' "$_sig" | grep -qF "1. ${_signer}" || { print -u2 "bump-op-pin: the package is not signed by '${_signer}'"; exit 1; }
_sha="$(shasum -a 256 -- "${_tmp}/op.pkg" | cut -d' ' -f1)"
print -r -- "_SPARK_OP_VERSION=\"${_ver}\""
print -r -- "_SPARK_OP_PKG_SHA256=\"${_sha}\""
if (( _write )); then
    sed -i.bak -e "s/^_SPARK_OP_VERSION=\".*\"/_SPARK_OP_VERSION=\"${_ver}\"/" -e "s/^_SPARK_OP_PKG_SHA256=\".*\"/_SPARK_OP_PKG_SHA256=\"${_sha}\"/" "${_root}/spark.sh"
    rm -f -- "${_root}/spark.sh.bak"
    print -r -- "written to spark.sh (review the diff, then commit)"
fi
