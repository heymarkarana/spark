#!/usr/bin/env bash
# spark.sh — the public homelab bootstrap (D097). One script, one job: get a bare machine to the point where ONE
# repository's own installer can take over.
#
# WHAT IT DOES, in order.
#   1. Checks sudo (the owner must be a sudoer) and the arguments; `--plan` stops here and prints what would happen.
#   2. Makes sure the bare minimums are on the machine: git, curl, zsh, jq (Ubuntu: apt; macOS: the Command Line Tools for
#      git, everything else is built in: no Homebrew, ever, in this script).
#   3. The 1Password CLI, optional, DEFAULT YES: installed from 1Password's OWN distribution when missing (macOS: the signed
#      universal .pkg from cache.agilebits.com, pinned version and SHA-256, signature chain checked with pkgutil before the one
#      `sudo installer`; Ubuntu: 1Password's apt repository with its signing key verified against a pinned fingerprint, the
#      debsig policy, and the source list written last). `--no-op` / SPARK_NO_OP=1 opts out; with a terminal the question is
#      asked once (Enter = yes) and then `op account add` / `op signin` run on the terminal; a failed sign-in (a typo in the address, email, Secret Key, password or code) is offered again, three attempts at most. Without a terminal it is installed
#      and not signed in. Never a Homebrew cask.
#   4. The ssh key for the forge: an existing usable source (a running agent, SPARK_SSH_KEY_FILE, SPARK_SSH_KEY_OP_REF, or
#      ~/.ssh/id_ed25519) is used; else, when op is signed in, the host's key is RESTORED from its 1Password item
#      (df_machine-<host>: id_ed25519, id_ed25519.pub; never over an existing file; its fingerprint is shown and, at a terminal, confirmed); else a new ed25519 key is GENERATED
#      (comment df_machine-<host>). A new or restored key is REGISTERED on the forge through its API when a token is readable
#      from 1Password (op://<vault>/df_common/DF_FORGEJO_API_TOKEN; the token travels on stdin, never argv); otherwise the public
#      key is printed with where to paste it. Same path, comment and title as the install's `ssh` setup module (D040), which
#      later finds the key and only checks that it authenticates.
#   5. Transport: an ssh base is used as it is (a key and a trusted host key are required). An https base is tried over ssh
#      first (ssh://git@<host>/<owner>, when a key is usable and the host key is pinned or already known), then https:
#      SPARK_HTTPS_TOKEN_FILE, else a token read from 1Password into a private 0600 file, else a hidden prompt on the
#      terminal, else anonymously (a public forge needs nothing). A local path base (an operator's delivery directory) is used as it is.
#   6. ONE repository (`--repo`, default dotFiles) is cloned into /opt/<repo> at `--ref` (a release tag, verified: it is on
#      origin's main, D005, and its VERSION names it; unset: the newest release tag; a branch: development only) or updated when
#      it is already there. spark reads NO stack.lock and knows NOTHING about Trove or Beskar any more: the repository's own
#      installer resolves its dependencies (dotFiles: lib/install_deps.zsh, D098).
#   7. The repository's installer runs as the owner: the command its `.spark` file names (`install=<argv relative to the repo>`,
#      after the tools its `needs=` line lists are present), else `./install`; spark's remaining arguments are appended.
#
# PRIVILEGE (D024). Run it AS YOUR NORMAL USER. It escalates with sudo only for: packages (apt, the op .pkg), the one code
# directory under /opt, and, from root, `sudo -u <owner>` for every user-context step. As root it REFUSES unless
# SPARK_PRIMARY_USER names the non-root account that is to own everything. It never chowns or chmods an existing tree.
# Bootstrap exception to the "no raw sudo" rule: spark runs before any dotFiles library exists, so `_df_sudo` is unavailable.
# The ONE wrapper `_spark_sudo` calls the absolute /usr/bin/sudo, argv only, never through a shell string.
#
# ENVIRONMENT OF THE CHILDREN. Every user-context child runs with all DF_*, ATLAS_*, TROVE_*, BESKAR_*, GIT_*, SUDO_* and
# SPARK_* variables removed and TROVE_HOME, BESKAR_HOME and DF_HOME pinned under /opt; /usr/local/bin is on its PATH (op and
# age live there, and a headless macOS session lacks it). OP_* and proxy variables pass through. DF_INSTALL_OPTIONAL crosses
# after a grammar check (D094).
#
# USAGE (download first, verify, then run):
#   curl -fsSL --proto '=https' --tlsv1.2 -O "<public repo>/raw/tag/<tag>/spark.sh" -O "<public repo>/raw/tag/<tag>/SHA256SUMS"
#   sha256sum -c SHA256SUMS      (shasum -a 256 -c on macOS)
#   bash spark.sh --base https://host/<owner> [--repo dotFiles] [--ref vX.Y.Z] [--no-op] [installer arguments...]
#   e.g.  bash spark.sh --base https://forge.example/homelab --answers ~/answers.json --skip-interview
# (`curl | bash` still works: no child ever reads the script from stdin; the prompts read /dev/tty.)  `bash spark.sh --plan` changes nothing.
#
# FLAGS AND THEIR ENVIRONMENT TWINS (a flag that disagrees with a set variable is exit 3)
#   --repo <name>      SPARK_REPO          the repository to install (default dotFiles; plain word)
#   --base <url>       SPARK_REPO_BASE     https://host/<owner>, ssh://[user@]host[:port]/<owner>, or an absolute local path
#   --ref <ref>        SPARK_REF           unset: newest release tag on main; vX.Y.Z: that release; anything else: a branch (development only)
#   --no-op            SPARK_NO_OP=1       do not install the 1Password CLI
#   --op-vault <name>  SPARK_OP_VAULT      the 1Password vault that holds df_common and df_machine-<host> (needed when several do)
#   --machine-name <n> SPARK_MACHINE_NAME  this machine's name: the ssh key's comment, the forge key's title and the 1Password item
#                                          df_machine-<n>. Without it spark ASKS (default: DF_HOSTNAME when set, else `hostname -s`;
#                                          Enter keeps it) and, unattended, uses a valid default or stops. It is passed on to an installer
#                                          whose .spark says `args=machine-name`, so it is not asked twice.
#   --plan                                 print what would happen, change nothing
#   SPARK_PRIMARY_USER (required as root), SPARK_NONINTERACTIVE=1 (never use a terminal),
#   SPARK_SSH_HOST_FPR=SHA256:... (the forge's host-key pin: compared exactly, refused on a mismatch, written to a private
#   known_hosts and kept afterwards in ~/.ssh/known_hosts as a managed block; without a pin only a key already in the owner's
#   known_hosts is trusted, never accept-new), SPARK_SSH_KEY_FILE (0600, owned by you, in a private directory),
#   SPARK_SSH_KEY_OP_REF=op://vault/item/field (read with a signed-in op into a private agent with a 300 s lifetime),
#   SPARK_HTTPS_TOKEN_FILE (same file rules; for a private https forge), SPARK_HTTPS_USER (default git).
#   Security refusals exit 3.
#
# PINS (bumped together; tools/bump-op-pin.zsh recomputes the digest after the same signature check):
#   the 1Password CLI version and the SHA-256 of its macOS universal .pkg, the fingerprint of 1Password's apt signing key.
#
# Test seams (hermetic runs only, DF_TEST_HERMETIC=1; ignored in production, D054):
#   SPARK_SUDO_BIN SPARK_ASSUME_ROOT SPARK_TEST_OS SPARK_HAVE_TTY SPARK_TTY SPARK_OPT_ROOT SPARK_OPT_ROOT_UID SPARK_SSH_BIN
#   SPARK_SSH_KEYSCAN_BIN SPARK_SECRET_OWNER_UID SPARK_OP_BIN SPARK_OP_PKG_URL SPARK_OP_APT_BASE SPARK_PKGUTIL_BIN SPARK_INSTALLER_BIN
#   SPARK_LOCAL_BIN SPARK_HOSTNAME SPARK_SSH_KEYGEN_BIN SPARK_HOME_SSH_DIR SPARK_CURL_BIN
set -euo pipefail

# The grammar checks below (regexes, [[:cntrl:]], [A-Za-z]) mean bytes, not the operator's locale
# collation (L9). The operator's own LC_ALL is restored for every child (see _spark_child_env).
if [[ -n "${LC_ALL+x}" ]]; then _SPARK_ORIG_LC_ALL="$LC_ALL"; _SPARK_HAD_LC_ALL=1; else _SPARK_ORIG_LC_ALL=""; _SPARK_HAD_LC_ALL=0; fi
export LC_ALL=C

# Release grammar (D077): a tag is vX.Y.Z. Checked before use.
_SPARK_RE_TAG='^v[0-9]+\.[0-9]+\.[0-9]+$'
_SPARK_RE_SHA='^([0-9a-f]{40}|[0-9a-f]{64})$'
_SPARK_RE_REPO='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
_SPARK_RE_HOSTLABEL='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
_SPARK_RE_VAULT='^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$'
_SPARK_RE_TOKEN='^[A-Za-z0-9._~+/=-]{8,512}$'

# ---------------------------------------------------------------------------------------
# PINS: the 1Password CLI (D097). The .pkg digest is of op_apple_universal_v<version>.pkg; the fingerprint is the primary key of
# https://downloads.1password.com/linux/keys/1password.asc (the same one Beskar pins). Bump all three together.
# ---------------------------------------------------------------------------------------
_SPARK_OP_VERSION="2.41.0"
_SPARK_OP_PKG_SHA256="eab17e0c929c11b6229b576ba0e7d2d764c7478cac9caf9fbfa11fe61bc35647"
_SPARK_OP_SIGNING_FPR="3FEF9748469ADBE15DA7CA80AC2D62742012EA22"
_SPARK_OP_PKG_SIGNER="Developer ID Installer: AgileBits Inc. (2BUA8C4S2C)"

_bot(){  printf '\n  \xe2\x9c\xaa %s\n' "$*"; }
_run(){  printf '   \xe2\x9c\xa8 %s\n' "$*"; }
_ok(){   printf '   \xe2\x9c\x94 %s\n' "$*"; }
# Warnings and errors go to the ORIGINAL stderr (fd 9, opened by main): a refusal raised while a command's stderr is captured (the ssh
# probe keeps git's noise in a file) must still reach the operator. Before main opens fd 9, plain stderr.
# 2>/dev/null: the probe only asks whether fd 9 is open; the shell's "Bad file descriptor" for a closed one is the answer, not news.
_spark_err_fd(){ if { true >&9; } 2>/dev/null; then printf '9'; else printf '2'; fi; }
_warn(){ local fd; fd="$(_spark_err_fd)"; printf '   \xe2\x9a\xa0 %s\n' "$*" >&"$fd"; }
_err(){  local fd; fd="$(_spark_err_fd)"; printf '   \xe2\x9c\x96 %s\n' "$*" >&"$fd"; }
die(){   _err "$*"; exit 1; }
die3(){  _err "$*"; exit 3; }

_spark_seam(){  # _spark_seam NAME default
  local name="$1" def="${2:-}" val=""
  if [[ "${DF_TEST_HERMETIC:-}" == 1 ]]; then val="${!name:-}"; fi
  printf '%s' "${val:-$def}"
}
_spark_euid(){
  if [[ "$(_spark_seam SPARK_ASSUME_ROOT 0)" == 1 ]]; then printf '0'; else id -u; fi
}
_spark_os(){
  case "$(_spark_seam SPARK_TEST_OS "$(uname -s)")" in
    Darwin) printf 'macos' ;;
    Linux)  printf 'linux' ;;
    *)      printf 'unknown' ;;
  esac
}
_spark_have_tty(){
  case "$(_spark_seam SPARK_HAVE_TTY auto)" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  # 2>/dev/null: the open failing IS the answer, not an error to show.
  ( : < "$(_spark_seam SPARK_TTY /dev/tty)" ) 2>/dev/null
}

_spark_sudo_bin(){
  if [[ "${DF_TEST_HERMETIC:-}" == 1 ]]; then _spark_seam SPARK_SUDO_BIN /nonexistent/hermetic-run-reached-sudo-without-SPARK_SUDO_BIN
  else printf '/usr/bin/sudo'; fi
}

_spark_sudo(){
  local bin
  bin="$(_spark_sudo_bin)"
  [[ -x "$bin" ]] || die "the sudo binary ${bin} is not executable."
  "$bin" "$@"
}

check_sudo(){
  local bin
  bin="$(_spark_sudo_bin)"
  # GUARD: spark-sudo-missing without /usr/bin/sudo no system step can run; say so before anything is created.
  if [[ ! -x "$bin" ]]; then
    die "spark needs sudo (${bin}) for the system steps, and ${OWNER} must be a sudoer — install sudo and add ${OWNER} to it, then re-run."
  fi
  # GUARD-END: spark-sudo-missing
  if [[ "$(_spark_euid)" -eq 0 ]]; then
    _spark_sudo -n -l -U "$OWNER" >/dev/null || die "${OWNER} is not allowed to use sudo — the install escalates its system steps through it; add ${OWNER} to the sudoers, then re-run."
  elif _spark_noninteractive; then
    _spark_sudo -n true || die "sudo needs a password and there is no terminal — run spark in a terminal or configure passwordless sudo for ${OWNER}."
  else
    # GUARD: spark-sudo-nopasswd-first a sudoers file with a password line (`%sudo ... ALL`) plus a NOPASSWD line for the user makes `sudo -v` ask for a password although `sudo -n true` succeeds; the no-password probe goes first and `sudo -v` is only the fallback (G18).
    # 2>/dev/null: the probe failing only means "a password is needed"; the fallback asks for it on the terminal.
    _spark_sudo -n true 2>/dev/null || _spark_sudo -v || die "sudo did not authenticate ${OWNER}."
    # GUARD-END: spark-sudo-nopasswd-first
  fi
}
# ---------------------------------------------------------------------------------------
# Who runs what (D024). Sets OWNER and OWNER_GROUP.
# ---------------------------------------------------------------------------------------
resolve_owner(){
  local owner_uid=""
  if [[ "$(_spark_euid)" -eq 0 ]]; then
    OWNER="${SPARK_PRIMARY_USER:-}"
    if [[ -n "$OWNER" ]]; then
      id "$OWNER" >/dev/null 2>&1 || die "SPARK_PRIMARY_USER '${OWNER}' does not exist — create the account first (spark seeds tools, not users)."
      owner_uid="$(id -u "$OWNER")"
    fi
    # GUARD: spark-refuse-root running as root without a named non-root owner would leave the armory, keys and rc files root-owned (D024). The test is the UID, so 0 and any uid-0 alias are refused too.
    if [[ -z "$OWNER" || "$owner_uid" -eq 0 ]]; then
      die "Refusing to run as root: set SPARK_PRIMARY_USER=<user> to a non-root account (it will own and run everything), or run spark.sh as that user."
    fi
    # GUARD-END: spark-refuse-root
    OWNER="$(id -un "$OWNER")"
  else
    OWNER="$(id -un)"
    owner_uid="$(id -u)"
    # GUARD: spark-owner-mismatch a SPARK_PRIMARY_USER other than the invoking user would silently be ignored; refuse instead.
    if [[ -n "${SPARK_PRIMARY_USER:-}" && "${SPARK_PRIMARY_USER}" != "$OWNER" ]]; then
      die "SPARK_PRIMARY_USER '${SPARK_PRIMARY_USER}' is not the invoking user '${OWNER}': run spark.sh as '${SPARK_PRIMARY_USER}' (or as root with SPARK_PRIMARY_USER set)."
    fi
    # GUARD-END: spark-owner-mismatch
  fi
  OWNER_UID="$owner_uid"
  OWNER_GROUP="$(id -gn "$OWNER")" || die "cannot resolve the primary group of '${OWNER}'."
}
# A child never inherits the script itself as stdin (curl | bash): /dev/null unless a real terminal.
_spark_stdin_safe(){
  if [[ -t 0 ]]; then "$@"; else "$@" </dev/null; fi
}

# The ONE child-environment builder (S4): every user-context child starts without any DF_*, ATLAS_*,
# TROVE_*, BESKAR_*, GIT_*, SUDO_* or SPARK_* variable of the operator's environment (a stale
# TROVE_HOME or DF_HOME, an ATLAS_REGISTRY, DF_TEST_HERMETIC, GIT_DIR ... would steer the installer
# to other trees), and sees exactly the three tier homes under the install root. OP_* and the proxy
# variables pass through on purpose. /usr/local/bin is on the child's PATH: op and age are installed there and a headless
# macOS session's PATH lacks it (through `sudo -u` a secure_path would drop it too).
CHILD_ENV=()
_spark_child_env(){
  local n
  CHILD_ENV=()
  for n in $(compgen -e); do
    case "$n" in
      DF_*|ATLAS_*|TROVE_*|BESKAR_*|GIT_*|SUDO_*|SPARK_*) CHILD_ENV+=(-u "$n") ;;
    esac
  done
  # spark's own LC_ALL=C is for its grammar checks only: a child gets the operator's locale back (env wants its -u options first).
  if [[ "$_SPARK_HAD_LC_ALL" != 1 ]]; then CHILD_ENV+=(-u LC_ALL); fi
  CHILD_ENV+=("TROVE_HOME=${OPT_ROOT}/trove" "BESKAR_HOME=${OPT_ROOT}/beskar" "DF_HOME=${OPT_ROOT}/dotFiles")
  case ":${PATH}:" in *":${_SPARK_LOCAL_BIN}:"*) CHILD_ENV+=("PATH=${PATH}") ;; *) CHILD_ENV+=("PATH=${_SPARK_LOCAL_BIN}:${PATH}") ;; esac
  if [[ "$_SPARK_HAD_LC_ALL" == 1 ]]; then CHILD_ENV+=("LC_ALL=${_SPARK_ORIG_LC_ALL}"); fi
  # The ONE DF_* value that crosses on purpose (D094): the optional-package opt-in (`all`, `none` or a list of
  # names), so a headless cold start can opt into the 1Password CLI. Checked against the install's own grammar
  # before it is passed; anything else stops the run (the -u above already dropped it).
  if [[ -n "${DF_INSTALL_OPTIONAL:-}" ]]; then
    if [[ "$DF_INSTALL_OPTIONAL" =~ ^(all|none|[A-Za-z0-9._+-]+(,[A-Za-z0-9._+-]+)*)$ ]]; then
      CHILD_ENV+=("DF_INSTALL_OPTIONAL=${DF_INSTALL_OPTIONAL}")
    else
      die "DF_INSTALL_OPTIONAL must be all, none or a comma-separated list of package names."
    fi
  fi
}

as_root(){
  if [[ "$(id -u)" -eq 0 ]]; then _spark_stdin_safe "$@"; else _spark_stdin_safe _spark_sudo "$@"; fi
}
# Run as the owner, in the pinned environment. From another account (root) it goes through
# sudo -u, with the SUDO_* variables dropped so the callee cannot mistake root for the invoking user.
as_user(){
  _spark_child_env
  if [[ "$(id -un)" == "$OWNER" ]]; then
    _spark_stdin_safe env ${CHILD_ENV[@]+"${CHILD_ENV[@]}"} "$@"
  else
    _spark_stdin_safe _spark_sudo -u "$OWNER" -H env -u SUDO_USER -u SUDO_UID -u SUDO_GID -u SUDO_COMMAND ${CHILD_ENV[@]+"${CHILD_ENV[@]}"} "$@"
  fi
}

# As as_user, but stdin is the caller's (a pipe), never replaced by /dev/null: for the places a secret travels on a pipe.
as_user_piped(){
  _spark_child_env
  if [[ "$(id -un)" == "$OWNER" ]]; then
    env ${CHILD_ENV[@]+"${CHILD_ENV[@]}"} "$@"
  else
    _spark_sudo -u "$OWNER" -H env -u SUDO_USER -u SUDO_UID -u SUDO_GID -u SUDO_COMMAND ${CHILD_ENV[@]+"${CHILD_ENV[@]}"} "$@"
  fi
}

# The 1Password CLI as the owner. Without the desktop app (a fresh machine) op keeps no session of its own: `op signin`
# prints one as `export OP_SESSION_<account>="<token>"`, and every later call needs it in the ENVIRONMENT. spark reads
# that line into two shell variables and exports the pair in its OWN environment (what `eval $(op signin)` does), so its
# op calls, the installer and every install phase are signed in without asking again: never on argv (env NAME=value would
# show it in ps), never in a file, never in a message (OP_* passes through the child environment on purpose). From root
# the token travels to the owner's op on a pipe (the sanctioned route for a secret), read back into the environment by a
# one-line sh (a literal; nothing is interpolated into it) before op starts.
_SPARK_OP_SESSION_NAME=""
_SPARK_OP_SESSION=""
_spark_op(){  # _spark_op <op arguments...>; stdin is the caller's
  _spark_child_env
  if [[ -z "$_SPARK_OP_SESSION_NAME" || "$(id -un)" == "$OWNER" ]]; then as_user_piped "$_SPARK_OP_BIN" "$@"; return; fi
  {
    { printf '%s\n' "$_SPARK_OP_SESSION"; if [[ ! -t 0 ]]; then cat; fi; } | \
      _spark_sudo -u "$OWNER" -H env -u SUDO_USER -u SUDO_UID -u SUDO_GID -u SUDO_COMMAND ${CHILD_ENV[@]+"${CHILD_ENV[@]}"} \
        /bin/sh -c 'IFS= read -r _s; export "$1=$_s"; shift; exec "$@"' _ "$_SPARK_OP_SESSION_NAME" "$_SPARK_OP_BIN" "$@"
  }
}
# Sign in on the terminal: op's prompts go to the person (stderr), its stdout (the session line) is read into the two
# variables and nowhere else. Returns 1 when no session line came back.
_spark_op_signin_capture(){  # _spark_op_signin_capture <op arguments...>
  local out line rest
  out="$(_spark_op "$@" <"$(_spark_seam SPARK_TTY /dev/tty)" 2>&9)" || return 1
  line="${out##*OP_SESSION_}"
  [[ "$line" != "$out" ]] || return 1
  rest="${line%%[!A-Za-z0-9_]*}"
  [[ -n "$rest" ]] || return 1
  _SPARK_OP_SESSION_NAME="OP_SESSION_${rest}"
  rest="${line#"$rest"}"; rest="${rest#=}"; rest="${rest# }"; rest="${rest#\"}"; rest="${rest%%\"*}"; rest="${rest%%[[:space:]]*}"
  [[ -n "$rest" ]] || { _SPARK_OP_SESSION_NAME=""; return 1; }
  _SPARK_OP_SESSION="$rest"
  export "${_SPARK_OP_SESSION_NAME}=${_SPARK_OP_SESSION}"
  return 0
}

# ---------------------------------------------------------------------------------------
# Arguments: validated BEFORE any system step (no partial state). spark's own flags are consumed; everything else is
# INSTALL_ARGS, handed to the repository's installer (an answers path made absolute, because the installer runs in the repo).
# A flag that disagrees with its set environment twin is exit 3: a one-liner must not be steered silently by the environment,
# nor the environment by a one-liner.
# ---------------------------------------------------------------------------------------
INSTALL_ARGS=()
ARG_NONINTERACTIVE=0
ARG_PLAN=0
ANSWERS_ABS=""
_spark_check_answers(){  # _spark_check_answers <path> → ANSWERS_ABS (absolute, checked)
  local path="$1"
  [[ -n "$path" ]] || die "--answers needs a file."
  case "$path" in /*) ;; *) path="${PWD}/${path}" ;; esac
  # GUARD: spark-answers-missing a missing or unreadable answers file stops the run before any system step (no partial state).
  if [[ ! -f "$path" ]] || ! as_user test -r "$path"; then
    die "answers file not found or not readable by ${OWNER}: ${path}"
  fi
  # GUARD-END: spark-answers-missing
  ANSWERS_ABS="$path"
}
REPO_NAME=""
ARG_NO_OP=0
OP_VAULT=""
ARG_MACHINE_NAME=""
_spark_flag_vs_env(){  # _spark_flag_vs_env <flag> <value> <env-name>
  local envval="${!3:-}"
  if [[ -n "$envval" && "$envval" != "$2" ]]; then die3 "${1} '${2}' disagrees with ${3}='${envval}': set one of them."; fi
}
check_args(){
  local a v
  INSTALL_ARGS=()
  while [[ $# -gt 0 ]]; do
    a="$1"
    case "$a" in
      --answers)
        [[ $# -ge 2 && -n "$2" ]] || die "--answers needs a file."
        _spark_check_answers "$2"
        INSTALL_ARGS+=("--answers" "$ANSWERS_ABS")
        shift 2; continue ;;
      --answers=*)
        _spark_check_answers "${a#--answers=}"
        INSTALL_ARGS+=("--answers" "$ANSWERS_ABS")
        shift; continue ;;
      --repo|--base|--ref|--op-vault|--machine-name)
        [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || die "${a} needs a value."
        v="$2"; shift 2 ;;
      --repo=*|--base=*|--ref=*|--op-vault=*|--machine-name=*)
        v="${a#*=}"; a="${a%%=*}"; shift ;;
      --no-op)
        _spark_flag_vs_env --no-op 1 SPARK_NO_OP; ARG_NO_OP=1; shift; continue ;;
      --plan)
        ARG_NONINTERACTIVE=1; ARG_PLAN=1; INSTALL_ARGS+=("$a"); shift; continue ;;
      --skip-interview|--no-interview)
        ARG_NONINTERACTIVE=1; INSTALL_ARGS+=("$a"); shift; continue ;;
      *) INSTALL_ARGS+=("$a"); shift; continue ;;
    esac
    case "$a" in
      --repo)     _spark_flag_vs_env --repo "$v" SPARK_REPO;          REPO_NAME="$v" ;;
      --base)     _spark_flag_vs_env --base "$v" SPARK_REPO_BASE;     SPARK_REPO_BASE="$v" ;;
      --ref)      _spark_flag_vs_env --ref "$v" SPARK_REF;            SPARK_REF="$v" ;;
      --op-vault) _spark_flag_vs_env --op-vault "$v" SPARK_OP_VAULT;  OP_VAULT="$v" ;;
      --machine-name) _spark_flag_vs_env --machine-name "$v" SPARK_MACHINE_NAME; ARG_MACHINE_NAME="$v" ;;
    esac
  done
  REPO_NAME="${REPO_NAME:-${SPARK_REPO:-dotFiles}}"
  # GUARD: spark-repo-grammar the repository name becomes a path component under /opt and a URL path segment: a plain word only.
  [[ "$REPO_NAME" =~ $_SPARK_RE_REPO && "$REPO_NAME" != *..* ]] || die3 "--repo '${REPO_NAME}' is not a plain repository name."
  # GUARD-END: spark-repo-grammar
  ARG_MACHINE_NAME="${ARG_MACHINE_NAME:-${SPARK_MACHINE_NAME:-}}"
  # GUARD: spark-machine-name-grammar the name becomes an ssh key comment, a 1Password item name and a forge key title, and may ride to the installer as an argument: a hostname label or nothing.
  if [[ -n "$ARG_MACHINE_NAME" ]] && ! [[ "$ARG_MACHINE_NAME" =~ $_SPARK_RE_HOSTLABEL ]]; then die3 "--machine-name is not a valid machine name (letters, digits and inner hyphens, 1-63 characters)."; fi
  # GUARD-END: spark-machine-name-grammar
  OP_VAULT="${OP_VAULT:-${SPARK_OP_VAULT:-}}"
  if [[ -n "$OP_VAULT" ]] && ! [[ "$OP_VAULT" =~ $_SPARK_RE_VAULT ]]; then die3 "--op-vault is not a plain vault name."; fi
  # The installer may need the same answer (dotFiles' resolver reads a token from that vault), so it travels on as a flag.
  if [[ -n "$OP_VAULT" ]]; then INSTALL_ARGS+=("--op-vault" "$OP_VAULT"); fi
  if [[ "${SPARK_NO_OP:-0}" == 1 ]]; then ARG_NO_OP=1; fi
}

_spark_noninteractive(){
  [[ "${SPARK_NONINTERACTIVE:-0}" == "1" || "$ARG_NONINTERACTIVE" == "1" ]] && return 0
  _spark_have_tty && return 1
  return 0
}

# ---------------------------------------------------------------------------------------
# Prerequisites: git curl zsh jq. Checked before any write. No Homebrew anywhere in spark (D097).
# ---------------------------------------------------------------------------------------
_SPARK_TOOLS="git curl zsh jq"
_SPARK_LOCAL_BIN="/usr/local/bin"
_spark_missing(){  # prints the missing tools, space separated
  local t out=""
  for t in $_SPARK_TOOLS; do
    command -v "$t" >/dev/null 2>&1 || out="${out:+$out }$t"
  done
  printf '%s' "$out"
}

# macOS base: the Command Line Tools (git). zsh, curl, jq (macOS 15+) and ssh are built in; Homebrew is the installed repository's
# business (dotFiles installs it, D098), never spark's.
ensure_macos_base(){
  if ! xcode-select -p >/dev/null 2>&1; then
    _run "installing the Xcode Command Line Tools — approve the dialog"
    # || true: the installer trigger exits non-zero when already requested; the die below is the real answer.
    xcode-select --install >/dev/null 2>&1 || true
    die "The Xcode Command Line Tools are installing — re-run spark once they finish."
  fi
}

ensure_prereqs(){
  local missing
  case "$(_spark_os)" in
    macos) ensure_macos_base ;;
    linux) ;;
    *)     die "unsupported OS '$(uname -s)' — spark supports macOS and Linux." ;;
  esac
  missing="$(_spark_missing)"
  if [[ -z "$missing" ]]; then _ok "prerequisites present (${_SPARK_TOOLS})"; return 0; fi
  case "$(_spark_os)" in
    linux) _spark_apt_install $missing || exit 1 ;;
    macos)
      # GUARD: spark-macos-no-brew a Mac that lacks jq or curl is older than macOS 15; spark names the tool and stops rather than pull in Homebrew.
      die "missing prerequisite(s) on macOS: ${missing} — this macOS does not ship them (macOS 15 and newer do); install them yourself, then re-run spark (spark never installs Homebrew)." ;;
      # GUARD-END: spark-macos-no-brew
  esac
  missing="$(_spark_missing)"
  # GUARD: spark-prereq-missing a tool still missing after the install attempt stops the run before anything is created.
  if [[ -n "$missing" ]]; then
    die "missing prerequisite(s) after the install attempt: ${missing} — install them, then re-run spark."
  fi
  # GUARD-END: spark-prereq-missing
  _ok "prerequisites installed"
}

# One apt install (argv only, non-interactive). Used for the prerequisites, gnupg, and a repository's `.spark` needs.
# Remove every 1Password credential from THIS shell (call it only in a subshell): as_root execs apt-get directly, with spark's own
# environment, when spark itself runs as root, and dpkg maintainer scripts must not see the session (D048, D099).
_spark_drop_op_credentials(){
  local n
  unset OP_SERVICE_ACCOUNT_TOKEN
  for n in $(compgen -e | grep '^OP_SESSION_'); do unset "$n"; done
}
_SPARK_APT_UPDATED=0
_spark_apt_install(){  # rc 1 on failure: the caller decides whether that is fatal (prerequisites) or a WARN (the optional op)
  command -v apt-get >/dev/null 2>&1 || { _err "missing: $* — and no apt-get to install them; install them, then re-run spark."; return 1; }
  _run "installing with apt: $*"
  # DPkg::Lock::Timeout: a fresh Ubuntu holds the dpkg lock for minutes (unattended-upgrades); wait for it (bounded, 300 s) instead of failing.
  if (( ! _SPARK_APT_UPDATED )); then
    ( _spark_drop_op_credentials; as_root env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update -q ) || { _err "apt-get update failed — fix the package sources (and the clock), then re-run spark."; return 1; }
    _SPARK_APT_UPDATED=1
  fi
  ( _spark_drop_op_credentials; as_root env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -- "$@" ) \
    || { _err "apt-get install $* failed."; return 1; }
}

# The terminal is opened ONCE, on fd 7, in the calling shell (before any $(...) that asks), so successive answers read successive lines.
_SPARK_TTY_OPEN=0
_spark_tty_open(){
  if [[ "$_SPARK_TTY_OPEN" == "1" ]]; then return 0; fi
  exec 7< "$(_spark_seam SPARK_TTY /dev/tty)" || die "cannot open the terminal."
  _SPARK_TTY_OPEN=1
}

# Reads one answer from the terminal (never a secret: a token is read hidden by its own reader).
_spark_ask(){  # _spark_ask <prompt> → stdout
  local reply=""
  printf '   %s' "$1" >&2
  IFS= read -r reply <&7 || reply=""
  printf '%s' "$reply"
}

# ---------------------------------------------------------------------------------------
# The 1Password CLI, optional, default yes (D097; amends D055/D074 for spark only): from 1Password's OWN distribution.
# ---------------------------------------------------------------------------------------
_SPARK_OP_BIN=""
# The op binary: on PATH, else /usr/local/bin/op (where the .pkg puts it; a headless macOS PATH lacks that directory).
_spark_op_bin(){
  local b
  b="$(_spark_seam SPARK_OP_BIN "")"
  if [[ -n "$b" ]]; then _SPARK_OP_BIN="$b"; [[ -x "$b" ]]; return $?; fi
  # 2>/dev/null: "not on PATH" is an answer here, not an error to show.
  if b="$(command -v op 2>/dev/null)"; then _SPARK_OP_BIN="$b"; return 0; fi
  if [[ -x "${_SPARK_LOCAL_BIN}/op" ]]; then _SPARK_OP_BIN="${_SPARK_LOCAL_BIN}/op"; return 0; fi
  _SPARK_OP_BIN=""
  return 1
}
# True when op is installed and has a registered account (a signed-in or sign-in-able session). 2>/dev/null: with none registered op
# prints an error; the empty answer is the result.
_spark_op_has_account(){ _spark_op_bin && [[ -n "$(_spark_op account list 2>/dev/null)" ]]; }
# True when op can read right now (signed in): `op whoami` succeeds.
_spark_op_signed_in(){ _spark_op_bin && _spark_op whoami >/dev/null 2>&1; }

# macOS: the pinned signed .pkg. Verified in the private directory BEFORE the one escalated step: SHA-256 against the pin, then
# the signature chain (pkgutil, in C locale, exit 0, chain entry 1 exactly the pinned Developer ID). When spark runs as root the
# verified file is copied into a root-owned directory first, so the owner-writable copy cannot be swapped under `installer`.
_spark_op_install_macos(){
  local url pkg got sig pkgutil installer tmpd="" rc=0
  url="$(_spark_seam SPARK_OP_PKG_URL "https://cache.agilebits.com/dist/1P/op2/pkg/v${_SPARK_OP_VERSION}/op_apple_universal_v${_SPARK_OP_VERSION}.pkg")"
  pkgutil="$(_spark_seam SPARK_PKGUTIL_BIN /usr/sbin/pkgutil)"; installer="$(_spark_seam SPARK_INSTALLER_BIN /usr/sbin/installer)"
  _spark_priv_dir
  pkg="${_SPARK_PRIV}/op.pkg"
  _run "downloading the 1Password CLI ${_SPARK_OP_VERSION} (.pkg) from 1Password"
  as_user "$(_spark_seam SPARK_CURL_BIN curl)" --proto '=https' --proto-redir '=https' --tlsv1.2 --max-redirs 3 -fsSL --max-time 300 -o "$pkg" "$url" \
    || { _warn "1Password CLI: download failed; continuing without op"; return 1; }
  got="$(as_user shasum -a 256 -- "$pkg")" || got=""; got="${got%% *}"
  # GUARD: spark-op-pkg-checksum the package is used only when its SHA-256 equals the pin; a mismatch removes it and installs nothing.
  if [[ "$got" != "$_SPARK_OP_PKG_SHA256" ]]; then
    as_user rm -f -- "$pkg"
    _warn "1Password CLI: the downloaded package does not match the pinned SHA-256 (got ${got:0:12}…); not installing it"
    return 1
  fi
  # GUARD-END: spark-op-pkg-checksum
  # GUARD: spark-op-pkg-signature the signature chain must verify (exit 0) and its first entry must be exactly 1Password's Developer ID Installer identity.
  # 2>/dev/null: pkgutil's own complaint is replaced by the refusal below; its exit status is the answer.
  sig="$(LC_ALL=C as_user "$pkgutil" --check-signature "$pkg" 2>/dev/null)" || { as_user rm -f -- "$pkg"; _warn "1Password CLI: the package signature does not verify; not installing it"; return 1; }
  if ! printf '%s\n' "$sig" | awk -v want="1. ${_SPARK_OP_PKG_SIGNER}" '{ sub(/^[ \t]+/, ""); if ($0 == want) ok=1 } END { exit ok ? 0 : 1 }'; then
    as_user rm -f -- "$pkg"
    _warn "1Password CLI: the package is not signed by '${_SPARK_OP_PKG_SIGNER}'; not installing it"
    return 1
  fi
  # GUARD-END: spark-op-pkg-signature
  if [[ "$(id -u)" -eq 0 ]]; then
    tmpd="$(mktemp -d "${TMPDIR:-/tmp}/spk-root.XXXXXX")" || return 1
    cp -- "$pkg" "${tmpd}/op.pkg" || { rm -rf -- "$tmpd"; return 1; }
    pkg="${tmpd}/op.pkg"
  fi
  _run "installing the 1Password CLI ${_SPARK_OP_VERSION}"
  as_root "$installer" -pkg "$pkg" -target / >/dev/null || rc=$?
  [[ -n "$tmpd" ]] && rm -rf -- "$tmpd"
  # 2>/dev/null: the download may already be gone (a root run copied it away). || true: cleanup never changes the outcome.
  as_user rm -f -- "${_SPARK_PRIV}/op.pkg" 2>/dev/null || true
  (( rc == 0 )) || { _warn "1Password CLI: the installer failed (exit ${rc}); continuing without op"; return 1; }
  return 0
}

# Ubuntu/Debian: 1Password's apt repository, Beskar's procedure (beskar_1password.zsh): the signing key is fetched over https
# into the private directory and its PRIMARY fingerprint must equal the pin; then the dearmored keyring, the debsig policy and
# keyring, and the source list LAST, each placed with one `sudo install`; then apt. Needs gpg (apt `gnupg`).
_spark_op_install_linux(){
  local base keyring=/usr/share/keyrings/1password-archive-keyring.gpg arch pol fprs tmp
  base="$(_spark_seam SPARK_OP_APT_BASE https://downloads.1password.com/linux)"
  pol="${_SPARK_OP_SIGNING_FPR: -16}"
  command -v gpg >/dev/null 2>&1 || _spark_apt_install gnupg || { _warn "1Password CLI: gnupg could not be installed; continuing without op"; return 1; }
  # 2>/dev/null: no dpkg means no architecture; the empty answer is refused on the next line.
  arch="$(dpkg --print-architecture 2>/dev/null)" || arch=""
  [[ "$arch" =~ ^[a-z0-9]+$ ]] || { _warn "1Password CLI: cannot read the dpkg architecture; continuing without op"; return 1; }
  _spark_priv_dir
  tmp="$_SPARK_PRIV"
  _run "adding 1Password's apt repository (signing key verified against the pinned fingerprint)"
  as_user "$(_spark_seam SPARK_CURL_BIN curl)" --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --retry 3 -o "${tmp}/1password.asc" "${base}/keys/1password.asc" \
    || { _warn "1Password CLI: could not download the signing key; continuing without op"; return 1; }
  as_user mkdir -m 0700 "${tmp}/gnupg" || return 1
  # 2>/dev/null: gpg's warnings about the fresh home directory are noise; the fingerprint list is the answer.
  fprs="$(as_user gpg --homedir "${tmp}/gnupg" --batch --no-tty --show-keys --with-colons "${tmp}/1password.asc" 2>/dev/null | awk -F: 'prev=="pub" && $1=="fpr" {print toupper($10)} {prev=$1}')" || fprs=""
  # GUARD: spark-op-key-fingerprint the apt signing key is used only when its primary fingerprint equals the pin; anything else installs nothing.
  if [[ "$fprs" != "$_SPARK_OP_SIGNING_FPR" ]]; then
    _warn "1Password CLI: the signing key's fingerprint is not the pinned one; not adding the repository"
    return 1
  fi
  # GUARD-END: spark-op-key-fingerprint
  as_user gpg --homedir "${tmp}/gnupg" --batch --no-tty --dearmor --output "${tmp}/keyring.gpg" "${tmp}/1password.asc" || return 1
  as_user "$(_spark_seam SPARK_CURL_BIN curl)" --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --retry 3 -o "${tmp}/1password.pol" "${base}/debian/debsig/1password.pol" || return 1
  printf 'deb [arch=%s signed-by=%s] %s/debian/%s stable main\n' "$arch" "$keyring" "$base" "$arch" | as_user_piped tee -- "${tmp}/1password.list" >/dev/null || return 1
  as_root install -d -m 0755 /usr/share/keyrings "/etc/debsig/policies/${pol}" "/usr/share/debsig/keyrings/${pol}" || return 1
  as_root install -m 0644 "${tmp}/keyring.gpg" "$keyring" || return 1
  as_root install -m 0644 "${tmp}/1password.pol" "/etc/debsig/policies/${pol}/1password.pol" || return 1
  as_root install -m 0644 "${tmp}/keyring.gpg" "/usr/share/debsig/keyrings/${pol}/debsig.gpg" || return 1
  # GUARD: spark-op-source-last the source list is written after the key and the policy are in place, so apt never sees a source whose key is missing.
  as_root install -m 0644 "${tmp}/1password.list" /etc/apt/sources.list.d/1password.list || return 1
  # GUARD-END: spark-op-source-last
  _SPARK_APT_UPDATED=0
  _spark_apt_install 1password-cli || { _warn "1Password CLI: apt could not install it; continuing without op"; return 1; }
  # 2>/dev/null: a file the steps above never created is fine. || true: cleanup never changes the outcome.
  as_user rm -rf -- "${tmp}/gnupg" "${tmp}/1password.asc" "${tmp}/keyring.gpg" "${tmp}/1password.pol" "${tmp}/1password.list" 2>/dev/null || true
}

# Install when missing (default yes), then sign in on the terminal. Nothing here is fatal: op stays optional.
ensure_op(){
  local ans
  if _spark_op_bin; then _ok "1Password CLI present (${_SPARK_OP_BIN})"
  elif (( ARG_NO_OP )); then _run "1Password CLI not installed and --no-op given: continuing without it"; return 0
  else
    if ! _spark_noninteractive; then
      _spark_tty_open
      ans="$(_spark_ask 'Install the 1Password CLI from 1Password? [Y/n]: ')"
      case "$ans" in n|N|no|NO|No) _run "continuing without the 1Password CLI"; return 0 ;; esac
    fi
    case "$(_spark_os)" in
      macos) _spark_op_install_macos || return 0 ;;
      linux) _spark_op_install_linux || return 0 ;;
    esac
    _spark_op_bin || { _warn "1Password CLI: installed but not found on PATH or in ${_SPARK_LOCAL_BIN}"; return 0; }
    _ok "1Password CLI installed (${_SPARK_OP_BIN})"
  fi
  if _spark_op_signed_in; then _ok "1Password: signed in"; return 0; fi
  if _spark_noninteractive; then _run "1Password: not signed in and no terminal; the forge URL, token and key cannot be read from it"; return 0; fi
  _run "1Password: sign in (op's own prompts follow; Ctrl-C skips it)"
  # Up to three attempts. A typo in the sign-in address, the email, the Secret Key, the password or the code makes `op` stop, and without a
  # retry the run went on without 1Password and failed much later at the clone of a private forge. An attempt is two steps, as Beskar does:
  # `account add` with the terminal as every descriptor (its enrolment prompts, the authentication code among them, end early when stdout is
  # captured), then `signin`, whose stdout is the session line. `account add` is repeated whole (address, email, Secret Key, password,
  # code) until an account is registered; once it is, only `signin` (password, code) is.
  local attempt=0 what
  while (( ++attempt <= 3 )); do
    if ! _spark_op_has_account; then
      _spark_op account add <"$(_spark_seam SPARK_TTY /dev/tty)" >&9 2>&9 || _warn "1Password: adding the account did not complete"
    fi
    if _spark_op_has_account; then
      _spark_op_signin_capture signin || _warn "1Password: sign-in did not complete"
    fi
    _spark_op_signed_in && break
    (( attempt < 3 )) || break
    if _spark_op_has_account; then what="your password and authentication code"; else what="the sign-in address, your email, the Secret Key, your password and the authentication code"; fi
    _spark_tty_open
    # GUARD: spark-op-signin-retry a failed sign-in offers another attempt (default yes, three at most) and says what will be asked again; a no, or the third failure, continues without 1Password as before.
    ans="$(_spark_ask "1Password: not signed in. Try again? You will be asked for ${what} again [Y/n]: ")"
    case "$ans" in n|N|no|NO|No) break ;; esac
    # GUARD-END: spark-op-signin-retry
  done
  if _spark_op_signed_in; then _ok "1Password: signed in"; else _warn "1Password: not signed in; the forge URL, token and key will not be read from it"; fi
  return 0
}

# The vault that holds df_common: --op-vault / SPARK_OP_VAULT, else the ONE vault that holds it (several: exit 3 naming the flag).
_SPARK_VAULT=""
_spark_op_vault(){
  local out n
  [[ -n "$_SPARK_VAULT" ]] && return 0
  if [[ -n "$OP_VAULT" ]]; then _SPARK_VAULT="$OP_VAULT"; return 0; fi
  _spark_op_signed_in || return 1
  # 2>/dev/null: a locked or empty account prints an error; the empty answer is "no vault found".
  out="$(_spark_op item list --format json 2>/dev/null | as_user_piped jq -r --arg t df_common '[.[] | select(.title == $t) | .vault.name] | unique | .[]')" || out=""
  [[ -n "$out" ]] || return 1
  n="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  # GUARD: spark-op-vault-ambiguous several vaults hold df_common: spark refuses to guess and names the flag.
  if (( n > 1 )); then die3 "several 1Password vaults hold df_common; say which with --op-vault <name> (or SPARK_OP_VAULT)."; fi
  # GUARD-END: spark-op-vault-ambiguous
  _SPARK_VAULT="${out%%$'\n'*}"
  [[ "$_SPARK_VAULT" =~ $_SPARK_RE_VAULT ]] || { _SPARK_VAULT=""; return 1; }
}
# Read one field of one item in the vault, as the owner. The value goes to stdout for a pipe, never to a variable that is printed.
_spark_op_read(){  # _spark_op_read <item> <field>
  _spark_op_vault || return 1
  # 2>/dev/null: a missing item or field is "not available"; op's message would name the reference, which the caller already knows.
  _spark_op read "op://${_SPARK_VAULT}/${1}/${2}" 2>/dev/null
}

# ---------------------------------------------------------------------------------------
# Credentials for the clone (ssh first; https only to fetch and start spark). Every secret stays off argv, out of the
# environment, out of URLs and out of logs. Security refusals exit 3.
# ---------------------------------------------------------------------------------------
_SPARK_PRIV=""          # private directory (0700, owned by the owner): known_hosts, agent socket, askpass helper
_SPARK_AGENT_PID=""     # the private ssh-agent spark started (op source only)
_SPARK_AGENT_SOCK=""
_SPARK_KEYMODE=""       # agent | file | op | none, decided once
_SPARK_SSH_CMD=""       # the pinned GIT_SSH_COMMAND
_SPARK_HOSTS_DONE=" "   # " host:port " entries whose host key is already in the private known_hosts
_SPARK_NET_REASON=""    # why a soft preparation failed
NET_ENV=()
GIT_PRE=()
T_HOST=""; T_PORT=""

# Strict grammars. Kept in variables: bash 3.2 reads a quoted =~ operand literally.
_SPARK_RE_SSH_URL='^ssh://([A-Za-z0-9_][A-Za-z0-9._-]{0,63}@)?([A-Za-z0-9][A-Za-z0-9.-]{0,252})(:[0-9]{1,5})?(/[A-Za-z0-9._/-]+)$'
_SPARK_RE_SCP_URL='^([A-Za-z0-9_][A-Za-z0-9._-]{0,63})@([A-Za-z0-9][A-Za-z0-9.-]{0,252}):([A-Za-z0-9._/][A-Za-z0-9._/-]*)$'
_SPARK_RE_ABS_PATH='^/[A-Za-z0-9._/@+=,:-]+$'
_SPARK_RE_FPR='^SHA256:[A-Za-z0-9+/]{43}$'
_SPARK_RE_OP_REF='^op://[A-Za-z0-9][A-Za-z0-9 ._-]*/[A-Za-z0-9][A-Za-z0-9 ._-]*(/[A-Za-z0-9][A-Za-z0-9 ._-]*){1,2}(\?ssh-format=openssh)?$'
_SPARK_RE_USER='^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$'

_spark_ssh_parse(){
  local u="$1"
  T_HOST=""; T_PORT=22
  case "$u" in
    *[[:space:]]*|*[[:cntrl:]]*|*..*|*::*) return 1 ;;
  esac
  if [[ "$u" =~ $_SPARK_RE_SSH_URL ]]; then
    T_HOST="${BASH_REMATCH[2]}"
    if [[ -n "${BASH_REMATCH[3]}" ]]; then T_PORT="${BASH_REMATCH[3]#:}"; fi
  elif [[ "$u" =~ $_SPARK_RE_SCP_URL ]]; then
    T_HOST="${BASH_REMATCH[2]}"
  else
    return 1
  fi
  (( 10#$T_PORT >= 1 && 10#$T_PORT <= 65535 )) || return 1
  T_PORT=$(( 10#$T_PORT ))
}

_spark_secret_file_check(){  # _spark_secret_file_check <variable-name> <path>
  local label="$1" p="$2" dir
  [[ "$p" =~ $_SPARK_RE_ABS_PATH ]] || die3 "${label} must be an absolute path of plain characters."
  [[ "$p" != *..* ]] || die3 "${label} must not contain '..'."
  # GUARD: spark-secret-symlink a symlinked or non-regular secret file could be swapped for another target; refuse it.
  if [[ -L "$p" || ! -f "$p" ]]; then
    die3 "${label} (${p}) must be a regular file, not a symlink."
  fi
  # GUARD-END: spark-secret-symlink
  # GUARD: spark-secret-owner a secret file the owner does not own could have been planted or read by someone else; refuse it.
  if ! _spark_owned_by "$p" "$(_spark_seam SPARK_SECRET_OWNER_UID "$OWNER_UID")"; then
    die3 "${label} (${p}) must be owned by ${OWNER}."
  fi
  # GUARD-END: spark-secret-owner
  # GUARD: spark-secret-mode a secret readable by group or others is already exposed; it must be exactly mode 0600.
  if [[ -z "$(find "$p" -maxdepth 0 -type f -perm 600 -print)" ]]; then
    die3 "${label} (${p}) must have mode 0600 (set the mode yourself; spark never changes a secret's mode)."
  fi
  # GUARD-END: spark-secret-mode
  dir="${p%/*}"; [[ -n "$dir" ]] || dir="/"
  # The physical-path check comes FIRST: a symlinked directory is named as what it is, and its own mode (a symlink reads
  # as lrwxrwxrwx on Linux) is never mistaken for a writable parent.
  # GUARD: spark-secret-parent-real a symlinked directory in the path lets its owner swap the target after the check; the path must already be the physical one (pwd -P).
  # 2>/dev/null: a directory that cannot be entered prints an error; the empty answer then differs from $dir, which is the refusal.
  if [[ "$(cd "$dir" 2>/dev/null && pwd -P)" != "$dir" ]]; then
    die3 "the path of ${label} (${p}) goes through a symlink — give the physical path (cd <dir> && pwd -P)."
  fi
  # GUARD-END: spark-secret-parent-real
  # GUARD: spark-secret-parent a secret in a directory others can write can be replaced between the check and the use; refuse it.
  if _spark_group_world_writable "$dir"; then
    die3 "the directory of ${label} (${dir}) is writable by group or others — move the file to a private directory."
  fi
  # GUARD-END: spark-secret-parent
  # GUARD: spark-secret-parent-owner a parent directory owned by someone else (neither the owner nor root) lets that account replace the file; refuse it.
  if ! _spark_owned_by "$dir" "$OWNER_UID" && ! _spark_owned_by "$dir" 0; then
    die3 "the directory of ${label} (${dir}) must be owned by ${OWNER} or root."
  fi
  # GUARD-END: spark-secret-parent-owner
}

# Is an ssh-agent with at least one key reachable? (read-only: ssh-add -l)
_spark_agent_usable(){
  [[ "$(id -un)" == "$OWNER" ]] || return 1
  [[ -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK}" ]] || return 1
  command -v ssh-add >/dev/null 2>&1 || return 1
  # 2>/dev/null: an unreachable or empty agent just means "not a key source"; the exit status is the answer.
  SSH_AUTH_SOCK="$SSH_AUTH_SOCK" ssh-add -l >/dev/null 2>&1
}

# The ambient agent "can hold many unrelated keys" and ssh offers every one of them to the forge, so spark shows what it would
# offer (the fingerprints) before taking the agent as the key source. At a terminal the person confirms (Enter accepts a single
# key; several keys default to no); with no terminal one key is accepted and several are refused (nobody can choose). A plan run only
# shows them. rc 0 use the agent, 1 decline (the machine key ladder runs instead).
_spark_agent_confirm(){
  local list n line ans def prompt
  # 2>/dev/null: an unreachable agent was already ruled out by _spark_agent_usable; an empty list just ends up as "no".
  list="$(SSH_AUTH_SOCK="$SSH_AUTH_SOCK" ssh-add -l 2>/dev/null)" || return 1
  n="$(printf '%s\n' "$list" | grep -c .)"
  _run "the running ssh-agent holds ${n} key(s); the forge clone would offer every one of them:"
  while IFS= read -r line; do printf '     %s\n' "$line"; done <<EOF_AGENT_KEYS
$list
EOF_AGENT_KEYS
  if (( ARG_PLAN )); then return 0; fi
  if _spark_noninteractive; then
    if (( n == 1 )); then return 0; fi
    die3 "the ssh-agent holds ${n} keys and there is no terminal to choose between them: set SPARK_SSH_KEY_FILE or SPARK_SSH_KEY_OP_REF to name the key, or unset SSH_AUTH_SOCK."
  fi
  _spark_tty_open
  if (( n == 1 )); then def=Y; prompt='Use this key from the ssh-agent for the forge? [Y/n]: '
  else def=N; prompt="Use these ${n} keys from the ssh-agent for the forge? [y/N]: "; fi
  ans="$(_spark_ask "$prompt")"
  case "$ans" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    [Nn]|[Nn][Oo]) return 1 ;;
    *) [[ "$def" == Y ]] ;;
  esac
}

# Validate every ssh/https credential setting BEFORE any system step, and decide the key source.
# Starts nothing, contacts nothing (so --plan may call it).
validate_ssh_settings(){
  local fpr="${SPARK_SSH_HOST_FPR:-}"
  if [[ -n "$fpr" ]]; then
    # GUARD: spark-fpr-grammar a malformed host-key pin would make the comparison meaningless; refuse it.
    if ! [[ "$fpr" =~ $_SPARK_RE_FPR ]]; then
      die3 "SPARK_SSH_HOST_FPR must look like SHA256:<43 base64 characters> (ssh-keygen -lf <host key>.pub)."
    fi
    # GUARD-END: spark-fpr-grammar
  fi
  if [[ -n "${SPARK_SSH_KEY_FILE:-}" ]]; then _spark_secret_file_check SPARK_SSH_KEY_FILE "$SPARK_SSH_KEY_FILE"; fi
  if [[ -n "${SPARK_HTTPS_TOKEN_FILE:-}" ]]; then
    _spark_secret_file_check SPARK_HTTPS_TOKEN_FILE "$SPARK_HTTPS_TOKEN_FILE"
    if [[ -n "${SPARK_HTTPS_USER:-}" ]] && ! [[ "${SPARK_HTTPS_USER}" =~ $_SPARK_RE_USER ]]; then
      die3 "SPARK_HTTPS_USER is not a plain user name."
    fi
  fi
  if [[ -n "${SPARK_SSH_KEY_OP_REF:-}" ]]; then
    # GUARD: spark-opref-grammar the 1Password reference reaches op's argv; only op://vault/item[/section]/field is accepted.
    if ! [[ "${SPARK_SSH_KEY_OP_REF}" =~ $_SPARK_RE_OP_REF ]]; then
      die3 "SPARK_SSH_KEY_OP_REF must look like op://vault/item/field (optionally ?ssh-format=openssh)."
    fi
    # GUARD-END: spark-opref-grammar
  fi
  # Explicit settings win, in this order: SPARK_SSH_KEY_FILE, SPARK_SSH_KEY_OP_REF, and only when
  # neither is set the ambient ssh-agent (which can hold many unrelated keys). `none` here is not final: ensure_forge_key
  # finds, restores or generates ~/.ssh/id_ed25519 later.
  if [[ -n "${SPARK_SSH_KEY_FILE:-}" ]]; then
    _SPARK_KEYMODE=file
    if [[ -n "${SPARK_SSH_KEY_OP_REF:-}" ]]; then _run "SPARK_SSH_KEY_FILE is set: it is used and SPARK_SSH_KEY_OP_REF is ignored."; fi
  elif [[ -n "${SPARK_SSH_KEY_OP_REF:-}" ]]; then
    _SPARK_KEYMODE=op
  elif _spark_agent_usable && _spark_agent_confirm; then
    _SPARK_KEYMODE=agent
    _run "using the running ssh-agent (SSH_AUTH_SOCK) as the key source; set SPARK_SSH_KEY_FILE or SPARK_SSH_KEY_OP_REF to use a specific key instead."
  else
    _SPARK_KEYMODE=none
  fi
}

# The op source needs an op on PATH, but only when an ssh clone is going to use it (an https or local run never touches the reference).
_spark_op_required(){
  # GUARD: spark-op-absent an op reference with no op cannot be read; fail with exit 3 and the instruction.
  if ! _spark_op_bin; then
    die3 "SPARK_SSH_KEY_OP_REF is set but the 1Password CLI (op) is not installed (and --no-op or a declined install left it out): install it and sign in, or use an ssh-agent or SPARK_SSH_KEY_FILE."
  fi
  # GUARD-END: spark-op-absent
}

# Who the current 1Password session belongs to (an identity, never a secret), for the line that says where a key came from.
_spark_op_account(){
  local out
  # 2>/dev/null: whoami failing, or jq on nothing, just means the account stays unnamed.
  out="$(_spark_op whoami --format json 2>/dev/null </dev/null | jq -r --arg sep " at " '[.email // "?", .url // "?"] | join($sep)' 2>/dev/null)" || out=""
  printf '%s' "${out:-unknown account}"
}

# The private directory: 0700, owned by the owner (created by the owner, so a root run works), only
# ever removed by _spark_cleanup. Called in the main shell, never inside $(...) of the caller.
_spark_priv_dir(){
  [[ -z "$_SPARK_PRIV" ]] || return 0
  _SPARK_PRIV="$(as_user mktemp -d "${TMPDIR:-/tmp}/spk.XXXXXX")" || die3 "cannot create a private temporary directory."
  [[ -d "$_SPARK_PRIV" ]] || die3 "cannot create a private temporary directory."
}

_spark_kill_agent(){
  local pid="$_SPARK_AGENT_PID"
  _SPARK_AGENT_PID=""
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  # 2>/dev/null: the agent may already be gone; there is nothing more to do then.
  if [[ "$(id -un)" == "$OWNER" ]]; then kill "$pid" 2>/dev/null; else _spark_sudo -u "$OWNER" kill "$pid" 2>/dev/null; fi
  return 0
}

# Idempotent; runs on every exit path (EXIT, INT, TERM, HUP) and right after the last clone/fetch.
_spark_cleanup(){
  local f
  if [[ -n "$_SPARK_AGENT_PID" ]]; then _spark_kill_agent; fi
  if [[ -n "$_SPARK_PRIV" ]]; then
    for f in kh askpass a tok probe.err op.pkg 1password.asc keyring.gpg 1password.pol 1password.list; do
      if [[ -e "${_SPARK_PRIV}/${f}" || -L "${_SPARK_PRIV}/${f}" ]]; then as_user rm -f -- "${_SPARK_PRIV}/${f}" || _warn "could not remove ${_SPARK_PRIV}/${f}"; fi
    done
    [[ -d "${_SPARK_PRIV}/gnupg" ]] && as_user rm -rf -- "${_SPARK_PRIV}/gnupg"
    as_user rmdir -- "$_SPARK_PRIV" || _warn "could not remove ${_SPARK_PRIV}"
    _SPARK_PRIV=""
  fi
  _SPARK_HOSTS_DONE=" "
  _SPARK_SSH_CMD=""
  _SPARK_WATCH_STARTED=0
  return 0
}
_spark_on_signal(){  # _spark_on_signal <exit-code>
  trap - EXIT
  _spark_cleanup
  exit "$1"
}

# The key lives in the private agent for at most this many seconds (ssh-add -t, and the agent's own -t
# default). spark reloads it from op before a clone when it is older than _SPARK_KEY_RELOAD seconds, so
# a long installer between two clones never leaves a clone without its key. After a SIGKILL of spark
# the key therefore stops being usable within _SPARK_KEY_TTL seconds at the latest.
_SPARK_KEY_TTL=300
_SPARK_KEY_RELOAD=120
_SPARK_KEY_LOADED_AT=""
_SPARK_WATCH_STARTED=0

_spark_agent_load(){
  _run "loading the ssh key from 1Password into a private ssh-agent"
  # GUARD: spark-agent-load a key that cannot be read or loaded leaves no key source: stop with exit 3, never fall back to another one.
  if ! { as_user op read "${SPARK_SSH_KEY_OP_REF}"; } | as_user_piped env "SSH_AUTH_SOCK=${_SPARK_AGENT_SOCK}" ssh-add -q -t "$_SPARK_KEY_TTL" -; then
    die3 "could not load the key from SPARK_SSH_KEY_OP_REF (is op signed in, and is the reference right?)."
  fi
  # GUARD-END: spark-agent-load
  _SPARK_KEY_LOADED_AT="$SECONDS"
}

_spark_agent_watch(){  # _spark_agent_watch <agent-pid>
  local pid="$1"
  (( _SPARK_WATCH_STARTED == 0 )) || return 0
  _SPARK_WATCH_STARTED=1
  as_user sh -c '
    parent=$1; agent=$2; sock=$3; dir=$4
    while ps -p "$parent" >/dev/null 2>&1 && [ -S "$sock" ]; do sleep 1; done
    if [ -S "$sock" ]; then
      # 2>/dev/null: the agent may already be gone; nothing more to do then.
      kill "$agent" 2>/dev/null
      rm -f -- "$dir/kh" "$dir/askpass" "$dir/a" 2>/dev/null
      rmdir -- "$dir" 2>/dev/null
    fi' spark-watch "$$" "$pid" "$_SPARK_AGENT_SOCK" "$_SPARK_PRIV" </dev/null >/dev/null 2>&1 &
}

_spark_agent_start(){
  local sock out
  _spark_op_required
  if [[ -n "$_SPARK_AGENT_PID" ]]; then
    if (( SECONDS - _SPARK_KEY_LOADED_AT > _SPARK_KEY_RELOAD )); then _spark_agent_load; fi
    return 0
  fi
  _spark_priv_dir
  sock="${_SPARK_PRIV}/a"
  # GUARD: spark-agent-sock-len a socket path longer than the unix limit makes ssh-agent fail obscurely; say so.
  if (( ${#sock} > 100 )); then
    die3 "the temporary directory path is too long for an ssh-agent socket (${#sock} > 100): set TMPDIR to a shorter path."
  fi
  # GUARD-END: spark-agent-sock-len
  out="$(as_user ssh-agent -t "$_SPARK_KEY_TTL" -a "$sock" -s)" || die3 "could not start a private ssh-agent."
  if ! [[ "$out" =~ SSH_AGENT_PID=([0-9]+) ]]; then die3 "could not read the private ssh-agent's pid."; fi
  _SPARK_AGENT_PID="${BASH_REMATCH[1]}"
  _SPARK_AGENT_SOCK="$sock"
  _spark_agent_watch "$_SPARK_AGENT_PID"
  _spark_agent_load
}

# The owner's home directory, from the owner's own environment.
_SPARK_OWNER_HOME=""
_spark_owner_home(){
  [[ -z "$_SPARK_OWNER_HOME" ]] || return 0
  _SPARK_OWNER_HOME="$(as_user sh -c 'printf %s "$HOME"')" || _SPARK_OWNER_HOME=""
  if ! [[ "$_SPARK_OWNER_HOME" =~ $_SPARK_RE_ABS_PATH ]]; then _SPARK_OWNER_HOME=""; return 1; fi
}

_spark_hk_state(){  # _spark_hk_state <known_hosts-file> <host-field> <line>
  local kf="$1" hk="$2" line="$3" _h ltype lkey found l t k _r same=0 diff=0
  read -r _h ltype lkey _r <<<"$line"
  [[ -f "$kf" ]] || return 1
  # 2>/dev/null: no entry for the host is exit 1 with no output; the empty answer is the result.
  found="$(as_user ssh-keygen -F "$hk" -f "$kf" 2>/dev/null)" || found=""
  while IFS= read -r l; do
    [[ -n "$l" && "$l" != '#'* ]] || continue
    read -r _h t k _r <<<"$l"
    if [[ "$t" == "$ltype" ]]; then
      if [[ "$k" == "$lkey" ]]; then same=1; else diff=1; fi
    fi
  done <<EOF
$found
EOF
  if (( diff )); then return 2; fi
  if (( same )); then return 0; fi
  return 1
}

_spark_hk_conflict_check(){  # _spark_hk_conflict_check <line>
  local line="$1" hk rc=0
  hk="${line%% *}"
  _spark_owner_home || return 0
  _spark_hk_state "${_SPARK_OWNER_HOME}/.ssh/known_hosts" "$hk" "$line" || rc=$?
  # GUARD: spark-hostkey-conflict a different key of the same type already recorded for the host contradicts the pin; refuse (exit 3), never overwrite or append beside it.
  if (( rc == 2 )); then
    die3 "${_SPARK_OWNER_HOME}/.ssh/known_hosts already records a DIFFERENT host key of the same type for ${hk}, and it is not the one SPARK_SSH_HOST_FPR pins. One of them is wrong: check the fingerprint with the forge administrator; remove the stale line yourself if the pin is right."
  fi
  # GUARD-END: spark-hostkey-conflict
}

# The fleet's forge host-key pin from 1Password, when none was given: df_common/DF_FORGE_SSH_HOST_FPR (a fingerprint, not a secret).
# A new machine then trusts the forge exactly as SPARK_SSH_HOST_FPR would make it, with nothing typed. Absent or malformed: no pin.
_spark_forge_pin_from_vault(){
  local fpr=""
  [[ -z "${SPARK_SSH_HOST_FPR:-}" ]] || return 0
  _spark_op_signed_in || return 0
  fpr="$(_spark_op_read df_common DF_FORGE_SSH_HOST_FPR | tr -d '\r\n')" || fpr=""
  [[ -n "$fpr" ]] || return 0
  # GUARD: spark-vault-fpr-grammar a pin read from the vault meets the same grammar as SPARK_SSH_HOST_FPR, or it is not used.
  if ! [[ "$fpr" =~ $_SPARK_RE_FPR ]]; then
    _warn "df_common/DF_FORGE_SSH_HOST_FPR is not a SHA256:<43 base64 characters> fingerprint: not used as the forge's host-key pin."
    return 0
  fi
  # GUARD-END: spark-vault-fpr-grammar
  SPARK_SSH_HOST_FPR="$fpr"
  _ok "forge host-key pin from 1Password (df_common/DF_FORGE_SSH_HOST_FPR)"
}

# No pin and an unknown forge, with a person at the terminal: show the fingerprints the forge presents and ask (default no). A yes
# pins the ed25519 key (else the first one shown) for this run, so the strict pin path below writes and keeps it. rc 1 on no.
_spark_hostkey_confirm(){  # _spark_hostkey_confirm <host> <port> <host-field>
  local host="$1" port="$2" hk="$3" scan="" line="" fpout="" fp="" _fa="" _fb="" ed="" first="" pick="" ans="" vault="<vault>"
  # 2>/dev/null: ssh-keyscan prints its banner comments on stderr; stdout carries the keys.
  scan="$(as_user "$(_spark_seam SPARK_SSH_KEYSCAN_BIN ssh-keyscan)" -T 10 -p "$port" -- "$host" 2>/dev/null)" || scan=""
  [[ -n "$scan" ]] || return 1
  _run "${hk} is not known on this machine yet. It presents these host keys:"
  while IFS= read -r line; do
    [[ -n "$line" && "$line" != '#'* ]] || continue
    fpout="$(printf '%s\n' "$line" | as_user_piped ssh-keygen -l -f -)" || continue
    fp=""; read -r _fa fp _fb <<<"$fpout" || fp=""
    [[ "$fp" =~ $_SPARK_RE_FPR ]] || continue
    printf '     %s\n' "$fpout"
    case "$line" in *" ssh-ed25519 "*) ed="$fp" ;; esac
    if [[ -z "$first" ]]; then first="$fp"; fi
  done <<EOF
$scan
EOF
  pick="${ed:-$first}"
  [[ -n "$pick" ]] || return 1
  _spark_tty_open
  # GUARD: spark-hostkey-confirm a first-seen forge key is trusted only on an explicit yes at a terminal (default no), never when nobody is there.
  ans="$(_spark_ask "Is ${pick} the forge's host key? Say yes only if you checked it with the forge's administrator or on the server [y/N]: ")"
  case "$ans" in [Yy]|[Yy][Ee][Ss]) ;; *) return 1 ;; esac
  # GUARD-END: spark-hostkey-confirm
  SPARK_SSH_HOST_FPR="$pick"
  _ok "pinned ${pick} for ${hk} (confirmed at the terminal)"
  if [[ -n "$_SPARK_VAULT" ]]; then vault="$_SPARK_VAULT"; fi
  _run "so the next machine is not asked, store it once in 1Password: op item edit df_common --vault '${vault}' 'DF_FORGE_SSH_HOST_FPR[text]=${pick}'"
}

_spark_known_hosts(){  # _spark_known_hosts <host> <port> <hard|soft>
  local host="$1" port="$2" strength="$3" hk scan line fp fpout _fa _fb seen="" matched=0 kh home_kh
  [[ "$_SPARK_HOSTS_DONE" != *" ${host}:${port} "* ]] || return 0
  hk="$host"; if [[ "$port" != 22 ]]; then hk="[${host}]:${port}"; fi
  _spark_priv_dir
  kh="${_SPARK_PRIV}/kh"
  if [[ -n "${SPARK_SSH_HOST_FPR:-}" ]]; then
    # 2>/dev/null: ssh-keyscan prints its banner comments on stderr; stdout carries the keys.
    scan="$(as_user "$(_spark_seam SPARK_SSH_KEYSCAN_BIN ssh-keyscan)" -T 10 -p "$port" -- "$host" 2>/dev/null)" || scan=""
    while IFS= read -r line; do
      [[ -n "$line" && "$line" != '#'* ]] || continue
      fpout="$(printf '%s\n' "$line" | as_user_piped ssh-keygen -l -f -)" || fpout=""
      fp=""; read -r _fa fp _fb <<<"$fpout" || fp=""
      seen="${seen:+$seen }${fp:-unreadable}"
      # GUARD: spark-hostkey-pin first contact is trusted only when the presented key's fingerprint equals SPARK_SSH_HOST_FPR exactly; only the matching line is written.
      if [[ "$fp" == "${SPARK_SSH_HOST_FPR}" ]]; then
        _spark_hk_conflict_check "$line"
        printf '%s\n' "$line" | as_user_piped tee -a -- "$kh" >/dev/null || die3 "could not write the private known_hosts."
        matched=1
      fi
      # GUARD-END: spark-hostkey-pin
    done <<EOF
$scan
EOF
    if (( ! matched )); then
      # GUARD: spark-hostkey-mismatch a host that presents keys none of which is the pin is refused in hard AND soft mode (a fetch or re-run included): a WARN would let a swapped host be skipped silently.
      if [[ -n "$seen" ]]; then
        die3 "the host key of ${hk} does not match SPARK_SSH_HOST_FPR (presented: ${seen}). Refusing: check the pin and the host."
      fi
      # GUARD-END: spark-hostkey-mismatch
      # Nothing presented at all: unreachable. A clone needs it (exit 3); an update of an existing checkout does not.
      _SPARK_NET_REASON="could not read a host key from ${hk} (offline?)"
      if [[ "$strength" == hard ]]; then die3 "$_SPARK_NET_REASON"; fi
      return 1
    fi
  else
    home_kh=""
    if _spark_owner_home; then home_kh="${_SPARK_OWNER_HOME}/.ssh/known_hosts"; fi
    if [[ -n "$home_kh" && -f "$home_kh" ]]; then
      # 2>/dev/null: no entry is a normal answer (exit 1), not an error to show.
      scan="$(as_user ssh-keygen -F "$hk" -f "$home_kh" 2>/dev/null)" || scan=""
      while IFS= read -r line; do
        [[ -n "$line" && "$line" != '#'* ]] || continue
        # GUARD: spark-kh-write a failed write of the private known_hosts must stop the run (errexit is off in this call chain): ssh would otherwise run against an empty file or a partial one.
        printf '%s\n' "$line" | as_user_piped tee -a -- "$kh" >/dev/null || die3 "could not write the private known_hosts."
        # GUARD-END: spark-kh-write
        matched=1
      done <<EOF
$scan
EOF
    fi
    if (( ! matched )); then
      if ! _spark_noninteractive && _spark_hostkey_confirm "$host" "$port" "$hk"; then
        _spark_known_hosts "$host" "$port" "$strength"; return $?
      fi
      _SPARK_NET_REASON="the host key of ${hk} is not trusted yet. Store its fingerprint in 1Password (df_common/DF_FORGE_SSH_HOST_FPR), or Pin it: export SPARK_SSH_HOST_FPR=SHA256:... (the fingerprint of the forge's ssh host key, from its administrator or: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub on the server). spark never accepts a first-seen key on trust."
      if [[ "$strength" == hard ]]; then die3 "$_SPARK_NET_REASON"; fi
      return 1
    fi
  fi
  _SPARK_HOSTS_DONE="${_SPARK_HOSTS_DONE}${host}:${port} "
}

# After the last clone: keep the PINNED host key, so the installer's later ssh calls are strict about the same key without a
# second trust-on-first-use. Only the lines that matched the pin; written as the owner into ~/.ssh/known_hosts as a managed block
# (D014 markers, atomic rename, the file's mode kept), by spark itself: it must work for any --repo, not only dotFiles. An identical
# entry is left alone; a recorded DIFFERENT key was refused earlier (exit 3). Failing to write it after that is a WARN.
_spark_hostkey_persist(){
  local kh kf new="" line hk rc dir tmp begin end old="" body=""   # both initialised: bash 5 aborts on a declared-but-unset local under set -u (a first run has no known_hosts)
  [[ -n "${SPARK_SSH_HOST_FPR:-}" && -n "$_SPARK_PRIV" ]] || return 0
  kh="${_SPARK_PRIV}/kh"
  [[ -s "$kh" ]] || return 0
  _spark_owner_home || { _warn "could not record the pinned host key: the owner's home directory is not a plain path."; return 0; }
  kf="${_SPARK_OWNER_HOME}/.ssh/known_hosts"
  while IFS= read -r line; do
    [[ -n "$line" && "$line" != '#'* ]] || continue
    hk="${line%% *}"
    rc=0; _spark_hk_state "$kf" "$hk" "$line" || rc=$?
    case "$rc" in
      0) ;;
      2) _spark_hk_conflict_check "$line" ;;
      *) new="${new}${line}"$'\n' ;;
    esac
  done <<EOF
$(as_user cat -- "$kh")
EOF
  if [[ -z "$new" ]]; then _ok "the pinned host key is already recorded in ${kf}"; return 0; fi
  begin="# >>> dotFiles:forge-hostkey (managed — do not edit between markers) >>>"
  end="# <<< dotFiles:forge-hostkey <<<"
  dir="${kf%/*}"
  as_user test -d "$dir" || as_user mkdir -m 0700 -- "$dir" || { _warn "could not create ${dir}"; return 0; }
  # The existing block's lines are kept (another forge pinned earlier); everything outside the block is kept as it is.
  if as_user test -f "$kf"; then
    old="$(as_user awk -v b="$begin" -v e="$end" '$0==b{inb=1;next} $0==e{inb=0;next} inb && $0 !~ /^# /{print}' "$kf")" || old=""
    body="$(as_user awk -v b="$begin" -v e="$end" '$0==b{inb=1;next} $0==e{inb=0;next} !inb{print}' "$kf")" || body=""
  fi
  tmp="$(as_user mktemp "${kf}.XXXXXX")" || { _warn "could not stage ${kf}"; return 0; }
  {
    [[ -n "$body" ]] && printf '%s\n' "$body"
    printf '%s\n' "$begin"
    { [[ -n "$old" ]] && printf '%s\n' "$old"; printf '%s' "$new"; } | awk '!seen[$0]++'
    printf '%s\n' "$end"
  } | as_user_piped tee -- "$tmp" >/dev/null || { as_user rm -f -- "$tmp"; _warn "could not write ${kf}"; return 0; }
  local mode=""
  # 2>/dev/null: perl reads the mode the same way on macOS and Linux (BSD and GNU stat take different flags); no perl or an unreadable file means 644 below.
  if as_user test -f "$kf"; then
    mode="$(as_user perl -e 'printf("%o", (stat($ARGV[0]))[2] & 07777)' "$kf" 2>/dev/null)" || mode=""
    # An existing file whose mode cannot be read (no perl) is made 600, never 644: the rewrite must not widen what the owner set.
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || mode=600
  fi
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || mode=644
  as_user chmod "$mode" "$tmp" || { as_user rm -f -- "$tmp"; _warn "could not set the mode of ${kf}"; return 0; }
  if as_user mv -f -- "$tmp" "$kf"; then _ok "recorded the pinned host key in ${kf} (managed block dotFiles:forge-hostkey)"
  else as_user rm -f -- "$tmp"; _warn "could not record the pinned host key in ${kf} — the installer's ssh calls will not know it."; fi
}

_spark_ssh_prepare(){  # _spark_ssh_prepare <host> <port> <hard|soft>
  local host="$1" port="$2" strength="$3" ssh_bin ident="" kh algs=""
  ssh_bin="$(command -v ssh)" || ssh_bin=""
  ssh_bin="$(_spark_seam SPARK_SSH_BIN "$ssh_bin")"
  if [[ -z "$ssh_bin" || ! -x "$ssh_bin" || ! "$ssh_bin" =~ $_SPARK_RE_ABS_PATH ]]; then
    _SPARK_NET_REASON="no usable ssh client (spark needs ssh for an ssh:// source)"
    if [[ "$strength" == hard ]]; then die3 "$_SPARK_NET_REASON"; fi
    return 1
  fi
  # IdentityFile=none: with an explicit (here: nonexistent) identity file ssh does not add the owner's default
  # ~/.ssh/id_* files, so only the intended key is ever offered. The key-file source adds IdentitiesOnly.
  case "$_SPARK_KEYMODE" in
    agent) ident="-o IdentityAgent=SSH_AUTH_SOCK -o IdentityFile=none" ;;
    file)  ident="-o IdentityAgent=none -o IdentitiesOnly=yes -o IdentityFile=${SPARK_SSH_KEY_FILE}" ;;
    op)
      # The reference needs op; in soft mode (a probe, an update) its absence is a reason to fall back, not a refusal (hard: exit 3).
      if ! _spark_op_bin; then
        _SPARK_NET_REASON="SPARK_SSH_KEY_OP_REF is set but the 1Password CLI (op) is not installed"
        if [[ "$strength" == hard ]]; then _spark_op_required; fi
        return 1
      fi
      _spark_agent_start; ident="-o IdentityAgent=${_SPARK_AGENT_SOCK} -o IdentityFile=none" ;;
    *)
      _SPARK_NET_REASON="no ssh key source: start an ssh-agent with a key (SSH_AUTH_SOCK), or set SPARK_SSH_KEY_FILE=/abs/path (mode 0600), or SPARK_SSH_KEY_OP_REF=op://vault/item/field"
      if [[ "$strength" == hard ]]; then die3 "$_SPARK_NET_REASON"; fi
      return 1 ;;
  esac
  _spark_known_hosts "$host" "$port" "$strength" || return 1
  kh="${_SPARK_PRIV}/kh"
  [[ "$kh" =~ $_SPARK_RE_ABS_PATH ]] || die3 "the temporary directory name has unexpected characters."
  # Only the key types the verified known_hosts holds may be negotiated (an rsa key is offered under its sha2 names too).
  algs="$(as_user awk '$1 !~ /^#/ && NF >= 3 { if ($2 == "ssh-rsa") t = "rsa-sha2-512,rsa-sha2-256,ssh-rsa"; else t = $2; if (!(t in seen)) { seen[t] = 1; out = out (out == "" ? "" : ",") t } } END { print out }' "$kh")" || algs=""
  [[ -z "$algs" || "$algs" =~ ^[A-Za-z0-9@.,-]+$ ]] || algs=""
  # -F /dev/null: neither ~/.ssh/config nor /etc/ssh/ssh_config applies (no Match exec, ProxyJump, Include,
  # ControlPath reuse). Every value that could run a command or reach elsewhere is pinned off.
  _SPARK_SSH_CMD="'${ssh_bin}' -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${kh} -o GlobalKnownHostsFile=/dev/null -o UpdateHostKeys=no -o VerifyHostKeyDNS=no -o CheckHostIP=no -o IgnoreUnknown=KnownHostsCommand,SecurityKeyProvider -o KnownHostsCommand=none -o SecurityKeyProvider=internal ${algs:+-o HostKeyAlgorithms=${algs} }-o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes -o ProxyCommand=none -o ProxyJump=none -o LocalCommand=none -o PermitLocalCommand=no -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=15 -o ConnectionAttempts=1 ${ident}"
}

_spark_askpass_prepare(){  # _spark_askpass_prepare <host[:port]>
  local hostport="$1" ap user="${SPARK_HTTPS_USER:-git}"
  [[ "$hostport" =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ ]] || die3 "unexpected host in the https URL."
  _spark_priv_dir
  ap="${_SPARK_PRIV}/askpass"
  [[ "$ap" =~ $_SPARK_RE_ABS_PATH ]] || die3 "the temporary directory name has unexpected characters."
  as_user install -m 0700 /dev/null "$ap" || die3 "cannot create the askpass helper."
  # GUARD: spark-askpass-exact the helper answers only the exact prompts "Username for 'https://H': " and "Password for 'https://U@H': " for the pinned host and user; any other prompt gets no answer.
  printf '%s\n' '#!/bin/sh' \
    "case \"\$1\" in" \
    "  \"Username for 'https://${hostport}': \") printf '%s\\n' '${user}' ;;" \
    "  \"Password for 'https://${user}@${hostport}': \") exec cat -- '${SPARK_HTTPS_TOKEN_FILE}' ;;" \
    "  *) exit 1 ;;" \
    "esac" | as_user_piped tee -- "$ap" >/dev/null || die3 "cannot write the askpass helper."
  # GUARD-END: spark-askpass-exact
}

_spark_net_env(){  # _spark_net_env <hard|soft> <proto> <url>
  local strength="$1" proto="$2" url="$3" hostport
  NET_ENV=(); GIT_PRE=()
  case "$proto" in
    ssh)
      if ! _spark_ssh_parse "$url"; then
        _SPARK_NET_REASON="the git origin '${url}' is not a plain ssh address"
        if [[ "$strength" == hard ]]; then die3 "$_SPARK_NET_REASON"; fi
        return 1
      fi
      _spark_ssh_prepare "$T_HOST" "$T_PORT" "$strength" || return 1
      NET_ENV=(-u SSH_ASKPASS -u SSH_ASKPASS_REQUIRE -u SSH_AGENT_PID -u SSH_SK_PROVIDER)
      case "$_SPARK_KEYMODE" in
        agent) NET_ENV+=("SSH_AUTH_SOCK=${SSH_AUTH_SOCK}") ;;
        op)    NET_ENV+=("SSH_AUTH_SOCK=${_SPARK_AGENT_SOCK}") ;;
        *)     NET_ENV+=(-u SSH_AUTH_SOCK) ;;
      esac
      NET_ENV+=("GIT_ALLOW_PROTOCOL=ssh" "GIT_TERMINAL_PROMPT=0" "GIT_SSH_COMMAND=${_SPARK_SSH_CMD}" "GIT_SSH_VARIANT=ssh") ;;
    https)
      NET_ENV=("GIT_ALLOW_PROTOCOL=https" "GIT_TERMINAL_PROMPT=0")
      # Always: the credential is never keyed by path (one answer for the whole host), a redirect is never
      # followed to another place, TLS is always verified, and no credential helper/keychain may store anything.
      GIT_PRE=(-c credential.useHttpPath=false -c http.followRedirects=false -c http.sslVerify=true -c credential.helper=)
      if [[ -n "${SPARK_HTTPS_TOKEN_FILE:-}" ]]; then
        hostport="${url#https://}"; hostport="${hostport%%/*}"
        _spark_askpass_prepare "$hostport"
        NET_ENV+=("GIT_ASKPASS=${_SPARK_PRIV}/askpass")
      fi ;;
    *) NET_ENV=("GIT_ALLOW_PROTOCOL=${proto}" "GIT_TERMINAL_PROMPT=0") ;;
  esac
  # No user or system git configuration steers a spark clone (insteadOf rewrites, proxies, helpers, hooks).
  NET_ENV+=("GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_NOSYSTEM=1")
  # GUARD: spark-git-c-locale a network git call speaks git's own English (LC_ALL=C, no LANGUAGE): spark recognises a moved release tag by the words of git's message, and under another locale that message is not those words, so a moved tag would pass for a fetch that merely failed (D079). env wants its -u options first.
  NET_ENV=(-u LANGUAGE -u LC_MESSAGES ${NET_ENV[@]+"${NET_ENV[@]}"} "LC_ALL=C")
  # GUARD-END: spark-git-c-locale
}

# Every other git call of spark (origin, HEAD, merge, checkout, status) runs without the user's and the system's git configuration too.
_spark_git_local(){ as_user env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"; }

# ---------------------------------------------------------------------------------------
# Where the repository comes from.
# ---------------------------------------------------------------------------------------
REPO_BASE=""
_SPARK_PROTO="https"

_spark_base_kind(){
  local b="$1" auth
  case "$b" in
    *[[:space:]]*) return 0 ;;
    *[[:cntrl:]]*) return 0 ;;
    *example.com*|*'<owner>'*|*'<user>'*) return 0 ;;
    ssh://?*)
      # GUARD: spark-ssh-base-grammar an ssh base must match ssh://[user@]host[:port]/path exactly (no leading dash, no ext:: or file:, no whitespace); anything else could reach ssh or git as an option.
      if ! _spark_ssh_parse "$b"; then return 0; fi
      # GUARD-END: spark-ssh-base-grammar
      printf 'ssh' ;;
    https://?*)
      auth="${b#https://}"; auth="${auth%%/*}"
      # GUARD: spark-base-credentials a URL with embedded credentials would put them on argv and in .git/config.
      case "$auth" in *@*) return 0 ;; esac
      # GUARD-END: spark-base-credentials
      printf 'https' ;;
    /*) printf 'local' ;;
  esac
  return 0
}

_spark_adopt_base(){  # _spark_adopt_base <base> <allow-local> → 0 adopted, 1 not acceptable
  local b="$1" allow_local="$2" kind
  b="${b%/}"
  kind="$(_spark_base_kind "$b")"
  case "$kind" in
    https) _SPARK_PROTO="https" ;;
    ssh)   _SPARK_PROTO="ssh" ;;
    local)
      [[ "$allow_local" == "1" ]] || return 1
      [[ -d "$b" ]] || return 1
      _SPARK_PROTO="file" ;;
    *) return 1 ;;
  esac
  REPO_BASE="$b"
  return 0
}

validate_explicit_base(){
  [[ -n "${SPARK_REPO_BASE:-}" ]] || return 0
  if _spark_adopt_base "$SPARK_REPO_BASE" 1; then return 0; fi
  # GUARD: spark-base-invalid an explicit SPARK_REPO_BASE that is not https or an existing absolute local directory is refused, never guessed around.
  die "SPARK_REPO_BASE '${SPARK_REPO_BASE}' is not usable: use https://host/<owner> (no credentials, no placeholder), ssh://[user@]host[:port]/<owner> (plain characters only), or an absolute path to an existing local directory."
  # GUARD-END: spark-base-invalid
}

# Only when a clone is needed (an existing checkout updates from its own origin, so a re-run does not come here at all).
resolve_repo_base(){
  local op_url input
  # 1. Explicit and already validated.
  [[ -n "$REPO_BASE" ]] && return 0
  # 2. 1Password, when signed in: the forge URL in df_common (vault-qualified; the labels reach jq as data, never spliced, F14).
  if _spark_op_signed_in && _spark_op_vault; then
    # 2>/dev/null: a missing item or a locked vault just means "not available here".
    op_url="$(_spark_op item get df_common --vault "$_SPARK_VAULT" --fields label=FORGEJO_URL,label=DF_FORGEJO_URL --format json 2>/dev/null)" || op_url=""
    if [[ -n "$op_url" ]]; then
      op_url="$(as_user jq -r -n --arg j "$op_url" --arg a FORGEJO_URL --arg b DF_FORGEJO_URL \
        '$j | fromjson | (if type == "array" then .[] else . end) | select(.label == $a or .label == $b) | .value // empty')" || op_url=""
      op_url="${op_url%%$'\n'*}"
      if [[ -n "$op_url" ]] && _spark_adopt_base "$op_url" 0; then _ok "git base from 1Password"; return 0; fi
    fi
  fi
  # 3. Ask on the terminal (https or ssh://; never a local path).
  if ! _spark_noninteractive; then
    _spark_tty_open
    input="$(_spark_ask 'Git base URL (https://host/<owner> or ssh://[user@]host[:port]/<owner>): ')"
    if [[ -n "$input" ]] && _spark_adopt_base "$input" 0; then return 0; fi
  fi
  die "Git repository base is required: --base https://host/<owner> or ssh://[user@]host[:port]/<owner> (or an absolute path to a local directory of repositories)."
}

_spark_repo_url(){  # _spark_repo_url <name> [soft]: soft prints nothing instead of dying
  local name="$1"
  if [[ "$_SPARK_PROTO" == "file" ]]; then
    if [[ -e "${REPO_BASE}/${name}.git" ]]; then printf '%s' "${REPO_BASE}/${name}.git"; return 0; fi
    if [[ -d "${REPO_BASE}/${name}" ]]; then printf '%s' "${REPO_BASE}/${name}"; return 0; fi
    if [[ "${2:-}" == "soft" ]]; then return 0; fi
    die "no repository for ${name} under ${REPO_BASE} (looked for ${name}.git and ${name})."
  fi
  printf '%s' "${REPO_BASE}/${name}.git"
}

_spark_git(){  # _spark_git <hard|soft> <proto> <url> <git args...>
  local strength="$1" proto="$2" url="$3"; shift 3
  _spark_net_env "$strength" "$proto" "$url" || { _warn "$_SPARK_NET_REASON"; return 1; }
  as_user env ${NET_ENV[@]+"${NET_ENV[@]}"} git ${GIT_PRE[@]+"${GIT_PRE[@]}"} "$@"
}

_spark_proto_of(){
  # GUARD: spark-origin-ext-helper an origin using a transport helper (ext::, fd::, any scheme::) can run commands; never classify it as ssh.
  case "$1" in
    *::*) die3 "unrecognised git origin '$1' (a transport helper)." ;;
  esac
  # GUARD-END: spark-origin-ext-helper
  case "$1" in
    https://*) printf 'https' ;;
    ssh://*|*@*:*) printf 'ssh' ;;
    /*) printf 'file' ;;
    *) die "unrecognised git origin '$1'." ;;
  esac
}

_spark_url_key(){
  local u="$1"
  u="${u%/}"; u="${u%.git}"; u="${u%/}"
  case "$u" in
    /*) printf '%s' "$u"; return 0 ;;
    https://*|http://*|ssh://*) u="${u#*://}" ;;
    *:*) u="${u%%:*}/${u#*:}" ;;   # bash 3.2 keeps the backslash of ${u/:/\/}: split instead
  esac
  u="${u#*@}"
  if [[ "$u" =~ ^([^/:]*):[0-9]+/(.*)$ ]]; then u="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"; fi
  printf '%s' "$u" | tr 'A-Z' 'a-z'
}

_spark_check_origin(){  # _spark_check_origin <name> <checkout> <origin>
  local name="$1" dest="$2" origin="$3" want
  if [[ -n "$REPO_BASE" ]]; then
    want="$(_spark_repo_url "$name" soft)"
    # GUARD: spark-origin-mismatch a checkout whose origin is not the requested source would run foreign code in ./install; refuse (scheme, user, port and .git are ignored).
    if [[ -n "$want" && "$(_spark_url_key "$origin")" != "$(_spark_url_key "$want")" ]]; then
      die "${name}: the checkout at ${dest} comes from '${origin}', not the requested '${want}' — refusing to run its installer; move it aside or fix SPARK_REPO_BASE."
    fi
    # GUARD-END: spark-origin-mismatch
  fi
}

# ---------------------------------------------------------------------------------------
# The ssh key for the forge (D097, amends D040): find, restore from 1Password, generate; then register.
# ---------------------------------------------------------------------------------------
_SPARK_HOSTNAME=""
_SPARK_KEY_PATH=""
_SPARK_KEY_REGISTERED=0
_SPARK_MACHINE_NAME_SETTLED=0
_spark_hostname(){
  [[ -n "$_SPARK_HOSTNAME" ]] && return 0
  local def ans="" n=0
  # An explicit --machine-name is the answer: nothing is asked (it was validated with the arguments).
  if [[ -n "$ARG_MACHINE_NAME" ]]; then
    _SPARK_HOSTNAME="$ARG_MACHINE_NAME"; _SPARK_MACHINE_NAME_SETTLED=1
    _ok "machine name: ${_SPARK_HOSTNAME}"
    return 0
  fi
  # The default: DF_HOSTNAME from spark's own environment when it is a valid name, else the short hostname.
  # 2>/dev/null: a host without a name prints an error and an empty name, which the grammar check below refuses.
  def="$(_spark_seam SPARK_HOSTNAME "$(hostname -s 2>/dev/null)")"
  if [[ -n "${DF_HOSTNAME:-}" && "${DF_HOSTNAME}" =~ $_SPARK_RE_HOSTLABEL ]]; then def="$DF_HOSTNAME"; fi
  if ! _spark_noninteractive; then
    _spark_tty_open
    while (( n++ < 3 )); do
      ans="$(_spark_ask "Machine name: it names this host's ssh key and its 1Password item [${def}]: ")"
      ans="${ans:-$def}"
      [[ "$ans" =~ $_SPARK_RE_HOSTLABEL ]] && break
      _warn "'${ans:0:40}' is not a valid machine name (letters, digits and inner hyphens, 1-63 characters)."
      ans=""
    done
    [[ -n "$ans" ]] || die3 "no valid machine name given; pass --machine-name <name>."
  else
    # GUARD: spark-hostname-grammar with nobody to ask, a default that is not a name (RFC 1123 label) stops the run: it would become a key comment, a 1Password item name and a forge key title.
    [[ "$def" =~ $_SPARK_RE_HOSTLABEL ]] || die3 "the short hostname '${def}' is not a valid machine name (letters, digits and inner hyphens, 1-63 characters) and there is no terminal to ask: pass --machine-name <name>."
    # GUARD-END: spark-hostname-grammar
    ans="$def"
    _run "machine name: ${ans} (this machine's hostname; pass --machine-name to choose another)"
  fi
  _SPARK_HOSTNAME="$ans"; _SPARK_MACHINE_NAME_SETTLED=1
  _ok "machine name: ${_SPARK_HOSTNAME}"
}
_spark_ssh_dir(){
  _spark_owner_home || die3 "the owner's home directory is not a plain path."
  printf '%s' "$(_spark_seam SPARK_HOME_SSH_DIR "${_SPARK_OWNER_HOME}/.ssh")"
}
# Write stdin into <path> as the owner, created at mode 0600 (umask 077), never over an existing file.
_spark_write_private(){  # _spark_write_private <path>
  local p="$1"
  [[ ! -e "$p" && ! -L "$p" ]] || return 1
  as_user_piped sh -c 'umask 077; cat > "$1"' spark-write "$p"
}

# Register <pubkey file> on the forge through its API, with the token on stdin (curl -K -). rc 0 registered or already there, 1 not.
# The forge holds a DIFFERENT key under this machine's title. What to do depends on what 1Password holds for the same name (the vault item is
# named by the title): "delete the forge entry" is right only when the key on this disk IS the stored one; when the vault holds another key,
# that forge entry is the registered copy of it, and the key to remove is the LOCAL one (it is then restored from the vault on the next run).
_spark_pub_fpr(){  # _spark_pub_fpr <public key line> → SHA256:… (empty when it is not a key)
  local out fp="" _a _b
  # 2>/dev/null: a line that is not a key gives an empty fingerprint, which the caller words.
  out="$(printf '%s\n' "$1" | as_user_piped ssh-keygen -l -f - 2>/dev/null)" || out=""
  read -r _a fp _b <<<"$out" || fp=""
  printf '%s' "$fp"
}
_spark_key_collision_advice(){  # _spark_key_collision_advice <title> <local public key line> <local public key file>
  local title="$1" lpub="$2" pubf="$3" vpub="" vfp lfp keyfile="${3%.pub}"
  # 2>/dev/null: no vault, no sign-in or no item is "the vault holds nothing"; op's message would only name the reference.
  if _spark_op_signed_in && _spark_op_vault; then vpub="$(_spark_op_read "$title" id_ed25519.pub 2>/dev/null | head -n 1)" || vpub=""; fi
  lfp="$(_spark_pub_fpr "$lpub")"; vfp="$(_spark_pub_fpr "$vpub")"
  # GUARD: spark-collision-advice when 1Password holds a DIFFERENT key for this machine, the forge entry is that key's registered copy: the advice is to remove the LOCAL key and re-run (it is restored), never to delete the forge entry.
  if [[ -n "$vfp" && -n "$lfp" && "$vfp" != "$lfp" ]]; then
    _warn "the forge already has a key titled '${title}', and it is not the key on this disk (${lfp})."
    _warn "1Password holds this machine's key (item ${title}, ${vfp}): that forge entry is its registered copy, so do NOT delete it."
    _warn "Remove the key on this disk and re-run; spark restores the one from 1Password:  rm -f ${keyfile} ${pubf}"
    return 0
  fi
  # GUARD-END: spark-collision-advice
  if [[ -n "$vfp" && "$vfp" == "$lfp" ]]; then
    _warn "the forge has a different key titled '${title}', but 1Password's copy matches the key on this disk (${lfp}): the forge entry is stale. Delete it in Settings → SSH Keys, then re-run."
    return 0
  fi
  _warn "a DIFFERENT key titled '${title}' is on the forge account (a rebuilt host?). Before deleting it: if 1Password holds this machine's key, remove the key on this disk (rm -f ${keyfile} ${pubf}) and re-run to restore that one instead. Otherwise delete the forge entry in Settings → SSH Keys, then re-run."
}
_spark_forge_register_key(){  # _spark_forge_register_key <api base https://host[:port]> <pubkey file> <title>
  local api="$1" pubf="$2" title="$3" body code pub keytype keyb64 list
  pub="$(as_user cat -- "$pubf")" || return 1
  read -r keytype keyb64 _ <<<"$pub"
  body="$(as_user jq -nc --arg t "$title" --arg k "${keytype} ${keyb64} ${title}" '{title:$t,key:$k}')" || return 1
  # The token never touches argv: curl reads its config (the Authorization header) from stdin.
  # 2>/dev/null: the HTTP status is the answer; curl's own text could echo the request.
  code="$( { printf 'header = "Authorization: token '; _spark_op_read df_common DF_FORGEJO_API_TOKEN | tr -d '\r\n' | sed 's/["\\]//g'; printf '"\n'; } \
    | as_user_piped "$(_spark_seam SPARK_CURL_BIN curl)" -K - -sS -m 20 --proto '=https' --tlsv1.2 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "$body" "${api}/api/v1/user/keys" 2>/dev/null )" || code="000"
  case "$code" in
    201) _ok "registered the ssh key '${title}' on ${api}"; return 0 ;;
    422)
      # 422 is "exists" for the key OR for the title: only the key really being on the account counts (a rebuilt host's new key under an old title is a stale entry).
      # 2>/dev/null: the listing or nothing is the answer; curl's own text could echo the request.
      list="$( { printf 'header = "Authorization: token '; _spark_op_read df_common DF_FORGEJO_API_TOKEN | tr -d '\r\n' | sed 's/["\\]//g'; printf '"\n'; } \
        | as_user_piped "$(_spark_seam SPARK_CURL_BIN curl)" -K - -sS -m 20 --proto '=https' --tlsv1.2 -X GET "${api}/api/v1/user/keys?limit=200" 2>/dev/null )" || list=""
      if printf '%s' "$list" | as_user_piped jq -e --arg k "${keytype} ${keyb64}" '[.[] | (.key | split(" ") | .[0:2] | join(" "))] | index($k) != null' >/dev/null 2>&1; then
        _ok "the ssh key '${title}' is already registered on ${api}"; return 0
      fi
      _spark_key_collision_advice "$title" "$pub" "$pubf"; return 1 ;;
    401|403) _warn "the forge rejected the token (HTTP ${code}); the key was not registered"; return 1 ;;
    *) _warn "the forge did not accept the key registration (HTTP ${code})"; return 1 ;;
  esac
}

# The ladder. Sets _SPARK_KEYMODE/SPARK_SSH_KEY_FILE when a key on disk is to be used.
ensure_forge_key(){
  local dir keypath pub
  if [[ "$_SPARK_KEYMODE" != none ]]; then _ok "ssh key source: ${_SPARK_KEYMODE}"; return 0; fi
  _spark_hostname
  dir="$(_spark_ssh_dir)"; keypath="${dir}/id_ed25519"
  _SPARK_KEY_PATH="$keypath"
  if as_user test -f "$keypath"; then
    _ok "ssh key present: ${keypath}"
  else
    as_user test -d "$dir" || as_user mkdir -m 0700 -- "$dir" || die "cannot create ${dir}."
    if _spark_op_signed_in && _spark_op_vault && _spark_op_read "df_machine-${_SPARK_HOSTNAME}" id_ed25519 | _spark_write_private "$keypath"; then
      if as_user test -s "$keypath"; then
        # GUARD: spark-key-restore-no-overwrite a restored key lands only where no file was; the public half is written the same way.
        # 2>/dev/null: the item may lack the public half (recomputed from the private key below). || true: it is optional.
        _spark_op_read "df_machine-${_SPARK_HOSTNAME}" id_ed25519.pub | _spark_write_private "${keypath}.pub" >/dev/null 2>&1 || true
        # GUARD-END: spark-key-restore-no-overwrite
        # The fingerprint is derived from the PRIVATE key (-y derives its public half): `ssh-keygen -l` on a private key path reports a
        # neighbouring .pub instead, so an item whose public field belongs to another key would have shown the wrong fingerprint. A
        # public half that disagrees with its private key is dropped here and re-derived by the step below.
        local rfp pfp
        # 2>/dev/null: ssh-keygen complains on an odd or passphrase-protected file; the fingerprint is information, not a gate.
        rfp="$(as_user ssh-keygen -y -f "$keypath" 2>/dev/null | as_user_piped ssh-keygen -l -f - 2>/dev/null | awk '{print $2}')" || rfp=""
        # 2>/dev/null: a missing or odd .pub just leaves nothing to compare.
        pfp="$(as_user ssh-keygen -lf "${keypath}.pub" 2>/dev/null | awk '{print $2}')" || pfp=""
        if [[ -n "$rfp" && -n "$pfp" && "$rfp" != "$pfp" ]]; then
          _warn "the public half stored in the item does not match its private key (${pfp}); using the private key's (${rfp})."
          as_user rm -f -- "${keypath}.pub"
        fi
        # 2>/dev/null: ssh-keygen -y and chmod complain on an odd file; the private key is what the clone needs.
        # || true: deriving the public half and setting its mode are best effort.
        if ! as_user test -s "${keypath}.pub"; then as_user rm -f -- "${keypath}.pub"; as_user ssh-keygen -y -f "$keypath" 2>/dev/null | _spark_write_private "${keypath}.pub" || true; fi
        as_user chmod 644 -- "${keypath}.pub" 2>/dev/null || true
        _ok "restored the machine's ssh key from 1Password (df_machine-${_SPARK_HOSTNAME}) → ${keypath}"
        # A key is restored by hostname alone, so a cloned or renamed machine that shares a name would receive another host's key:
        # show which key this is and where it came from, and at a terminal ask whether to use it.
        _run "restored key ${rfp:-(fingerprint unavailable)}: item df_machine-${_SPARK_HOSTNAME} in vault ${_SPARK_VAULT} (account $(_spark_op_account))"
        if ! _spark_noninteractive; then
          _spark_tty_open
          case "$(_spark_ask 'Use the restored key for this machine? [Y/n]: ')" in
            [Nn]|[Nn][Oo])
              as_user rm -f -- "$keypath" "${keypath}.pub"
              _warn "not using the restored key; a new key will be generated for this machine."
              ;;
          esac
        fi
      else
        as_user rm -f -- "$keypath"
      fi
    fi
    if ! as_user test -s "$keypath"; then
      as_user rm -f -- "$keypath" "${keypath}.pub"
      _run "generating a new ed25519 ssh key for this machine (${keypath})"
      as_user "$(_spark_seam SPARK_SSH_KEYGEN_BIN ssh-keygen)" -q -t ed25519 -N "" -C "df_machine-${_SPARK_HOSTNAME}" -f "$keypath" </dev/null \
        || die "ssh-keygen failed."
      _ok "generated ${keypath}"
    fi
  fi
  # Registration when a token is readable; otherwise the public key and where to paste it. The API lives at https://<forge host>.
  local fhost=""
  case "$REPO_BASE" in
    https://*) fhost="${REPO_BASE#https://}"; fhost="${fhost%%/*}" ;;
    ssh://*)   fhost="${REPO_BASE#ssh://}"; fhost="${fhost#*@}"; fhost="${fhost%%/*}"; fhost="${fhost%%:*}" ;;
  esac
  if [[ -n "$fhost" ]] && _spark_op_signed_in && _spark_op_vault && _spark_op_read df_common DF_FORGEJO_API_TOKEN >/dev/null 2>&1; then
    if _spark_forge_register_key "https://${fhost}" "${keypath}.pub" "df_machine-${_SPARK_HOSTNAME}"; then
      _SPARK_KEY_REGISTERED=1
      # A marker beside the key (the forge it was registered on), so later runs stop printing the paste-me reminder.
      # 2>/dev/null: an existing marker is left alone (the writer refuses to overwrite). || true: the marker is a convenience.
      printf '%s\n' "$REPO_BASE" | _spark_write_private "${keypath}.registered" >/dev/null 2>&1 || true
    fi
  fi
  if (( ! _SPARK_KEY_REGISTERED )) && ! as_user test -s "${keypath}.registered"; then
    # 2>/dev/null: no public half means an empty line in the reminder, not an error.
    pub="$(as_user cat -- "${keypath}.pub" 2>/dev/null)" || pub=""
    _warn "register this public key on your git host (Settings → SSH Keys), title 'df_machine-${_SPARK_HOSTNAME}':"
    printf '     %s\n' "$pub" >&2
  fi
  # GUARD: spark-key-file-checked the key file spark is about to use passes the same checks as an operator-given SPARK_SSH_KEY_FILE (0600, owned, private directory).
  SPARK_SSH_KEY_FILE="$keypath"; _spark_secret_file_check SPARK_SSH_KEY_FILE "$keypath"
  # GUARD-END: spark-key-file-checked
  _SPARK_KEYMODE=file
}

# ---------------------------------------------------------------------------------------
# Transport: ssh first, https with a token as the fallback, anonymous https last (D097).
# ---------------------------------------------------------------------------------------
# Probe a URL with what is on hand; rc 0 reachable with a main branch. 2>/dev/null: the answer is the status, the failure text would name internals.
_spark_probe(){  # _spark_probe <proto> <url>
  local rc=0 errf
  # Runs in the main shell (no $(...)): the private directory, the known_hosts and an agent it may start must be the ones cleanup
  # knows. The probe is quiet about ordinary failures (no answer is the answer); a security refusal inside it (a host-key mismatch, a
  # known_hosts conflict) is still said, because _err writes past the capture.
  _spark_priv_dir
  errf="${_SPARK_PRIV}/probe.err"
  # git's own noise goes to a file; spark's refusals and warnings bypass it (fd 9, see _err), so a die3 in here is never silent.
  _spark_git soft "$1" "$2" ls-remote --exit-code --heads -- "$2" main >/dev/null 2>"$errf" || rc=$?
  # 2>/dev/null: the stderr file may not exist when the probe was refused before git ran; nothing to remove then.
  as_user rm -f -- "$errf" 2>/dev/null
  return $rc
}
# A token into the private directory from 1Password (vault-qualified) or a hidden prompt; sets SPARK_HTTPS_TOKEN_FILE. rc 1 none.
_spark_token_from_op_or_tty(){
  local f tok=""
  _spark_priv_dir
  f="${_SPARK_PRIV}/tok"
  if _spark_op_signed_in && _spark_op_vault; then
    # || true: no token in the vault is not an error; the terminal (below) is the next source.
    _spark_op_read df_common DF_FORGEJO_API_TOKEN | tr -d '\r\n' | _spark_write_private "$f" || true
    if as_user test -s "$f"; then _run "forge token read from 1Password"; else as_user rm -f -- "$f"; fi
  fi
  if ! as_user test -s "$f" && ! _spark_noninteractive; then
    printf '   Forge https token for %s (hidden; Enter for none): ' "$REPO_BASE" >/dev/tty
    IFS= read -rs tok </dev/tty || tok=""
    printf '\n' >/dev/tty
    tok="${tok//[$'\r\n']/}"
    if [[ -n "$tok" ]]; then
      # GUARD: spark-token-grammar a token is one line of plain characters; anything else is refused without being printed (it is written into a shell helper as a literal).
      [[ "$tok" =~ $_SPARK_RE_TOKEN ]] || die3 "the token has characters a token never has; refusing (the value is not printed)."
      # GUARD-END: spark-token-grammar
      printf '%s' "$tok" | _spark_write_private "$f" || die3 "cannot write the token file."
    fi
    tok=""
  fi
  # 2>/dev/null: an empty token file that was never created cannot be removed; either way there is no token.
  as_user test -s "$f" || { as_user rm -f -- "$f" 2>/dev/null; return 1; }
  SPARK_HTTPS_TOKEN_FILE="$f"
  return 0
}
# Decide how the ONE repository is reached. Runs before any directory is created.
resolve_transport(){
  local host owner sshbase url
  [[ -n "$REPO_BASE" ]] || resolve_repo_base
  case "$_SPARK_PROTO" in
    file) _spark_repo_url "$REPO_NAME" >/dev/null || exit 1; _ok "source: local path ${REPO_BASE}"; return 0 ;;
    ssh)  _ok "source: ssh (${REPO_BASE})"; return 0 ;;
  esac
  host="${REPO_BASE#https://}"; owner="${host#*/}"; host="${host%%/*}"
  sshbase="ssh://git@${host%%:*}/${owner}"
  if [[ "$_SPARK_KEYMODE" != none ]] && _spark_probe ssh "${sshbase}/${REPO_NAME}.git"; then
    REPO_BASE="$sshbase"; _SPARK_PROTO=ssh
    _ok "source: ssh (${REPO_BASE}); the key authenticates"
    return 0
  fi
  url="${REPO_BASE}/${REPO_NAME}.git"
  if [[ -n "${SPARK_HTTPS_TOKEN_FILE:-}" ]]; then _ok "source: https with the token in SPARK_HTTPS_TOKEN_FILE"; return 0; fi
  if _spark_probe https "$url"; then _ok "source: https, anonymous (${REPO_BASE})"; return 0; fi
  if _spark_token_from_op_or_tty && _spark_probe https "$url"; then _ok "source: https with a token (${REPO_BASE})"; return 0; fi
  # GUARD: spark-no-credentials a private forge with no key that authenticates and no token is a refusal that names the ways, before any directory is created.
  die3 "cannot reach ${url}: the ssh key does not authenticate there yet (register it, see above), anonymous https was refused, and no token is available (SPARK_HTTPS_TOKEN_FILE, 1Password op://<vault>/df_common/DF_FORGEJO_API_TOKEN, or a terminal to type one)."
  # GUARD-END: spark-no-credentials
}

# Portable without stat(1) (BSD and GNU differ): find's -uid and -perm agree on both.
_spark_owned_by(){  [[ -n "$(find "$1" -maxdepth 0 -uid "$2" -print)" ]]; }                         # _spark_owned_by <path> <uid>
_spark_group_world_writable(){ [[ -n "$(find "$1" -maxdepth 0 \( -perm -020 -o -perm -002 \) -print)" ]]; }

# ---------------------------------------------------------------------------------------
# The install tree: ONE code directory, only when absent, owned by the owner (F06/F26). /opt itself and the Atlas registry are
# never chowned or chmodded here.
# ---------------------------------------------------------------------------------------
ensure_install_tree(){
  local dir want_uid
  if [[ -e "$OPT_ROOT" || -L "$OPT_ROOT" ]]; then
    want_uid="$(_spark_seam SPARK_OPT_ROOT_UID 0)"
    # GUARD: spark-opt-root-owner an install root that is a symlink, not root-owned, or group/world-writable could be swapped under the root-time install -d; refuse it.
    if [[ -L "$OPT_ROOT" || ! -d "$OPT_ROOT" ]] || ! _spark_owned_by "$OPT_ROOT" "$want_uid" || _spark_group_world_writable "$OPT_ROOT"; then
      die "${OPT_ROOT} must be a real directory owned by root (uid ${want_uid}) and not group/world-writable — fix it yourself, then re-run."
    fi
    # GUARD-END: spark-opt-root-owner
  else
    as_root install -d -m 0755 "$OPT_ROOT" || die "could not create ${OPT_ROOT}."
  fi
  dir="${OPT_ROOT}/${REPO_NAME}"
  if [[ -e "$dir" || -L "$dir" ]]; then
    # GUARD: spark-tree-unwritable an existing code directory that is a symlink, not owned by the owner, writable by group/world, or not writable by the owner is reported, never chowned or chmodded (F06, D048).
    if [[ -L "$dir" || ! -d "$dir" ]] || ! _spark_owned_by "$dir" "$OWNER_UID" || _spark_group_world_writable "$dir" || ! as_user test -w "$dir"; then
      die "${dir} must be a real directory owned by ${OWNER}, writable by them and not by group/world — fix it yourself (spark never changes the ownership or mode of an existing tree), then re-run."
    fi
    # GUARD-END: spark-tree-unwritable
    return 0
  fi
  as_root install -d -o "$OWNER" -g "$OWNER_GROUP" -m 0755 "$dir" || die "could not create ${dir}."
}

# ---------------------------------------------------------------------------------------
# The ONE repository: cloned or updated at REF (D077 for a tag: verified like `dotFiles up`).
# ---------------------------------------------------------------------------------------
REF=""            # the ref; empty with REF_MODE=release means "the newest release tag on main"
REF_MODE=branch   # release | branch
_SPARK_TAG=""     # _spark_newest_main_tag's answer
_SPARK_SHA=""     # _spark_verify_release's answer: the commit the verified tag names, resolved ONCE (D079)

clone_repo(){  # clone_repo <ref|main>
  local dest="${OPT_ROOT}/${REPO_NAME}" url proto clone_ref="$1"
  url="$(_spark_repo_url "$REPO_NAME")"
  proto="$(_spark_proto_of "$url")" || exit 1
  # GUARD: spark-tree-notempty a non-empty directory that is not a git checkout is never overwritten or deleted.
  if [[ -n "$(as_user find "$dest" -mindepth 1 -maxdepth 1)" ]]; then
    die "${dest} is not empty and is not a git checkout — move it aside (spark never deletes), then re-run."
  fi
  # GUARD-END: spark-tree-notempty
  _run "cloning ${REPO_NAME} → ${dest} (${clone_ref})"
  _spark_git hard "$proto" "$url" -c advice.detachedHead=false clone -q -b "$clone_ref" -- "$url" "$dest" \
    || die "failed to clone ${url} (ref ${clone_ref}) — check --base, --ref and access."
}

# Release: clone main (or fetch), pick the tag (REF, else the newest on main), verify it, and put the checkout on the verified
# commit; an existing checkout on a branch is refused (convert it once), a dirty one that has to move is refused, nothing is wiped.
prepare_release(){
  local dest="${OPT_ROOT}/${REPO_NAME}" origin proto head cur fresh=0 fetched=1
  if [[ ! -d "${dest}/.git" ]]; then
    # A release tag is not cloned by name: the clone is of origin's main (D005), the tag is verified in the clone and only then checked out.
    local url; url="$(_spark_repo_url "$REPO_NAME")" || exit 1
    # GUARD: spark-release-no-main an origin without a main branch has no release: exit 3 with the reason, before anything is cloned.
    _spark_probe "$_SPARK_PROTO" "$url" || die3 "${REPO_NAME}: the origin has no reachable main branch (D005: releases live on main), so there is no release to install. For a development install use --ref <branch>."
    # GUARD-END: spark-release-no-main
    clone_repo main; fresh=1
    _spark_git_local -C "$dest" checkout -q --detach || die "${REPO_NAME}: could not detach HEAD in the new clone."
  else
    origin="$(_spark_git_local -C "$dest" remote get-url origin)" || die "${REPO_NAME}: the checkout at ${dest} has no origin remote."
    _spark_check_origin "$REPO_NAME" "$dest" "$origin"
    proto="$(_spark_proto_of "$origin")"
    _run "fetching the ${REPO_NAME} releases (${dest})"
    if ! _spark_fetch_release "$REPO_NAME" "$dest" "$proto" "$origin"; then fetched=0; _warn "${REPO_NAME}: update failed — using the release tags already fetched"; fi
  fi
  if [[ -z "$REF" ]]; then
    _spark_newest_main_tag "$dest" || die "${REPO_NAME}: could not list the release tags of ${dest}."
    # GUARD: spark-release-none no release tag on origin's main means there is no release to install: spark never falls back to a branch on its own.
    [[ -n "$_SPARK_TAG" ]] || die3 "${REPO_NAME} has no release tag (vX.Y.Z) on origin's main branch: there is no release to install. For a development install use --ref <branch>."
    # GUARD-END: spark-release-none
    REF="$_SPARK_TAG"
  fi
  _spark_verify_release "$REPO_NAME" "$dest" "$REF"
  if (( fresh )); then _spark_checkout_sha "$REPO_NAME" "$dest" "$_SPARK_SHA"; _ok "${REPO_NAME}: at ${REF}"; return 0; fi
  head="$(_spark_git_local -C "$dest" rev-parse -q --verify HEAD)" || die3 "${REPO_NAME}: the checkout at ${dest} has no commit."
  cur="$(_spark_git_local -C "$dest" symbolic-ref -q --short HEAD)" || cur=""
  if [[ "$head" == "$_SPARK_SHA" ]]; then _ok "${REPO_NAME}: current (${REF})"; return 0; fi
  # GUARD: spark-release-branch a release install runs on a checkout detached at a verified tag, never on a branch: a checkout on any branch (a box first installed by branch) is refused with the one command that converts it.
  if [[ -n "$cur" ]]; then
    die3 "${REPO_NAME}: the checkout at ${dest} is on branch '${cur}', not detached at a release tag — a release install keeps it detached. Convert it once: git -C ${dest} checkout --detach   (then re-run spark; it is moved to ${REF}). Refusing; nothing was changed."
  fi
  # GUARD-END: spark-release-branch
  # GUARD: spark-release-offline offline, a checkout that is not the release is refused: never "current" for a commit nobody could check.
  (( fetched )) || die3 "${REPO_NAME}: cannot reach the origin and the checkout is not at ${REF} — refusing."
  # GUARD-END: spark-release-offline
  # GUARD: spark-release-dirty a checkout that has to move and has uncommitted changes is refused: a move would touch them.
  [[ -z "$(_spark_git_local -C "$dest" status --porcelain)" ]] || die3 "${REPO_NAME}: the checkout is not at ${REF} and its worktree is not clean — refusing to move it. Commit, stash or discard the changes in ${dest}, then re-run; nothing was changed."
  # GUARD-END: spark-release-dirty
  _spark_checkout_sha "$REPO_NAME" "$dest" "$_SPARK_SHA"
  _ok "${REPO_NAME}: now at ${REF}"
}

# Branch install (development only): clone if absent, else fast-forward the repository's branch. A failed update (offline, a
# diverged checkout) is reported and the on-disk checkout is used only when it already is the requested ref.
prepare_branch(){
  local dest="${OPT_ROOT}/${REPO_NAME}" origin proto head target cur localref moved=0 fetched=0
  if [[ ! -d "${dest}/.git" ]]; then clone_repo "$REF"; _ok "${REPO_NAME}: at ${REF} (branch install)"; return 0; fi
  origin="$(_spark_git_local -C "$dest" remote get-url origin)" || die "${REPO_NAME}: the checkout at ${dest} has no origin remote."
  _spark_check_origin "$REPO_NAME" "$dest" "$origin"
  proto="$(_spark_proto_of "$origin")"
  head="$(_spark_git_local -C "$dest" rev-parse -q --verify HEAD)" || die "${REPO_NAME}: the checkout at ${dest} has no commit."
  cur="$(_spark_git_local -C "$dest" symbolic-ref -q --short HEAD)" || cur=""
  # GUARD: spark-branch-foreign a checkout on some other branch is never moved to the requested ref.
  if [[ -n "$cur" && "$cur" != "$REF" ]]; then
    die "${REPO_NAME}: the checkout at ${dest} is on branch '${cur}', not ${REF} — refusing to move it; check out ${REF} yourself or use another directory."
  fi
  # GUARD-END: spark-branch-foreign
  _run "updating ${REPO_NAME} → ${REF} (${dest})"
  if _spark_git soft "$proto" "$origin" -C "$dest" fetch -q origin "$REF"; then fetched=1; fi
  if (( fetched )); then
    target="$(_spark_git_local -C "$dest" rev-parse -q --verify 'FETCH_HEAD^{commit}')" || die "${REPO_NAME}: ${REF} did not resolve to a commit."
    if [[ "$head" != "$target" ]]; then
      if [[ -n "$cur" ]]; then
        _spark_git_local -C "$dest" merge -q --ff-only FETCH_HEAD || die "${REPO_NAME}: ${REF} cannot be fast-forwarded (the checkout diverged) — refusing."
      else
        [[ -z "$(_spark_git_local -C "$dest" status --porcelain)" ]] || die "${REPO_NAME}: the checkout is not at ${REF} and its worktree is not clean — refusing to move it."
        _spark_git_local -C "$dest" checkout -q --detach FETCH_HEAD || die "${REPO_NAME}: could not check out ${REF}."
      fi
      head="$(_spark_git_local -C "$dest" rev-parse -q --verify HEAD)" || die "${REPO_NAME}: no HEAD after the update."
      moved=1
    fi
    # GUARD: spark-not-at-ref the run continues only when HEAD is exactly the requested ref; never report "current" for another commit.
    [[ "$head" == "$target" ]] || die "${REPO_NAME}: the checkout is not at ${REF} (it is ahead of or off it) — refusing."
    # GUARD-END: spark-not-at-ref
    if (( moved )); then _ok "${REPO_NAME}: now at ${REF}"; else _ok "${REPO_NAME}: current"; fi
  else
    if [[ -z "$cur" ]]; then
      localref="$(_spark_git_local -C "$dest" rev-parse -q --verify "refs/tags/${REF}^{commit}")" || localref=""
      [[ -n "$localref" && "$head" == "$localref" ]] || die "${REPO_NAME}: cannot reach the origin and the checkout is not at ${REF} — refusing."
    fi
    _warn "${REPO_NAME}: update failed — continuing with the existing checkout at ${REF}"
  fi
}

# ---------------------------------------------------------------------------------------
# The installer contract: `.spark` at the repository root (install=<argv>, needs=<tools>), else ./install (D097).
# ---------------------------------------------------------------------------------------
_SPARK_INSTALL_CMD=()
_SPARK_NEEDS=""
_SPARK_PASS_MACHINE_NAME=0
_spark_read_contract(){
  local dest="${OPT_ROOT}/${REPO_NAME}" f="${OPT_ROOT}/${REPO_NAME}/.spark" line k v w
  _SPARK_INSTALL_CMD=(); _SPARK_NEEDS=""; _SPARK_PASS_MACHINE_NAME=0
  if [[ ! -f "$f" ]]; then
    [[ -x "${dest}/install" ]] || die "${REPO_NAME}: neither a .spark file nor an executable ./install at ${dest}; nothing to run."
    _SPARK_INSTALL_CMD=(./install); return 0
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%\#*}"
    [[ "$line" == *=* ]] || continue
    k="${line%%=*}"; k="${k//[$'\r\t ']/}"; v="${line#*=}"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    case "$k" in
      install)
        # GUARD: spark-contract-grammar the install command is argv of plain words, relative, inside the repository (no leading dash, no .., no slash-leading path): nothing in it is interpreted by a shell.
        [[ -n "$v" && "$v" =~ ^[A-Za-z0-9._][A-Za-z0-9._/=-]*([[:space:]]+[A-Za-z0-9._=-][A-Za-z0-9._/=,:-]*)*$ && "$v" != *..* ]] || die3 "${REPO_NAME}: .spark install= is not a plain relative command; refusing."
        # GUARD-END: spark-contract-grammar
        read -r -a _SPARK_INSTALL_CMD <<<"$v"
        [[ -e "${dest}/${_SPARK_INSTALL_CMD[0]}" ]] || die3 "${REPO_NAME}: .spark names an installer that is not in the repository (${_SPARK_INSTALL_CMD[0]}); refusing." ;;
      args)
        # The flags this installer understands from spark. An allow-list, like needs=: today only machine-name.
        for w in $v; do
          # GUARD: spark-contract-args-allowlist the flags spark may pass to a repository's installer are an allow-list, not whatever the file says.
          case "$w" in machine-name) _SPARK_PASS_MACHINE_NAME=1 ;; *) die3 "${REPO_NAME}: .spark args= names '${w}', which spark does not pass (allowed: machine-name); refusing." ;; esac
          # GUARD-END: spark-contract-args-allowlist
        done ;;
      needs)
        for w in $v; do
          # GUARD: spark-contract-needs-allowlist the tools a repository may ask spark to install as root are an allow-list, not whatever the file says.
          case "$w" in zsh|jq|git|curl|gnupg|age) ;; *) die3 "${REPO_NAME}: .spark needs= names '${w}', which spark does not install (allowed: zsh jq git curl gnupg age); refusing." ;; esac
          # GUARD-END: spark-contract-needs-allowlist
          _SPARK_NEEDS="${_SPARK_NEEDS:+$_SPARK_NEEDS }$w"
        done ;;
    esac
  done < "$f"
  (( ${#_SPARK_INSTALL_CMD[@]} )) || die3 "${REPO_NAME}: .spark has no install= line; refusing."
}
_spark_ensure_needs(){
  local w missing=""
  for w in $_SPARK_NEEDS; do
    case "$w" in
      age) command -v age >/dev/null 2>&1 || [[ -x "${_SPARK_LOCAL_BIN}/age" ]] || missing="${missing:+$missing }age" ;;
      gnupg) command -v gpg >/dev/null 2>&1 || missing="${missing:+$missing }gnupg" ;;
      *) command -v "$w" >/dev/null 2>&1 || missing="${missing:+$missing }$w" ;;
    esac
  done
  [[ -n "$missing" ]] || return 0
  case "$(_spark_os)" in
    linux) _spark_apt_install $missing || exit 1 ;;
    macos) die "${REPO_NAME} needs ${missing}, which spark does not install on macOS; install it, then re-run." ;;
  esac
}
run_installer(){
  local dest="${OPT_ROOT}/${REPO_NAME}" rc=0
  local -a unattended=()
  # The machine's name, once settled here, goes on to an installer that says it takes it (args=machine-name), so it is not asked twice.
  if (( _SPARK_MACHINE_NAME_SETTLED )); then
    if (( _SPARK_PASS_MACHINE_NAME )); then INSTALL_ARGS+=("--machine-name" "$_SPARK_HOSTNAME")
    else _run "machine name ${_SPARK_HOSTNAME} is used for the ssh key; ${REPO_NAME}'s .spark does not take --machine-name, so its installer decides its own"; fi
  fi
  _run "running the ${REPO_NAME} installer: ${_SPARK_INSTALL_CMD[*]} ${INSTALL_ARGS[*]-}"
  # No terminal (or --non-interactive): tell the installer nobody can answer (Trove's installer honours TROVE_NONINTERACTIVE).
  if _spark_noninteractive; then unattended=(TROVE_NONINTERACTIVE=1); fi
  # From another account (root), `sudo -u` resets the environment: a 1Password session or service-account token does not reach the
  # installer. The only route that could carry it is a pipe, which would take the installer's terminal, so say so instead of
  # dropping it silently. (The token is never put on argv.)
  if [[ "$(id -un)" != "$OWNER" ]] && { [[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" || -n "$_SPARK_OP_SESSION_NAME" ]] || compgen -e | grep -q '^OP_SESSION_'; }; then
    _warn "the 1Password credential held here does not reach the installer (spark runs it through sudo -u ${OWNER}, which resets the environment); run spark as the owner to keep it, or sign in when the installer asks."
  fi
  ( cd "$dest" && as_user env ${unattended[@]+"${unattended[@]}"} "${_SPARK_INSTALL_CMD[@]}" ${INSTALL_ARGS[@]+"${INSTALL_ARGS[@]}"} ) || rc=$?
  # GUARD: spark-install-fatal the completion line is printed only after the installer returned 0.
  if (( rc != 0 )); then die "${REPO_NAME} installer failed (exit ${rc}) — see the error above."; fi
  # GUARD-END: spark-install-fatal
}

# Release verification for the ONE repository (D077, D079; the same checks `dotFiles up` makes).
_spark_verify_release(){
  local name="$1" dest="$2" tag="$3" sha have
  _SPARK_SHA=""
  # GUARD: spark-release-tag-grammar a release tag is vX.Y.Z and nothing else, so no ref, option or path can ride in as one.
  [[ "$tag" =~ $_SPARK_RE_TAG ]] || die3 "${name}: not a release tag (vX.Y.Z); refusing."
  # GUARD-END: spark-release-tag-grammar
  # GUARD: spark-release-tag-missing the release tag must exist in the checkout (fetched from origin), or there is nothing to verify and nothing to install.
  sha="$(_spark_git_local -C "$dest" rev-parse -q --verify "refs/tags/${tag}^{commit}")" \
    || die3 "${name}: there is no release tag ${tag} in ${dest} (fetched from its origin); refusing."
  # GUARD-END: spark-release-tag-missing
  # GUARD: spark-release-on-main a release tag must be reachable from origin's main branch (D005): a tag on a side branch is unreleased code, and its installer is never run.
  _spark_git_local -C "$dest" merge-base --is-ancestor "$sha" refs/remotes/origin/main \
    || die3 "${name}: ${tag} is not on origin's main branch (D005), so it is not a release; refusing to run its installer."
  # GUARD-END: spark-release-on-main
  have="$(_spark_git_local -C "$dest" show "${sha}:VERSION")" || die3 "${name}: ${tag} carries no VERSION file; refusing."
  have="${have//[$'\r\n\t ']/}"
  # GUARD: spark-release-version the VERSION file at the tag must name the tag: a retagged or mislabelled release is refused (the file's content is not printed).
  [[ "$have" == "${tag#v}" ]] || die3 "${name}: the VERSION file at ${tag} does not name ${tag}; refusing a tag whose version does not match."
  # GUARD-END: spark-release-version
  _SPARK_SHA="$sha"
}

_spark_checkout_sha(){
  local name="$1" dest="$2" sha="$3" now
  [[ "$sha" =~ $_SPARK_RE_SHA ]] || die3 "${name}: no verified commit to check out; refusing."
  _spark_git_local -C "$dest" checkout -q --detach "$sha" -- || die "${name}: could not check out the verified commit ${sha:0:12}."
  # GUARD: spark-checkout-verified HEAD must be exactly the commit that was verified once the checkout is done: whatever else it landed on is code nobody checked, and its installer is never run.
  now="$(_spark_git_local -C "$dest" rev-parse -q --verify HEAD)" || now=""
  [[ "$now" == "$sha" ]] || die3 "${name}: after the checkout HEAD is not the verified commit ${sha:0:12}; refusing."
  # GUARD-END: spark-checkout-verified
}

_spark_newest_main_tag(){
  local dest="$1" out t rest ma mi pa bma=-1 bmi=-1 bpa=-1
  _SPARK_TAG=""
  out="$(_spark_git_local -C "$dest" tag --list 'v[0-9]*.[0-9]*.[0-9]*' --merged refs/remotes/origin/main)" || return 1
  while IFS= read -r t; do
    [[ "$t" =~ $_SPARK_RE_TAG ]] || continue
    rest="${t#v}"; ma="${rest%%.*}"; rest="${rest#*.}"; mi="${rest%%.*}"; pa="${rest#*.}"
    (( ${#ma} <= 9 && ${#mi} <= 9 && ${#pa} <= 9 )) || continue
    ma=$((10#$ma)); mi=$((10#$mi)); pa=$((10#$pa))
    if (( ma > bma || (ma == bma && (mi > bmi || (mi == bmi && pa > bpa))) )); then
      bma=$ma; bmi=$mi; bpa=$pa; _SPARK_TAG="$t"
    fi
  done <<EOF_TAGS
${out}
EOF_TAGS
  return 0
}

_spark_fetch_release(){
  local name="$1" dest="$2" proto="$3" origin="$4" out rc=0
  out="$(_spark_git soft "$proto" "$origin" -C "$dest" fetch --no-tags origin '+refs/heads/main:refs/remotes/origin/main' 'refs/tags/*:refs/tags/*' 2>&1)" || rc=$?
  if (( rc != 0 )); then
    # GUARD: spark-release-moved-tag a release tag that differs from origin's (a moved tag) is refused, never overwritten and never retried around.
    case "$out" in
      *clobber*|*'[rejected]'*) die3 "${name}: a release tag differs from origin's (a moved tag); refusing." ;;
    esac
    # GUARD-END: spark-release-moved-tag
    # GUARD: spark-fetch-no-main an origin that has lost (or never had) its main branch is not "unreachable": there are no releases to follow, and continuing on the tags already fetched would hide it (exit 3).
    case "$out" in
      *"find remote ref"*) die3 "${name}: origin has no main branch (D005: releases live on main), so there is no release to follow; refusing. For a development or UAT install set SPARK_REF to a branch." ;;
    esac
    # GUARD-END: spark-fetch-no-main
    printf '%s\n' "$out" >&2
    return 1
  fi
  return 0
}

validate_ref(){
  if [[ -z "${SPARK_REF:-}" ]]; then
    REF=""
    REF_MODE=release
  else
    REF="$SPARK_REF"
    # GUARD: spark-ref-invalid a ref that could be read as a git option or a path escape is refused before any step.
    if ! [[ "$REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || [[ "$REF" == *..* ]]; then
      die "--ref / SPARK_REF '${REF}' is not a plain branch or tag name."
    fi
    # GUARD-END: spark-ref-invalid
    if [[ "$REF" =~ $_SPARK_RE_TAG ]]; then REF_MODE=release; else REF_MODE=branch; fi
  fi
  if [[ "$REF_MODE" == release ]]; then
    _ok "release install: ${REPO_NAME} ${REF:-at the newest release tag on its main} (verified: on origin's main, VERSION names the tag)"
  else
    _warn "branch install (--ref ${REF}): nothing is verified. Development/UAT only; a release install leaves --ref unset or names a tag vX.Y.Z."
  fi
}

_spark_usage(){
  printf '%s\n' \
    "usage: bash spark.sh [--repo <name>] [--base <url>] [--ref <ref>] [--no-op] [--op-vault <vault>] [--plan] [installer arguments]" \
    "  e.g. bash spark.sh --base https://forge.example/homelab --answers ~/answers.json --skip-interview" \
    "What it does: git curl zsh jq → the 1Password CLI (optional, default yes, from 1Password) → the forge ssh key (find, restore," \
    "from 1Password, or generate and register) → clone ONE repository (default dotFiles) → run its installer (.spark, else ./install)." \
    "environment twins: SPARK_REPO SPARK_REPO_BASE SPARK_REF SPARK_NO_OP SPARK_OP_VAULT; SPARK_PRIMARY_USER (required as root)," \
    "SPARK_NONINTERACTIVE=1; ssh: SPARK_SSH_HOST_FPR SPARK_SSH_KEY_FILE SPARK_SSH_KEY_OP_REF; https: SPARK_HTTPS_TOKEN_FILE." \
    "Run as your normal user; the header of spark.sh documents the contract."
}

plan_run(){  # --plan: say what spark would do; change nothing
  local missing trust want
  _bot "spark --plan — nothing is changed"
  missing="$(_spark_missing)"
  if [[ -n "$missing" ]]; then _run "would install prerequisites: ${missing}"; else _ok "prerequisites present (${_SPARK_TOOLS})"; fi
  if _spark_op_bin; then _ok "1Password CLI present (${_SPARK_OP_BIN})"
  elif (( ARG_NO_OP )); then _run "would not install the 1Password CLI (--no-op)"
  else _run "would install the 1Password CLI ${_SPARK_OP_VERSION} from 1Password (default yes; --no-op opts out) and sign in on the terminal"; fi
  if [[ "$_SPARK_KEYMODE" != none ]]; then _ok "ssh key source: ${_SPARK_KEYMODE}"
  else _run "would ask for this machine's name (default: ${ARG_MACHINE_NAME:-${DF_HOSTNAME:-$(hostname -s 2>/dev/null)}}; --machine-name sets it), then use ~/.ssh/id_ed25519, else restore it from 1Password (df_machine-<name>), else generate it, and register it on the forge when a token is readable"; fi
  if [[ "$REF_MODE" == release ]]; then want="${REF:-the newest release tag on its main}"; else want="branch ${REF}"; fi
  if [[ -d "${OPT_ROOT}/${REPO_NAME}/.git" ]]; then _run "would update ${REPO_NAME} at ${OPT_ROOT}/${REPO_NAME} to ${want}"
  else _run "would create ${OPT_ROOT}/${REPO_NAME} (owner ${OWNER}) and clone ${REPO_NAME} at ${want} from ${REPO_BASE:-the base found at run time}"; fi
  if [[ "$_SPARK_PROTO" == ssh ]]; then
    trust="the known_hosts of ${OWNER} only"
    if [[ -n "${SPARK_SSH_HOST_FPR:-}" ]]; then trust="the pin SPARK_SSH_HOST_FPR"; fi
    _run "would clone over ssh (host key trusted through ${trust})"
  elif [[ "$_SPARK_PROTO" == https ]]; then
    _run "would try ssh first (when a key and a trusted host key exist), then https (token from SPARK_HTTPS_TOKEN_FILE, 1Password or a prompt, else anonymous)"
  fi
  _run "would run the ${REPO_NAME} installer (.spark install=, else ./install) with: ${INSTALL_ARGS[*]-}"
}

main(){
  case "${1:-}" in -h|--help|help) _spark_usage; return 0 ;; esac
  # fd 9: the operator's stderr, kept for _warn/_err while a command's stderr is captured.
  exec 9>&2
  # Group-writable clones would break D048 (Ubuntu user private groups give 002).
  umask 022
  trap _spark_cleanup EXIT
  trap '_spark_on_signal 130' INT
  trap '_spark_on_signal 143' TERM
  trap '_spark_on_signal 129' HUP
  # The tiers find each other under /opt (Beskar's installer targets /opt/trove, Atlas defaults to /opt): any other install root
  # is refused outside the hermetic test seam.
  OPT_ROOT="$(_spark_seam SPARK_OPT_ROOT /opt)"
  # GUARD: spark-opt-root-fixed a non-default SPARK_OPT_ROOT breaks how the tiers find each other; refuse it (least surprise).
  if [[ -n "${SPARK_OPT_ROOT:-}" && "${SPARK_OPT_ROOT}" != "/opt" && "$OPT_ROOT" == "/opt" ]]; then
    die "SPARK_OPT_ROOT '${SPARK_OPT_ROOT}' is not supported: the tiers resolve /opt (leave it unset)."
  fi
  # GUARD-END: spark-opt-root-fixed
  case "$OPT_ROOT" in /?*) ;; *) die "SPARK_OPT_ROOT must be an absolute path." ;; esac
  _SPARK_LOCAL_BIN="$(_spark_seam SPARK_LOCAL_BIN /usr/local/bin)"
  resolve_owner
  check_args "$@"
  validate_ref
  validate_explicit_base
  validate_ssh_settings
  if (( ! ARG_PLAN )); then check_sudo; fi
  if (( ARG_PLAN )); then plan_run; return 0; fi
  _bot "spark → ${OPT_ROOT}/${REPO_NAME} (as ${OWNER})"
  ensure_prereqs
  ensure_op
  _spark_forge_pin_from_vault
  # An existing checkout updates from its own origin (offline, that is a WARN and the checkout at the ref is used): the base and the
  # transport ladder are only for a clone.
  if [[ ! -d "${OPT_ROOT}/${REPO_NAME}/.git" ]]; then
    [[ -n "$REPO_BASE" ]] || resolve_repo_base
    ensure_forge_key
    resolve_transport
  else
    ensure_forge_key
  fi
  ensure_install_tree
  if [[ "$REF_MODE" == release ]]; then prepare_release; else prepare_branch; fi
  # The clone is done: the pinned host key is kept for the installer (its ssh calls are strict about the same key), then the
  # private agent, the askpass helper, the token and the private known_hosts go.
  _spark_hostkey_persist
  _spark_cleanup
  _spark_read_contract
  _spark_ensure_needs
  run_installer
  _bot "spark: ${REPO_NAME} installed."
}

# Run main when executed (bash spark.sh) or piped (curl | bash: BASH_SOURCE is empty there);
# do nothing when sourced, so the test suite can call the functions.
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
