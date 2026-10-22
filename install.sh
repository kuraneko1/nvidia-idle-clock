#!/usr/bin/env bash
# nvidia-idle-clock installer.
#
# The installer parses its own options instead of treating argv as GPU names
# (#12), validates the host and the source tree before writing anything (#13,
# #23), backs up files it replaces and restarts instances that already run the
# old code (#22), and undoes its own changes when a later step fails (#13).
set -euo pipefail
# Propagate the ERR trap into functions so rollback also runs for failures
# inside a step helper, not only at the top level.
set -E

# Installer version. Bumped together with the release tag (v0.2.3).
INSTALLER_VERSION="0.2.3"

PROG="$(basename -- "$0")"
SELF_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
DAEMON_SRC="$SELF_DIR/nvidia-idle-clock"
UNIT_SRC="$SELF_DIR/nvidia-idle-clock@.service"

DAEMON_DST="/usr/local/sbin/nvidia-idle-clock"
UNIT_DST="/etc/systemd/system/nvidia-idle-clock@.service"
LEGACY_UNIT="/etc/systemd/system/nvidia-idle-clock.service"
LEGACY_UNIT_NAME="nvidia-idle-clock.service"
# Shared with the daemon and uninstall.sh. Only the keep-clocks marker inside
# it is ever touched here.
STATE_DIR="${STATE_DIR:-/run/nvidia-idle-clock}"
KEEP_CLOCKS_MARKER="$STATE_DIR/keep-clocks"

DRY_RUN=0
FORCE=0
PAYLOAD_CHANGED=0
RESTART_FAILED=0
SYSTEMD_TOUCHED=0
PRE_LEGACY_SNAPSHOT=0
PRE_LEGACY_ENABLED=0
PRE_LEGACY_ACTIVE=0

declare -a GPU_ARGS=()
declare -a GPUS=()
declare -a GPU_INDEXES=()
declare -a CREATED=()
declare -a REPLACED=()
declare -a ENABLED=()
declare -a PRE_ACTIVE=()
declare -a PRE_ENABLED=()

# --- output ---------------------------------------------------------------
# Stable key=value records, so logs stay greppable (see issue #31).
info()  { printf 'level=info %s\n' "$*"; }
warn()  { printf 'level=warn %s\n' "$*" >&2; }
error() { printf 'level=error %s\n' "$*" >&2; }

usage() {
  cat <<EOF
usage: $PROG [OPTIONS] [GPU ...]

Install nvidia-idle-clock: copy the daemon to $DAEMON_DST,
install the systemd template unit and enable one instance per GPU.

A GPU argument is an nvidia-smi index ("0 1") or a GPU UUID ("GPU-<uuid>").
UUIDs are validated and resolved to the matching index because the daemon
addresses GPUs by index. With no GPU argument every detected GPU is used.

options:
  -h, --help       show this help and exit
  -V, --version    show the installer version and the daemon checksum, exit
  -n, --dry-run    validate and print every action without changing anything
                   (does not need root)
      --gpus LIST  comma or space separated GPU list; may be repeated
      --force      only skip the source-tree trust check. By default the
                   checkout must be owned by root or by the user running sudo,
                   must not be world writable and must not be group writable
                   through a shared group, because its files are copied into
                   /usr/local/sbin and run as root.
EOF
}

usage_error() {
  error "msg=\"$1\" hint=\"run '$PROG --help'\""
  printf 'usage: %s [OPTIONS] [GPU ...]\n' "$PROG" >&2
  exit 2
}

die() {
  error "msg=\"$1\""
  exit 1
}

# --- helpers --------------------------------------------------------------
hash_of() {
  local out
  out="$(sha256sum -- "$1")"
  printf '%s' "${out%% *}"
}

unit_name() {
  printf 'nvidia-idle-clock@%s.service' "$1"
}

print_version() {
  printf 'nvidia-idle-clock installer %s\n' "$INSTALLER_VERSION"
  if [ -f "$DAEMON_SRC" ]; then
    printf 'daemon sha256=%s\n' "$(hash_of "$DAEMON_SRC")"
  else
    printf 'daemon sha256=unavailable path=%s\n' "$DAEMON_SRC"
  fi
}

# --- argument parsing (#12) ----------------------------------------------
# Options are matched explicitly: an unknown flag is an error and can never
# become part of a unit name (it used to be enabled as @--help.service).
append_gpu_list() {
  local list="$1" part
  local -a parts=()
  [ -n "${list// /}" ] || usage_error "option --gpus requires a non-empty argument"
  # A comma separated list may also contain spaces; read -a splits both ways.
  read -r -a parts <<<"${list//,/ }" || true
  for part in ${parts[@]+"${parts[@]}"}; do
    if [ -n "$part" ]; then
      GPU_ARGS+=("$part")
    fi
  done
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      -V|--version)
        print_version
        exit 0
        ;;
      -n|--dry-run)
        DRY_RUN=1
        shift
        ;;
      --force)
        FORCE=1
        shift
        ;;
      --gpus)
        [ "$#" -ge 2 ] || usage_error "option --gpus requires an argument"
        append_gpu_list "$2"
        shift 2
        ;;
      --gpus=*)
        append_gpu_list "${1#--gpus=}"
        shift
        ;;
      --)
        shift
        while [ "$#" -gt 0 ]; do
          GPU_ARGS+=("$1")
          shift
        done
        ;;
      -?*)
        usage_error "unknown option: $1"
        ;;
      *)
        GPU_ARGS+=("$1")
        shift
        ;;
    esac
  done
}

# --- preflight (#13) ------------------------------------------------------
require_root() {
  [ "$(id -u)" -eq 0 ] && return 0
  die "root privileges are required; run: sudo ./install.sh"
}

preflight() {
  local cmd missing="" state
  for cmd in nvidia-smi systemctl install sha256sum stat cp cmp date; do
    command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
  done
  if [ -n "$missing" ]; then
    die "required command(s) not found:${missing} (nothing was written)"
  fi

  # is-system-running exits non-zero for "offline"/"unknown" and also when
  # systemd is not PID 1 at all, so the output string is what decides.
  state="$(systemctl is-system-running 2>/dev/null || true)"
  case "$state" in
    running|degraded|starting|initializing|maintenance) ;;
    *)
      die "systemd is not running on this system (state: ${state:-none}); containers and WSL are not supported (nothing was written)"
      ;;
  esac

  [ -f "$DAEMON_SRC" ] || die "missing source file: $DAEMON_SRC"
  [ -f "$UNIT_SRC" ] || die "missing source file: $UNIT_SRC"

  # The unit starts the daemon with systemd's default PATH and the script
  # falls back to /usr/bin/nvidia-smi. A driver outside both would only show
  # up later as a restart loop, so warn before installing.
  case "$(command -v nvidia-smi)" in
    /usr/local/sbin/*|/usr/local/bin/*|/usr/sbin/*|/usr/bin/*|/sbin/*|/bin/*) ;;
    *)
      warn "msg=\"nvidia-smi is outside the systemd service PATH\" path=\"$(command -v nvidia-smi)\" hint=\"the unit would not find the driver\""
      ;;
  esac
}

# --- GPU argument validation (#12) ---------------------------------------
is_index_token() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

is_gpu_uuid_token() {
  local rest="$1"
  case "$rest" in
    GPU-*) rest="${rest#GPU-}" ;;
    *) return 1 ;;
  esac
  # GPU-<hex digits in 4-8-4-4-12 groups>; be lenient about the grouping.
  [ "${#rest}" -ge 8 ] || return 1
  case "$rest" in
    *[!0-9a-fA-F-]*) return 1 ;;
  esac
  return 0
}

is_mig_token() {
  local rest="$1"
  case "$rest" in
    MIG-*) rest="${rest#MIG-}" ;;
    *) return 1 ;;
  esac
  [ "${#rest}" -ge 8 ] || return 1
  case "$rest" in
    *[!0-9A-Za-z/_-]*) return 1 ;;
  esac
  return 0
}

in_list() {
  local needle="$1" item
  shift
  for item in "$@"; do
    if [ "$item" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

index_for_uuid() {
  local want="$1" idx uuid
  while IFS=, read -r idx uuid; do
    idx="${idx//[[:space:]]/}"
    uuid="${uuid//[[:space:]]/}"
    [ -n "$uuid" ] || continue
    if [ "$uuid" = "$want" ]; then
      printf '%s' "$idx"
      return 0
    fi
  done < <(nvidia-smi --query-gpu=index,uuid --format=csv,noheader 2>/dev/null || true)
  return 1
}

# MIG identifiers cannot be handed to the daemon (it takes an index), so map
# the MIG UUID to the index of the GPU it belongs to using "nvidia-smi -L".
index_for_mig() {
  local want="$1" line idx=""
  while IFS= read -r line; do
    case "$line" in
      "GPU "[0-9]*:*)
        idx="${line#GPU }"
        idx="${idx%%:*}"
        ;;
    esac
    case "$line" in
      *"$want"*)
        if [ -n "$idx" ]; then
          printf '%s' "$idx"
          return 0
        fi
        ;;
    esac
  done < <(nvidia-smi -L 2>/dev/null || true)
  return 1
}

load_gpu_indexes() {
  local line
  GPU_INDEXES=()
  while IFS= read -r line; do
    line="${line//[[:space:]]/}"
    [ -n "$line" ] || continue
    case "$line" in
      *[!0-9]*) continue ;;
    esac
    GPU_INDEXES+=("$line")
  done < <(nvidia-smi --query-gpu=index --format=csv,noheader,nounits 2>/dev/null || true)
}

resolve_gpus() {
  local token resolved seen
  seen=" "

  if [ "${#GPU_ARGS[@]}" -eq 0 ]; then
    if [ "${#GPU_INDEXES[@]}" -eq 0 ]; then
      die "no GPU detected (nvidia-smi --query-gpu=index returned nothing); pass an index explicitly"
    fi
    for token in ${GPU_INDEXES[@]+"${GPU_INDEXES[@]}"}; do
      GPUS+=("$token")
    done
    return 0
  fi

  for token in ${GPU_ARGS[@]+"${GPU_ARGS[@]}"}; do
    if is_index_token "$token"; then
      if ! in_list "$token" ${GPU_INDEXES[@]+"${GPU_INDEXES[@]}"}; then
        usage_error "GPU index $token does not exist (detected: ${GPU_INDEXES[*]:-none})"
      fi
      resolved="$token"
    elif is_gpu_uuid_token "$token"; then
      if ! resolved="$(index_for_uuid "$token")"; then
        usage_error "GPU UUID $token was not found by nvidia-smi --query-gpu=uuid"
      fi
      info "msg=\"resolved GPU UUID to index\" uuid=\"$token\" gpu=$resolved"
    elif is_mig_token "$token"; then
      if ! resolved="$(index_for_mig "$token")"; then
        usage_error "MIG identifier $token was not found by nvidia-smi -L; pass the index of the parent GPU instead"
      fi
      info "msg=\"resolved MIG identifier to parent GPU index\" mig=\"$token\" gpu=$resolved note=\"clock locks apply to the whole GPU\""
    else
      usage_error "invalid GPU argument: $token"
    fi

    case "$seen" in
      *" $resolved "*)
        warn "msg=\"duplicate GPU ignored\" gpu=$resolved"
        ;;
      *)
        seen="$seen$resolved "
        GPUS+=("$resolved")
        ;;
    esac
  done

  [ "${#GPUS[@]}" -gt 0 ] || die "no GPU selected"
}

# --- source tree trust check (#23) ----------------------------------------
# The files are copied into /usr/local/sbin and run as root, so a checkout
# that another user can modify is refused unless --force is given.
untrusted() {
  local path="$1" reason="$2"
  if [ "$FORCE" -eq 1 ]; then
    warn "msg=\"source tree check overridden by --force\" path=\"$path\" reason=\"$reason\""
    return 0
  fi
  error "msg=\"refusing to install from an untrusted source tree\" path=\"$path\" reason=\"$reason\" hint=\"chmod go-w the checkout, or clone it as the user running sudo; --force overrides this check (nothing was written)\""
  exit 1
}

check_owned_path() {
  local path="$1" uid grp mode perm owner_uid primary
  owner_uid="${SUDO_UID:-$(id -u)}"
  primary="$(id -gn "$owner_uid" 2>/dev/null || id -gn)"
  uid="$(stat -c %u -- "$path")"
  grp="$(stat -c %G -- "$path")"
  mode="$(stat -c %a -- "$path")"
  perm=$((0$mode))

  if [ "$uid" -ne 0 ] && [ "$uid" -ne "$owner_uid" ]; then
    untrusted "$path" "owned by uid $uid, expected root or $owner_uid"
  fi
  if [ $((perm & 002)) -ne 0 ]; then
    untrusted "$path" "writable by every user (mode 0$mode)"
  fi
  # Group writable is only accepted for the owner's own (usually private)
  # group; a shared group could let another user swap the payload.
  if [ $((perm & 020)) -ne 0 ] && [ "$grp" != "$primary" ]; then
    untrusted "$path" "group writable through the shared group '$grp' (mode 0$mode)"
  fi
}

check_ancestors() {
  local dir="$1" parent perm
  while :; do
    parent="$(dirname -- "$dir")"
    [ "$parent" = "$dir" ] && break
    perm=$((0$(stat -c %a -- "$parent")))
    # A sticky world-writable directory (/tmp) cannot be used to replace an
    # entry owned by somebody else, so it is fine.
    if [ $((perm & 002)) -ne 0 ] && [ $((perm & 01000)) -eq 0 ]; then
      untrusted "$parent" "parent directory is writable by every user and not sticky (mode 0$(stat -c %a -- "$parent"))"
    fi
    dir="$parent"
  done
}

check_source_tree() {
  local file
  for file in "$DAEMON_SRC" "$UNIT_SRC"; do
    if [ -L "$file" ] || [ ! -f "$file" ]; then
      die "source file is not a regular file: $file"
    fi
    check_owned_path "$file"
  done
  if [ -L "$SELF_DIR" ] || [ ! -d "$SELF_DIR" ]; then
    die "source directory is not a regular directory: $SELF_DIR"
  fi
  check_owned_path "$SELF_DIR"
  check_ancestors "$SELF_DIR"
}

# --- rollback (#13, #46) --------------------------------------------------
# Only undo the unit changes this run actually made: a unit that was already
# enabled before the run must stay enabled, and one that was already running
# must be left running. Otherwise a failed ./install.sh on one GPU would stop
# the healthy instance of another GPU.
rollback() {
  local rc=$?
  local unit entry dst backup was_enabled was_active restore_failed=0
  trap - ERR INT TERM
  set +e
  error "msg=\"install failed, rolling back\" rc=$rc"

  for unit in ${ENABLED[@]+"${ENABLED[@]}"}; do
    was_enabled=0
    was_active=0
    if in_list "$unit" ${PRE_ENABLED[@]+"${PRE_ENABLED[@]}"}; then
      was_enabled=1
    fi
    if in_list "$unit" ${PRE_ACTIVE[@]+"${PRE_ACTIVE[@]}"}; then
      was_active=1
    fi

    if [ "$was_enabled" -eq 1 ] && [ "$was_active" -eq 1 ]; then
      warn "msg=\"left unit alone: it was already enabled and running before this run\" unit=\"$unit\""
      continue
    fi

    if [ "$was_enabled" -eq 1 ]; then
      # Started by this run but already enabled: stop it, keep it enabled.
      if systemctl stop "$unit" >/dev/null 2>&1; then
        warn "msg=\"stopped unit, left it enabled as before\" unit=\"$unit\""
      else
        error "msg=\"could not stop unit\" unit=\"$unit\" hint=\"systemctl stop $unit\""
      fi
      continue
    fi

    if [ "$was_active" -eq 1 ]; then
      # Enabled by this run but already running: undo the enable, do not stop.
      if systemctl disable "$unit" >/dev/null 2>&1; then
        warn "msg=\"disabled unit, left the running instance alone\" unit=\"$unit\""
      else
        error "msg=\"could not disable unit\" unit=\"$unit\" hint=\"systemctl disable $unit\""
      fi
      continue
    fi

    if systemctl disable --now "$unit" >/dev/null 2>&1; then
      warn "msg=\"rolled back unit\" unit=\"$unit\""
    else
      error "msg=\"could not disable unit\" unit=\"$unit\" hint=\"systemctl disable --now $unit\""
    fi
  done

  for entry in ${REPLACED[@]+"${REPLACED[@]}"}; do
    dst="${entry%%$'\t'*}"
    backup="${entry#*$'\t'}"
    if cp -p -- "$backup" "$dst"; then
      rm -f -- "$backup"
      warn "msg=\"restored previous file\" path=\"$dst\""
    else
      error "msg=\"could not restore previous file\" path=\"$dst\" backup=\"$backup\""
    fi
  done

  for dst in ${CREATED[@]+"${CREATED[@]}"}; do
    rm -f -- "$dst"
    warn "msg=\"removed newly created file\" path=\"$dst\""
  done

  if [ "$SYSTEMD_TOUCHED" -eq 1 ]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed 'nvidia-idle-clock@*' >/dev/null 2>&1 || true
  fi

  # The legacy unit was stopped and disabled by remove_legacy_unit(); its file
  # is back in place, so restore the service state as well. Otherwise a failed
  # install would leave a previously working installation inactive.
  if [ "$PRE_LEGACY_SNAPSHOT" -eq 1 ]; then
    if [ "$PRE_LEGACY_ENABLED" -eq 1 ]; then
      if systemctl enable "$LEGACY_UNIT_NAME" >/dev/null 2>&1; then
        warn "msg=\"re-enabled the legacy unit\" unit=\"$LEGACY_UNIT_NAME\""
      else
        error "msg=\"could not re-enable the legacy unit\" unit=\"$LEGACY_UNIT_NAME\" hint=\"systemctl enable $LEGACY_UNIT_NAME\""
      fi
    fi
    if [ "$PRE_LEGACY_ACTIVE" -eq 1 ]; then
      if systemctl start "$LEGACY_UNIT_NAME" >/dev/null 2>&1; then
        warn "msg=\"restarted the legacy unit\" unit=\"$LEGACY_UNIT_NAME\""
      else
        error "msg=\"could not restart the legacy unit\" unit=\"$LEGACY_UNIT_NAME\" hint=\"systemctl start $LEGACY_UNIT_NAME\""
      fi
    fi
  fi

  # Do not claim the previous state was restored unless every snapshotted
  # unit is really back in its old enabled/active state.
  for unit in ${PRE_ENABLED[@]+"${PRE_ENABLED[@]}"}; do
    if ! systemctl is-enabled --quiet "$unit" 2>/dev/null; then
      error "msg=\"could not restore the enabled state\" unit=\"$unit\" hint=\"systemctl enable $unit\""
      restore_failed=1
    fi
  done
  for unit in ${PRE_ACTIVE[@]+"${PRE_ACTIVE[@]}"}; do
    if ! systemctl is-active --quiet "$unit" 2>/dev/null; then
      error "msg=\"could not restore the active state\" unit=\"$unit\" hint=\"systemctl start $unit\""
      restore_failed=1
    fi
  done
  if [ "$PRE_LEGACY_SNAPSHOT" -eq 1 ] && [ "$PRE_LEGACY_ENABLED" -eq 1 ] \
    && ! systemctl is-enabled --quiet "$LEGACY_UNIT_NAME" 2>/dev/null; then
    error "msg=\"could not restore the enabled state\" unit=\"$LEGACY_UNIT_NAME\" hint=\"systemctl enable $LEGACY_UNIT_NAME\""
    restore_failed=1
  fi
  if [ "$PRE_LEGACY_SNAPSHOT" -eq 1 ] && [ "$PRE_LEGACY_ACTIVE" -eq 1 ] \
    && ! systemctl is-active --quiet "$LEGACY_UNIT_NAME" 2>/dev/null; then
    error "msg=\"could not restore the active state\" unit=\"$LEGACY_UNIT_NAME\" hint=\"systemctl start $LEGACY_UNIT_NAME\""
    restore_failed=1
  fi

  if [ "$restore_failed" -ne 0 ]; then
    error "msg=\"rollback could not restore the previous state\" hint=\"inspect the units named above with systemctl status\""
    exit 1
  fi
  error "msg=\"rollback finished: the previous state was restored, nothing was installed\""
  exit "$rc"
}

# --- install steps --------------------------------------------------------
stage_file() {
  local src="$1" dst="$2" mode="$3" backup
  if [ -e "$dst" ] && [ ! -f "$dst" ]; then
    die "destination exists and is not a regular file: $dst"
  fi

  if [ -f "$dst" ] && cmp -s -- "$src" "$dst"; then
    info "msg=\"unchanged\" dst=\"$dst\""
    if [ "$DRY_RUN" -eq 1 ]; then
      info "msg=\"would skip install\" dst=\"$dst\""
    fi
    return 0
  fi

  if [ -f "$dst" ]; then
    # Never silently drop a local modification: keep a timestamped copy.
    backup="$dst.bak.$(date +%Y%m%dT%H%M%S)"
    if [ -e "$backup" ]; then
      # Two installs within the same second must not overwrite each other.
      backup="$backup.$$"
    fi
    PAYLOAD_CHANGED=1
    if [ "$DRY_RUN" -eq 1 ]; then
      info "msg=\"would back up existing file\" dst=\"$dst\" backup=\"$backup\""
    else
      cp -p -- "$dst" "$backup"
      REPLACED+=("$dst"$'\t'"$backup")
      info "msg=\"backed up existing file\" backup=\"$backup\""
    fi
  else
    PAYLOAD_CHANGED=1
    if [ "$DRY_RUN" -eq 1 ]; then
      info "msg=\"would create file\" dst=\"$dst\""
    else
      CREATED+=("$dst")
    fi
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "msg=\"would install\" src=\"$src\" dst=\"$dst\" mode=\"$mode\" owner=\"root:root\""
  else
    install -m "$mode" --owner=root --group=root -- "$src" "$dst"
    info "msg=\"installed\" src=\"$src\" dst=\"$dst\" mode=\"$mode\" owner=\"root:root\""
  fi
}

remove_legacy_unit() {
  local load_state backup
  [ -e "$LEGACY_UNIT" ] || return 0

  if [ "$DRY_RUN" -eq 1 ]; then
    info "msg=\"would disable and remove legacy non-template unit\" path=\"$LEGACY_UNIT\""
    return 0
  fi

  load_state="$(systemctl show -p LoadState --value "$LEGACY_UNIT_NAME" 2>/dev/null || true)"
  if [ "$load_state" != "not-found" ]; then
    systemctl disable --now "$LEGACY_UNIT_NAME"
    SYSTEMD_TOUCHED=1
    info "msg=\"disabled legacy unit\" unit=\"$LEGACY_UNIT_NAME\""
  else
    info "msg=\"legacy unit is not loaded, skipping disable\" unit=\"$LEGACY_UNIT_NAME\""
  fi

  backup="$LEGACY_UNIT.bak.$(date +%Y%m%dT%H%M%S)"
  if [ -e "$backup" ]; then
    backup="$backup.$$"
  fi
  cp -p -- "$LEGACY_UNIT" "$backup"
  REPLACED+=("$LEGACY_UNIT"$'\t'"$backup")
  rm -f -- "$LEGACY_UNIT"
  info "msg=\"removed legacy unit\" path=\"$LEGACY_UNIT\" backup=\"$backup\""
}

daemon_reload() {
  if [ "$DRY_RUN" -eq 1 ]; then
    info "msg=\"would run systemctl daemon-reload\""
    return 0
  fi
  SYSTEMD_TOUCHED=1
  systemctl daemon-reload
  info "msg=\"systemd reloaded\""
}

# Record the enabled and active state of every target unit before this run
# changes anything. rollback() uses it to undo only what the run did (#46):
# a pre-existing enabled+active instance must survive a failed install.
# The legacy non-template unit is snapshotted too: remove_legacy_unit stops
# and disables it, so a rollback has to bring it back as well.
capture_unit_state() {
  local gpu unit legacy_load_state
  for gpu in ${GPUS[@]+"${GPUS[@]}"}; do
    unit="$(unit_name "$gpu")"
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
      PRE_ACTIVE+=("$unit")
    fi
    if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
      PRE_ENABLED+=("$unit")
    fi
  done
  legacy_load_state="$(systemctl show -p LoadState --value "$LEGACY_UNIT_NAME" 2>/dev/null || true)"
  if [ -e "$LEGACY_UNIT" ] || [ "$legacy_load_state" != "not-found" ]; then
    PRE_LEGACY_SNAPSHOT=1
    if systemctl is-active --quiet "$LEGACY_UNIT_NAME" 2>/dev/null; then
      PRE_LEGACY_ACTIVE=1
    fi
    if systemctl is-enabled --quiet "$LEGACY_UNIT_NAME" 2>/dev/null; then
      PRE_LEGACY_ENABLED=1
    fi
    if [ "$PRE_LEGACY_ENABLED" -eq 1 ] || [ "$PRE_LEGACY_ACTIVE" -eq 1 ]; then
      info "msg=\"legacy unit state captured before this run\" unit=\"$LEGACY_UNIT_NAME\" enabled=$PRE_LEGACY_ENABLED active=$PRE_LEGACY_ACTIVE"
    fi
  fi
  if [ "${#PRE_ACTIVE[@]}" -gt 0 ]; then
    info "msg=\"instances already active before this run\" units=\"${PRE_ACTIVE[*]}\""
  fi
  if [ "${#PRE_ENABLED[@]}" -gt 0 ]; then
    info "msg=\"instances already enabled before this run\" units=\"${PRE_ENABLED[*]}\""
  fi
}

# uninstall.sh --keep-clocks leaves a marker that is meant for the current
# boot only. If it survived a reinstall, the new daemon would never release
# the clocks (#48), so a real install clears it before any unit is enabled.
clear_stale_keep_clocks() {
  if [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi
  if [ -e "$KEEP_CLOCKS_MARKER" ] || [ -L "$KEEP_CLOCKS_MARKER" ]; then
    rm -f -- "$KEEP_CLOCKS_MARKER"
    info "msg=\"cleared stale keep-clocks marker\" path=\"$KEEP_CLOCKS_MARKER\""
  fi
}

enable_units() {
  local gpu unit
  for gpu in ${GPUS[@]+"${GPUS[@]}"}; do
    unit="$(unit_name "$gpu")"
    if [ "$DRY_RUN" -eq 1 ]; then
      info "msg=\"would enable\" unit=\"$unit\""
      continue
    fi
    # Record before enabling: a failed enable can still leave the wants
    # symlink behind, and rollback has to remove it.
    ENABLED+=("$unit")
    systemctl enable --now "$unit"
    info "msg=\"enabled\" unit=\"$unit\""
  done
}

verify_installed() {
  local src_hash dst_hash
  if [ "$DRY_RUN" -eq 1 ]; then
    info "msg=\"would verify installed daemon\" path=\"$DAEMON_DST\" sha256=\"$(hash_of "$DAEMON_SRC")\""
    return 0
  fi
  src_hash="$(hash_of "$DAEMON_SRC")"
  dst_hash="$(hash_of "$DAEMON_DST")"
  if [ "$src_hash" != "$dst_hash" ]; then
    die "installed daemon checksum mismatch: src=$src_hash dst=$dst_hash"
  fi
  info "msg=\"verified installed daemon\" path=\"$DAEMON_DST\" sha256=\"$dst_hash\""
}

# Restart the instances that were already running, so "git pull && sudo
# ./install.sh" really executes the new code (#22).
restart_upgraded() {
  local unit
  if [ "${#PRE_ACTIVE[@]}" -eq 0 ]; then
    info "msg=\"no already-active instance to restart\""
    return 0
  fi
  if [ "$PAYLOAD_CHANGED" -eq 0 ]; then
    info "msg=\"payload unchanged, active instances were left running\""
    return 0
  fi
  for unit in "${PRE_ACTIVE[@]}"; do
    if [ "$DRY_RUN" -eq 1 ]; then
      info "msg=\"would restart\" unit=\"$unit\""
      continue
    fi
    if systemctl try-restart "$unit"; then
      info "msg=\"restarted to load the new code\" unit=\"$unit\""
    else
      error "msg=\"could not restart instance, it is still running the old code\" unit=\"$unit\" hint=\"systemctl restart $unit\""
      RESTART_FAILED=1
    fi
  done
}

print_status() {
  local gpu unit
  [ "$DRY_RUN" -eq 1 ] && return 0
  sleep 2
  for gpu in ${GPUS[@]+"${GPUS[@]}"}; do
    unit="$(unit_name "$gpu")"
    systemctl --no-pager --lines=3 status "$unit" || true
    printf '\n'
  done
}

summary() {
  local gpus_str installed_hash msg
  gpus_str="${GPUS[*]}"
  gpus_str="${gpus_str// /,}"
  if [ "$RESTART_FAILED" -ne 0 ]; then
    msg="install finished but a restart failed"
  else
    msg="install complete"
  fi
  info "msg=\"$msg\" gpus=\"$gpus_str\" dry_run=$DRY_RUN force=$FORCE"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'dry-run: nothing was written\n'
  else
    installed_hash="$(hash_of "$DAEMON_DST")"
    printf 'nvidia-idle-clock version=%s sha256=%s path=%s\n' \
      "$INSTALLER_VERSION" "$installed_hash" "$DAEMON_DST"
  fi
  printf 'per-GPU settings (drop-in): sudo systemctl edit nvidia-idle-clock@<GPU>.service\n'
  printf 'apply changed drop-ins:     sudo systemctl restart <unit>\n'
}

main() {
  parse_args "$@"

  # Validate first, write later: a typo in the arguments or a host without
  # systemd/nvidia-smi is reported before anything is copied, root or not.
  preflight
  load_gpu_indexes
  resolve_gpus

  # --dry-run writes nothing, so it works without root (and stays testable).
  if [ "$DRY_RUN" -eq 0 ]; then
    require_root
  fi
  check_source_tree

  info "msg=\"install plan\" version=\"$INSTALLER_VERSION\" gpus=\"${GPUS[*]}\" dry_run=$DRY_RUN force=$FORCE"

  # From here on the system is modified: a failure triggers rollback.
  trap 'rollback' ERR INT TERM

  # Snapshot the unit state first (read-only), so rollback knows which units
  # it may stop/disable and which ones were already running (#46).
  capture_unit_state
  stage_file "$DAEMON_SRC" "$DAEMON_DST" 0755
  stage_file "$UNIT_SRC" "$UNIT_DST" 0644
  remove_legacy_unit
  daemon_reload
  verify_installed
  clear_stale_keep_clocks
  enable_units

  # The installation itself is complete and consistent: stop undoing it. A
  # failed restart below is reported but must not remove working units.
  trap - ERR INT TERM

  restart_upgraded
  print_status
  summary

  if [ "$RESTART_FAILED" -ne 0 ]; then
    error "msg=\"install finished but at least one instance still runs the old code\""
    exit 1
  fi
  exit 0
}

main "$@"
