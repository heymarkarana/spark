#!/bin/bash
# tests/op_signin.sh — the 1Password sign-in of spark.sh (ensure_op), run against the REAL function body.
#   bash tests/op_signin.sh [path/to/spark.sh]
# `op` is scripted: T_ADD and T_SIGNIN list the outcome of each successive `account add` / `signin` (ok or fail), and the terminal is
# a file of answers. What it proves: a failed sign-in offers another attempt (default yes, three at most) and says what will be asked
# again; `account add` (address, email, Secret Key, password, code) is repeated whole until an account is registered, and once it is only
# `signin` (password, code) is repeated; a no or the third failure continues without 1Password; no terminal means no attempt and no question.
set -u
cd "$(dirname "$0")/.."
sh_file="${1:-spark.sh}"
fail=0; n=0
ok()  { n=$((n+1)); echo "ok   $*"; }
bad() { n=$((n+1)); fail=1; echo "FAIL $*" >&2; }
fn() { awk -v name="$1" '$0 ~ "^"name"\\(\\)\\{" {p=1} p {print} p && /^}/ {exit}' "$sh_file"; }
harness="$(mktemp)"; tmp="$(mktemp -d)"
trap 'rm -f "$harness"; rm -rf "$tmp"' EXIT
{
  cat <<'STUBS'
_ok(){ echo "OK: $*"; }
_run(){ echo "RUN: $*"; }
_warn(){ echo "WARN: $*" >&2; }
_spark_seam(){ local nm="$1" d="${2:-}"; printf '%s' "${!nm:-$d}"; }
_spark_noninteractive(){ [[ "${T_NONINT:-0}" == 1 ]]; }
_spark_tty_open(){ :; }
_spark_ask(){ echo "ASKED: $1" >> "$T_DIR/asked"; local a=""; IFS= read -r a <&8 || a=""; printf '%s' "$a"; }
_spark_op_bin(){ _SPARK_OP_BIN=/usr/bin/op; return 0; }
_spark_os(){ echo linux; }
_spark_op_signed_in(){ [[ -e "$T_DIR/signed" ]]; }
_spark_op_has_account(){ [[ -e "$T_DIR/account" ]]; }
nth(){ local list="$1" k="$2" w; set -- $list; w="${!k:-${@: -1}}"; printf '%s' "$w"; }
# `op account add`: the k-th call takes the k-th outcome (the last one repeats)
_spark_op(){ echo add >> "$T_DIR/calls"; local k; k="$(grep -c add "$T_DIR/calls")"
  [[ "$(nth "$T_ADD" "$k")" == ok ]] && { : > "$T_DIR/account"; return 0; }; return 1; }
_spark_op_signin_capture(){ echo signin >> "$T_DIR/calls"; local k; k="$(grep -c signin "$T_DIR/calls")"
  [[ "$(nth "$T_SIGNIN" "$k")" == ok ]] && { : > "$T_DIR/signed"; return 0; }; return 1; }
STUBS
  fn ensure_op
} > "$harness"

# run <answers> <env...>: a fresh bash and a fresh state directory per case
run() {
  local answers="$1"; shift
  rm -rf "$tmp/s"; mkdir -p "$tmp/s"; printf '%s' "$answers" > "$tmp/s/answers"
  RUN_OUT="$(env T_DIR="$tmp/s" SPARK_TTY=/dev/null ARG_NO_OP=0 "$@" bash -c '
    source "$HARNESS"; exec 8< "$T_DIR/answers"; exec 9>&2; ARG_NO_OP=0; ensure_op' 2>&1)"
  RUN_RC=$?
  adds="$(grep -c add "$tmp/s/calls" 2>/dev/null)"; signins="$(grep -c signin "$tmp/s/calls" 2>/dev/null)"
  adds="${adds:-0}"; signins="${signins:-0}"
  ASKED_TEXT="$(cat "$tmp/s/asked" 2>/dev/null)"                                   # the questions put to the terminal
  asked=0; [ -n "$ASKED_TEXT" ] && asked="$(printf '%s\n' "$ASKED_TEXT" | wc -l | tr -d ' ')"
}
export HARNESS="$harness"

# 1. first attempt works: no question
run $'\n' T_ADD="ok" T_SIGNIN="ok"
[ "$adds/$signins/$asked" = "1/1/0" ] && case "$RUN_OUT" in *"OK: 1Password: signed in"*) ok "a first attempt that works asks nothing" ;; *) bad "first: $RUN_OUT" ;; esac || bad "first: calls $adds/$signins/$asked"

# 2. a typo in the address/email/Secret Key (account add fails): asked, Enter retries, the WHOLE add is repeated
run $'\n' T_ADD="fail ok" T_SIGNIN="ok"
[ "$adds/$signins/$asked" = "2/1/1" ] && case "$ASKED_TEXT" in *"the sign-in address, your email, the Secret Key, your password and the authentication code"*) ok "a failed account add offers a retry naming address, email, Secret Key, password and code; Enter repeats the whole add" ;; *) bad "retry text: $ASKED_TEXT" ;; esac || bad "retry: calls $adds/$signins/$asked"

# 3. the account was added but the sign-in failed (wrong password): only signin is repeated, and the question says so
run $'\n' T_ADD="ok" T_SIGNIN="fail ok"
[ "$adds/$signins/$asked" = "1/2/1" ] && case "$ASKED_TEXT" in *"your password and authentication code again"*) ok "once an account exists only the sign-in is repeated (password and code), and the question says so" ;; *) bad "signin-only text: $ASKED_TEXT" ;; esac || bad "signin-only: calls $adds/$signins/$asked"

# 4. a no stops after one attempt and continues without 1Password
run $'n\n' T_ADD="fail" T_SIGNIN="ok"
[ "$adds/$signins/$asked" = "1/0/1" ] && case "$RUN_OUT" in *"WARN: 1Password: not signed in; the forge URL"*) ok "answering n stops after one attempt and continues without 1Password" ;; *) bad "no: $RUN_OUT" ;; esac || bad "no: calls $adds/$signins/$asked"

# 5. three failures: exactly three attempts, two questions, then on without 1Password
run $'\n\n\n' T_ADD="fail" T_SIGNIN="fail"
[ "$adds/$signins/$asked" = "3/0/2" ] && case "$RUN_OUT" in *"WARN: 1Password: not signed in; the forge URL"*) ok "three failures: three attempts, two questions, then on without 1Password" ;; *) bad "3x: $RUN_OUT" ;; esac || bad "3x: calls $adds/$signins/$asked"

# 6. no terminal: no attempt, no question
run '' T_NONINT=1 T_ADD="ok" T_SIGNIN="ok"
[ "$adds/$signins/$asked" = "0/0/0" ] && case "$RUN_OUT" in *"not signed in and no terminal"*) ok "no terminal: no attempt and no question" ;; *) bad "nonint: $RUN_OUT" ;; esac || bad "nonint: calls $adds/$signins/$asked"

# 7. already signed in: nothing is attempted
rm -rf "$tmp/s"; mkdir -p "$tmp/s"; : > "$tmp/s/signed"; printf '' > "$tmp/s/answers"
RUN_OUT="$(env T_DIR="$tmp/s" SPARK_TTY=/dev/null T_ADD=ok T_SIGNIN=ok bash -c 'source "$HARNESS"; exec 8< "$T_DIR/answers"; exec 9>&2; ARG_NO_OP=0; ensure_op' 2>&1)"
[ ! -e "$tmp/s/calls" ] && case "$RUN_OUT" in *"OK: 1Password: signed in"*) ok "an existing session is used: nothing is attempted" ;; *) bad "signed: $RUN_OUT" ;; esac || bad "signed: calls were made"

echo "op_signin: ${n} checks"
exit "$fail"
