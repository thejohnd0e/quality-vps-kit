# shellcheck shell=bash
# Common helpers for qvk: environment, exit codes, logging, temp files, cleanup.
# Sourced by ./qvk; never executed directly.

# shellcheck disable=SC2034  # constants are used by other modules
{
  QVK_EXIT_OK=0
  QVK_EXIT_USAGE=1        # bad flags/values, option not implemented in this version
  QVK_EXIT_ENV=2          # not root for `run`, unsupported platform, missing required tool
  QVK_EXIT_INTERNAL=3     # tester bug / unexpected internal failure
  QVK_EXIT_INTERRUPTED=130
}

QVK_TMPDIR=""
QVK_USER_LOCALE=""

# Capture the user's locale (for --lang autodetection) and then force a
# predictable environment for parsing command output.
qvk_init_env() {
  QVK_USER_LOCALE="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
  export LC_ALL=C
  umask 077
}

qvk_log() { printf 'qvk: %s\n' "$*" >&2; }

# qvk_die <exit_code> <message...>
qvk_die() {
  local code=$1
  shift
  qvk_log "$*"
  exit "$code"
}

qvk_tmpdir() {
  if [[ -z $QVK_TMPDIR ]]; then
    QVK_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/qvk.XXXXXX") \
      || qvk_die "$QVK_EXIT_INTERNAL" "cannot create temporary directory"
  fi
  printf '%s' "$QVK_TMPDIR"
}

qvk_cleanup() {
  if [[ -n $QVK_TMPDIR && -d $QVK_TMPDIR ]]; then
    rm -rf -- "$QVK_TMPDIR"
  fi
  QVK_TMPDIR=""
}

qvk_on_signal() {
  local sig=$1
  trap - EXIT INT TERM
  qvk_cleanup
  qvk_log "interrupted ($sig), cleaned up"
  case $sig in
    TERM) exit 143 ;;
    *) exit "$QVK_EXIT_INTERRUPTED" ;;
  esac
}

qvk_install_traps() {
  trap qvk_cleanup EXIT
  trap 'qvk_on_signal INT' INT
  trap 'qvk_on_signal TERM' TERM
}

# --- Terminal output -------------------------------------------------------

QVK_COLOR=0

# Colors only for a TTY, honoring NO_COLOR (https://no-color.org) and TERM=dumb.
qvk_color_init() {
  if [[ -t 1 && -z ${NO_COLOR:-} && ${TERM:-} != dumb ]]; then
    QVK_COLOR=1
  else
    QVK_COLOR=0
  fi
}

# qvk_paint <green|yellow|red|bold> <text>
qvk_paint() {
  local code
  if ((QVK_COLOR == 0)); then
    printf '%s' "$2"
    return
  fi
  case $1 in
    green) code=32 ;;
    yellow) code=33 ;;
    red) code=31 ;;
    bold) code=1 ;;
    *) code=0 ;;
  esac
  printf '\033[%sm%s\033[0m' "$code" "$2"
}

qvk_color_verdict() {
  local label
  label=$(msg "verdict.$1")
  case $1 in
    suitable) qvk_paint green "$label" ;;
    unsuitable) qvk_paint red "$label" ;;
    *) qvk_paint yellow "$label" ;;
  esac
}

# Display width of a UTF-8 string under LC_ALL=C (continuation bytes ignored).
qvk_strwidth() {
  local s=${1//[$'\x80'-$'\xbf']/}
  printf '%s' "${#s}"
}

# qvk_pad <text> <width> — left-align text to a display width.
qvk_pad() {
  local w
  w=$(qvk_strwidth "$1")
  printf '%s' "$1"
  if ((w < $2)); then printf '%*s' $(($2 - w)) ''; fi
}

qvk_now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

qvk_new_run_id() {
  local id=""
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    read -r id </proc/sys/kernel/random/uuid || id=""
  fi
  if [[ -z $id ]]; then
    id="$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM$RANDOM"
  fi
  printf '%s' "$id"
}

qvk_have() { command -v "$1" >/dev/null 2>&1; }

# Atomically write stdin to a file with owner-only permissions.
qvk_write_file() {
  local dest=$1 dir tmp
  dir=$(dirname -- "$dest")
  [[ -d $dir ]] || qvk_die "$QVK_EXIT_USAGE" "output directory does not exist: $dir"
  tmp=$(mktemp "$dest.XXXXXX") || qvk_die "$QVK_EXIT_ENV" "cannot write to $dir"
  if ! cat >"$tmp"; then
    rm -f -- "$tmp"
    qvk_die "$QVK_EXIT_ENV" "failed to write $dest"
  fi
  chmod 600 -- "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$dest" || {
    rm -f -- "$tmp"
    qvk_die "$QVK_EXIT_ENV" "failed to write $dest"
  }
}
