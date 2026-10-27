#!/bin/bash
# tests/key_collision.sh — what spark says when the forge already holds a DIFFERENT key under this machine's title, run against the REAL
# function bodies (_spark_forge_register_key, _spark_key_collision_advice, _spark_pub_fpr) with real ssh-keygen keys and a stubbed forge.
#   bash tests/key_collision.sh [path/to/spark.sh]
# The advice depends on what 1Password holds for the same name. If it holds ANOTHER key than the one on this disk, the forge entry is that
# key's registered copy: the advice is to remove the LOCAL key (it is restored on the next run) and never to delete the forge entry. If it
# holds THIS key, the forge entry is stale and deleting it is right. With nothing in the vault, the old advice stays, with a caution.
set -u
cd "$(dirname "$0")/.."
sh_file="${1:-spark.sh}"
fail=0; n=0
ok()  { n=$((n+1)); echo "ok   $*"; }
bad() { n=$((n+1)); fail=1; echo "FAIL $*" >&2; }
command -v ssh-keygen >/dev/null && command -v jq >/dev/null || { echo "key_collision: ssh-keygen and jq are needed"; exit 2; }
fn() { awk -v name="$1" '$0 ~ "^"name"\\(\\)\\{" {p=1} p {print} p && /^}/ {exit}' "$sh_file"; }
harness="$(mktemp)"; tmp="$(mktemp -d)"
trap 'rm -f "$harness"; rm -rf "$tmp"' EXIT
{
  cat <<'STUBS'
_ok(){ echo "OK: $*"; }
_warn(){ echo "WARN: $*"; }
as_user(){ "$@"; }
as_user_piped(){ "$@"; }
_spark_seam(){ local nm="$1" d="${2:-}"; printf '%s' "${!nm:-$d}"; }
_spark_op_signed_in(){ [[ -e "$T/signed" ]]; }
_spark_op_vault(){ _SPARK_VAULT=thevault; return 0; }
# the vault: <item>.<field> files
_spark_op_read(){ local f="$T/vault/$1.$2"; [[ -f "$f" ]] && cat "$f"; }
STUBS
  fn _spark_pub_fpr; fn _spark_key_collision_advice; fn _spark_forge_register_key
} > "$harness"

mkdir -p "$tmp/vault" "$tmp/ssh"
ssh-keygen -q -t ed25519 -N '' -C df_machine-matchbox -f "$tmp/local"      # the key on this disk (new, unregistered)
ssh-keygen -q -t ed25519 -N '' -C df_machine-matchbox -f "$tmp/stored"     # the real machine's key (in the vault, registered on the forge)
printf 'token' > "$tmp/vault/df_common.DF_FORGEJO_API_TOKEN"
LFP="$(ssh-keygen -lf "$tmp/local.pub" | awk '{print $2}')"; SFP="$(ssh-keygen -lf "$tmp/stored.pub" | awk '{print $2}')"
# the forge: POST says 422 (exists); the listing holds ONE key titled df_machine-matchbox, whichever $forge_key says
cat > "$tmp/curl" <<'EOS'
#!/bin/sh
cat >/dev/null
case " $* " in
  *" -X POST "*) printf 422 ;;
  *" -X GET "*)  cat "$T/list.json" ;;
esac
EOS
chmod 755 "$tmp/curl"
forge_has() { jq -nc --arg k "$(cut -d' ' -f1-2 "$1")" '[{id:1,title:"df_machine-matchbox",key:($k+" df_machine-matchbox")}]' > "$tmp/list.json"; }

run() {  # run: register $tmp/local.pub; the vault and the sign-in are whatever the case set up
  RUN_OUT="$(env T="$tmp" SPARK_CURL_BIN="$tmp/curl" HARNESS="$harness" _SPARK_KEY_PATH="$tmp/ssh/id_ed25519" bash -c '
    source "$HARNESS"; _spark_forge_register_key https://forge.test "$T/local.pub" df_machine-matchbox' 2>&1)"; RUN_RC=$?
}

# A. the vault holds ANOTHER key than the disk: the forge entry is its registered copy
forge_has "$tmp/stored.pub"; : > "$tmp/signed"; cp "$tmp/stored.pub" "$tmp/vault/df_machine-matchbox.id_ed25519.pub"
run
[ "$RUN_RC" = 1 ] && ok "a collision is still a failure (rc 1)" || bad "A rc=$RUN_RC"
case "$RUN_OUT" in *"1Password holds this machine's key"*"$SFP"*"do NOT delete it"*"rm -f "*) ok "A: names the stored key's fingerprint, says do NOT delete the forge entry, and gives the rm of the LOCAL key" ;; *) bad "A text: $RUN_OUT" ;; esac
case "$RUN_OUT" in *"not the key on this disk ($LFP)"*) ok "A: names the fingerprint of the key on this disk" ;; *) bad "A local fpr: $RUN_OUT" ;; esac
case "$RUN_OUT" in *"Delete it in Settings"*|*"delete it in Settings"*) bad "A still tells the person to delete the forge entry: $RUN_OUT" ;; *) ok "A: never tells the person to delete the forge entry" ;; esac

# B. the vault holds THIS key and the forge another: the forge entry is stale, deleting it is right
forge_has "$tmp/stored.pub"; cp "$tmp/local.pub" "$tmp/vault/df_machine-matchbox.id_ed25519.pub"
run
case "$RUN_OUT" in *"1Password's copy matches the key on this disk ($LFP)"*"Delete it in Settings"*) ok "B: the vault holds this key, so the forge entry is stale and deleting it is the advice" ;; *) bad "B: $RUN_OUT" ;; esac

# C. nothing in the vault: the old advice, with the caution first
rm -f "$tmp/vault/df_machine-matchbox.id_ed25519.pub"
run
case "$RUN_OUT" in *"Before deleting it: if 1Password holds this machine's key"*"delete the forge entry in Settings"*) ok "C: no vault item: the old advice with the caution" ;; *) bad "C: $RUN_OUT" ;; esac

# D. not signed in: the vault is not even asked
cp "$tmp/stored.pub" "$tmp/vault/df_machine-matchbox.id_ed25519.pub"; rm -f "$tmp/signed"
run
case "$RUN_OUT" in *"Before deleting it"*) ok "D: not signed in: the old advice with the caution (the vault is not read)" ;; *) bad "D: $RUN_OUT" ;; esac

# E. the key on this disk IS on the account: already registered, rc 0 (unchanged behaviour)
forge_has "$tmp/local.pub"; : > "$tmp/signed"
run
[ "$RUN_RC" = 0 ] && case "$RUN_OUT" in *"already registered"*) ok "E: the local key is already on the account: ok, rc 0" ;; *) bad "E: $RUN_OUT" ;; esac || bad "E rc=$RUN_RC"

echo "key_collision: ${n} checks"
exit "$fail"
