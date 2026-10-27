#!/bin/bash
# tests/machine_name.sh — the machine-name step of spark.sh, run against the REAL function bodies.
#   bash tests/machine_name.sh [path/to/spark.sh]
# spark.sh runs its whole job when sourced, so the functions under test are cut out of it by name and evaluated here with stubs for
# the terminal, the die helpers and the process helpers. What it proves: --machine-name is the answer and is validated; without it
# the default is DF_HOSTNAME, else the hostname, and a person confirms or changes it (three tries); unattended a valid default is
# used and an invalid one stops the run; the name is passed on only to an installer whose .spark says args=machine-name.
set -u
cd "$(dirname "$0")/.."
sh_file="${1:-spark.sh}"
fail=0; n=0
ok()  { n=$((n+1)); echo "ok   $*"; }
bad() { n=$((n+1)); fail=1; echo "FAIL $*" >&2; }

fn() { awk -v name="$1" '$0 ~ "^"name"\\(\\)\\{" {p=1} p {print} p && /^}/ {exit}' "$sh_file"; }
re_host="$(sed -n "s/^_SPARK_RE_HOSTLABEL=\\(.*\\)\$/\\1/p" "$sh_file")"
re_vault="$(sed -n "s/^_SPARK_RE_VAULT=\\(.*\\)\$/\\1/p" "$sh_file")"
re_repo="$(sed -n "s/^_SPARK_RE_REPO=\\(.*\\)\$/\\1/p" "$sh_file")"
harness="$(mktemp)"; tmp="$(mktemp -d)"
trap 'rm -f "$harness"; rm -rf "$tmp"' EXIT
{
  echo "_SPARK_RE_HOSTLABEL=$re_host"; echo "_SPARK_RE_VAULT=$re_vault"; echo "_SPARK_RE_REPO=$re_repo"
  cat <<'STUBS'
die(){ echo "DIE: $*" >&2; exit 1; }
die3(){ echo "DIE3: $*" >&2; exit 3; }
_ok(){ echo "OK: $*"; }
_run(){ echo "RUN: $*"; }
_warn(){ echo "WARN: $*" >&2; }
hostname(){ printf '%s\n' "${STUB_HOSTNAME:-ubuntu}"; }
_spark_seam(){ local nm="$1" d="${2:-}"; printf '%s' "${!nm:-$d}"; }
_spark_noninteractive(){ [[ "${T_NONINT:-0}" == 1 ]]; }
_spark_tty_open(){ :; }
# a scripted terminal: successive answers come from successive lines of $T_ANSWERS
_spark_ask(){ echo "ASKED: $1" >> "$T_LOG"; local a=""; IFS= read -r a <&8 || a=""; printf '%s' "$a"; }
as_user(){ echo "AS_USER: $*"; }
_spark_check_answers(){ :; }
STUBS
  fn _spark_flag_vs_env; fn check_args; fn _spark_hostname; fn _spark_read_contract; fn run_installer
} > "$harness"

# run <env assignments...> -- <script body>: a fresh bash per case, with the terminal script in $T_ANSWERS
run() {
  local out rc
  out="$(env "$@" bash -c '
    source "$HARNESS"
    exec 8< "${T_ANSWERS:-/dev/null}"
    eval "$BODY"
  ' 2>&1)"; rc=$?
  RUN_OUT="$out"; RUN_RC=$rc
}
export HARNESS="$harness" T_LOG="$tmp/asked.log"
answers() { printf '%s' "$1" > "$tmp/answers"; export T_ANSWERS="$tmp/answers"; : > "$T_LOG"; }

# 1. --machine-name is the answer; nobody is asked
answers $'should-not-be-read\n'
BODY='ARG_MACHINE_NAME=matchbox; _SPARK_HOSTNAME=""; _SPARK_MACHINE_NAME_SETTLED=0; _spark_hostname; echo "name=${_SPARK_HOSTNAME} settled=${_SPARK_MACHINE_NAME_SETTLED}"' run T_X=1
export BODY
case "$RUN_OUT" in *"name=matchbox settled=1"*) [ ! -s "$T_LOG" ] && ok "the flag is the answer and nobody is asked" || bad "the flag was asked about" ;; *) bad "flag: $RUN_OUT" ;; esac

# 2. interactive: Enter takes the hostname default
answers $'\n'
BODY='_SPARK_HOSTNAME=""; _SPARK_MACHINE_NAME_SETTLED=0; ARG_MACHINE_NAME=""; _spark_hostname; echo "name=${_SPARK_HOSTNAME}"' run STUB_HOSTNAME=ubuntu
case "$RUN_OUT" in *"name=ubuntu"*) grep -q '\[ubuntu\]' "$T_LOG" && ok "Enter keeps the hostname default, shown in brackets" || bad "default not shown" ;; *) bad "enter: $RUN_OUT" ;; esac

# 3. the default is DF_HOSTNAME when set, ahead of the hostname
answers $'\n'
BODY='_SPARK_HOSTNAME=""; _SPARK_MACHINE_NAME_SETTLED=0; ARG_MACHINE_NAME=""; _spark_hostname; echo "name=${_SPARK_HOSTNAME}"' run STUB_HOSTNAME=ubuntu DF_HOSTNAME=fleetname
case "$RUN_OUT" in *"name=fleetname"*) grep -q '\[fleetname\]' "$T_LOG" && ok "DF_HOSTNAME is the default ahead of the hostname" || bad "DF_HOSTNAME not the shown default" ;; *) bad "DF_HOSTNAME: $RUN_OUT" ;; esac

# 4. a typed name replaces the default
answers $'matchbox\n'
BODY='_SPARK_HOSTNAME=""; _SPARK_MACHINE_NAME_SETTLED=0; ARG_MACHINE_NAME=""; _spark_hostname; echo "name=${_SPARK_HOSTNAME} settled=${_SPARK_MACHINE_NAME_SETTLED}"' run STUB_HOSTNAME=ubuntu
case "$RUN_OUT" in *"name=matchbox settled=1"*) ok "a typed name replaces the default" ;; *) bad "typed: $RUN_OUT" ;; esac

# 5. an invalid answer is refused and asked again
answers $'bad name\nmatchbox\n'
BODY='_SPARK_HOSTNAME=""; _SPARK_MACHINE_NAME_SETTLED=0; ARG_MACHINE_NAME=""; _spark_hostname; echo "name=${_SPARK_HOSTNAME}"' run STUB_HOSTNAME=ubuntu
case "$RUN_OUT" in *"WARN: 'bad name' is not a valid machine name"*"name=matchbox"*) ok "an invalid answer is refused with a warning and asked again" ;; *) bad "retry: $RUN_OUT" ;; esac

# 6. three invalid answers stop the run (exit 3) naming the flag
answers $'a b\nc_d\ne.f\n'
BODY='_SPARK_HOSTNAME=""; ARG_MACHINE_NAME=""; _spark_hostname' run STUB_HOSTNAME=ubuntu
[ "$RUN_RC" = 3 ] && case "$RUN_OUT" in *"--machine-name"*) ok "three invalid answers: exit 3, the flag is named" ;; *) bad "3x: $RUN_OUT" ;; esac || bad "3x rc=$RUN_RC"

# 7. unattended: a valid hostname is used; an invalid one stops the run
answers ''
BODY='_SPARK_HOSTNAME=""; _SPARK_MACHINE_NAME_SETTLED=0; ARG_MACHINE_NAME=""; _spark_hostname; echo "name=${_SPARK_HOSTNAME}"' run T_NONINT=1 STUB_HOSTNAME=ubuntu
case "$RUN_OUT" in *"name=ubuntu"*) [ ! -s "$T_LOG" ] && ok "unattended: a valid hostname is used without asking" || bad "unattended asked" ;; *) bad "unattended: $RUN_OUT" ;; esac
BODY='_SPARK_HOSTNAME=""; ARG_MACHINE_NAME=""; _spark_hostname' run T_NONINT=1 STUB_HOSTNAME=ubuntu_vm
[ "$RUN_RC" = 3 ] && case "$RUN_OUT" in *"--machine-name"*) ok "unattended with a hostname that is not a name: exit 3, the flag is named" ;; *) bad "unattended invalid: $RUN_OUT" ;; esac || bad "unattended invalid rc=$RUN_RC"

# 8. arguments: the flag (both forms) and its environment twin are consumed, validated, and not left for the installer
for form in "--machine-name matchbox" "--machine-name=matchbox"; do
  BODY="OPT_ROOT=$tmp; check_args --base https://h/o $form --skip-interview; echo \"name=\${ARG_MACHINE_NAME} args=\${INSTALL_ARGS[*]}\"" run T_X=1
  case "$RUN_OUT" in *"name=matchbox args=--skip-interview"*) ok "$form is consumed, not forwarded as an installer argument" ;; *) bad "args($form): $RUN_OUT" ;; esac
done
BODY='check_args --base https://h/o; echo "name=${ARG_MACHINE_NAME}"' run SPARK_MACHINE_NAME=envname
case "$RUN_OUT" in *"name=envname"*) ok "SPARK_MACHINE_NAME is the environment twin" ;; *) bad "env twin: $RUN_OUT" ;; esac
BODY='check_args --base https://h/o --machine-name one' run SPARK_MACHINE_NAME=two
[ "$RUN_RC" = 3 ] && ok "a flag that disagrees with its environment twin is exit 3" || bad "disagree rc=$RUN_RC"
BODY='check_args --base https://h/o --machine-name "bad_name; rm -rf /"' run T_X=1
[ "$RUN_RC" = 3 ] && case "$RUN_OUT" in *"rm -rf"*) bad "the bad value was echoed" ;; *) ok "a --machine-name outside the grammar: exit 3, not echoed" ;; esac || bad "grammar rc=$RUN_RC"

# 9. the contract: args=machine-name opts in; anything else is refused
mkdir -p "$tmp/opt/repo"
printf 'install=./install.sh\nargs=machine-name\n' > "$tmp/opt/repo/.spark"; touch "$tmp/opt/repo/install.sh"
BODY="OPT_ROOT=$tmp/opt; REPO_NAME=repo; _spark_read_contract; echo \"pass=\${_SPARK_PASS_MACHINE_NAME}\"" run T_X=1
case "$RUN_OUT" in *"pass=1"*) ok ".spark args=machine-name opts in" ;; *) bad "contract: $RUN_OUT" ;; esac
printf 'install=./install.sh\n' > "$tmp/opt/repo/.spark"
BODY="OPT_ROOT=$tmp/opt; REPO_NAME=repo; _spark_read_contract; echo \"pass=\${_SPARK_PASS_MACHINE_NAME}\"" run T_X=1
case "$RUN_OUT" in *"pass=0"*) ok "without args= the name is not passed on" ;; *) bad "contract none: $RUN_OUT" ;; esac
printf 'install=./install.sh\nargs=op-vault\n' > "$tmp/opt/repo/.spark"
BODY="OPT_ROOT=$tmp/opt; REPO_NAME=repo; _spark_read_contract" run T_X=1
[ "$RUN_RC" = 3 ] && ok "an args= word outside the allow-list is refused (exit 3)" || bad "contract allow-list rc=$RUN_RC"

# 10. forwarding: only a settled name, only to an installer that opted in
runit() {  # runit <settled> <pass>
  BODY="OPT_ROOT=$tmp/opt; REPO_NAME=repo; OWNER=\"\$(id -un)\"; INSTALL_ARGS=(--op-vault v); _SPARK_INSTALL_CMD=(./install.sh); _SPARK_HOSTNAME=matchbox; _SPARK_OP_SESSION_NAME=; _SPARK_MACHINE_NAME_SETTLED=$1; _SPARK_PASS_MACHINE_NAME=$2; run_installer" run T_NONINT=1
}
mkdir -p "$tmp/opt/repo"
runit 1 1; case "$RUN_OUT" in *"AS_USER: env"*"./install.sh --op-vault v --machine-name matchbox"*|*"TROVE_NONINTERACTIVE=1 ./install.sh --op-vault v --machine-name matchbox"*) ok "a settled name goes to an installer that opted in" ;; *) bad "forward: $RUN_OUT" ;; esac
runit 1 0; case "$RUN_OUT" in *"--machine-name matchbox"*) bad "forwarded to an installer that did not opt in" ;; *"does not take --machine-name"*) ok "a settled name is NOT forwarded to an installer that did not opt in, and spark says so" ;; *) bad "no-opt-in: $RUN_OUT" ;; esac
runit 0 1; case "$RUN_OUT" in *"--machine-name"*) bad "an unsettled name was forwarded" ;; *) ok "an unsettled name is never forwarded" ;; esac

echo "machine_name: ${n} checks"
exit "$fail"
