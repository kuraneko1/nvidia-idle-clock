#!/usr/bin/env bash
# nvidia-idle-clock uninstaller.
#
# Every step is checked instead of being silenced with "|| true" (#14): a
# failed stop aborts the removal (so a running daemon is never left without
# its unit), a failed removal or clock release is reported and makes the whole
# run fail, and success is only printed when the verification passed.
set -euo pipefail

PROG="$(basename -- "$0")"

DAEMON_BIN="/usr/local/sbin/nvidia-idle-clock"
UNIT_TEMPLATE="/etc/systemd/system/nvidia-idle-clock@.service"
LEGACY_UNIT="/etc/systemd/system/nvidia-idle-clock.service"
LEGACY_UNIT_NAME="nvidia-idle-clock.service"
# Template drop-in directory: systemd keeps "nvidia-idle-clock@.service.d"
# for the template itself, plus one "*.service.d" per instance.
UNIT_DIR="/etc/systemd/system"

# Marker directory shared with the daemon (STATE_DIR, default
# /run/nvidia-idle-clock). While "$STATE_DIR/keep-clocks" exists, the daemon's
# shutdown path and the unit's ExecStopPost "--unlock" keep the clock clamp,
# so --keep-clocks has to create it before the first unit is stopped (#48).
STATE_DIR="${STATE_DIR:-/run/nvidia-idle-clock}"
KEEP_CLOCKS_MARKER="$STATE_DIR/keep-clocks"
MARKER_CREATED=0

DRY_RUN=0
KEEP_CLOCKS=0
FAIL=0
SYSTEMD_OK=1

# --- output ---------------------------------------------------------------
# Stable key=value records, so logs stay greppable (see issue #31).
info()  { printf 'level=info %s\n' "$*"; }
warn()  { printf 'level=warn %s\n' "$*" >&2; }
error() { printf 'level=error %s\n' "$*" >&2; }

usage() {
  cat <<EOF
usage: $PROG [OPTIONS]

Stop and disable every nvidia-idle-clock instance, remove the installed
daemon and unit files (including per-instance drop-in directories) and
release the GPU clock locks with "nvidia-smi -rgc".

options:
  -h, --help        show this help and exit
  -n, --dry-run     print every action without changing anything
                    (does not need root)
      --keep-clocks keep the current GPU clock limit. A keep-clocks marker is
                    written to $STATE_DIR before the instances are stopped, so
                    both the daemon's shutdown and the unit's ExecStopPost
                    "--unlock" leave the clamp in place. The limit survives
                    until reboot; delete $STATE_DIR or run
                    "sudo nvidia-smi -rgc" to release it earlier.
EOF
}

usage_error() {
  error "msg=\"$1\" hint=\"run '$PROG --help'\""
  printf 'usage: %s [OPTIONS]\n' "$PROG" >&2
  exit 2
}

die() {
  error "msg=\"$1\""
  exit 1
}

# --- helpers --------------------------------------------------------------
parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      -n|--dry-run)
        DRY_RUN=1
        shift
        ;;
      --keep-clocks)
        KEEP_CLOCKS=1
        shift
        ;;
      --)
        shift
        [ "$#" -eq 0 ] || usage_error "unexpected argument: $1"
        ;;
      -*)
        usage_error "unknown option: $1"
        ;;
      *)
        usage_error "unexpected argument: $1"
        ;;
    esac
  done
}

require_root() {
  [ "$(id -u)" -eq 0 ] && return 0
  die "root privileges are required; run: sudo ./uninstall.sh"
}

preflight() {
  command -v systemctl >/dev/null 2>&1 || die "systemctl not found; nothing was removed"

  # "offline"/"unknown" means there is no systemd to talk to (container, WSL,
  # chroot). Removing files is still useful there, but the unit steps cannot
  # run; say so instead of pretending they succeeded.
  local state
  state="$(systemctl is-system-running 2>/dev/null || true)"
  case "$state" in
    running|degraded|starting|initializing|maintenance) ;;
    *)
      SYSTEMD_OK=0
      warn 'msg="systemd is not running, unit steps are skipped"' "state=\"${state:-none}\"" 'note="remove the files only"'
      ;;
  esac
}

# --- steps ----------------------------------------------------------------
# --keep-clocks (#48): the flag alone only skips release_clocks(), which runs
# after the units are gone. Every stop releases the clamp from the daemon's
# shutdown path and from ExecStopPost --unlock, so the marker has to exist
# before the first stop. A failure removes it again, otherwise a later stop
# would silently keep a clamp nobody asked to keep.
prepare_keep_clocks() {
  [ "$KEEP_CLOCKS" -eq 1 ] || return 0

  if [ "$DRY_RUN" -eq 1 ]; then
    info "msg=\"would create keep-clocks marker\"" "path=\"$KEEP_CLOCKS_MARKER\""
    return 0
  fi

  if ! mkdir -p -- "$STATE_DIR"; then
    die "could not create $STATE_DIR; the clock limit could not be kept, so the instances were left running (nothing was removed)"
  fi
  if ! chmod 0700 -- "$STATE_DIR"; then
    die "could not set mode 0700 on $STATE_DIR; the instances were left running (nothing was removed)"
  fi
  # umask keeps the file private even if the chmod below never runs.
  if ! ( umask 077 && : >"$KEEP_CLOCKS_MARKER" ); then
    die "could not create $KEEP_CLOCKS_MARKER; the clock limit could not be kept, so the instances were left running (nothing was removed)"
  fi
  MARKER_CREATED=1
  if ! chmod 0600 -- "$KEEP_CLOCKS_MARKER"; then
    die "could not set mode 0600 on $KEEP_CLOCKS_MARKER; the instances were left running (nothing was removed)"
  fi
  info "msg=\"keep-clocks marker created\"" "path=\"$KEEP_CLOCKS_MARKER\"" \
    "hint=\"the daemon and --unlock keep the clamp while this file exists\""
}

# EXIT trap: only a successful run may leave the marker behind.
cleanup_keep_clocks_marker() {
  local rc=$?
  if [ "$MARKER_CREATED" -ne 1 ] || [ "$rc" -eq 0 ]; then
    return 0
  fi
  if rm -f -- "$KEEP_CLOCKS_MARKER"; then
    warn "msg=\"removed the keep-clocks marker after a failed run\"" \
      "path=\"$KEEP_CLOCKS_MARKER\"" "note=\"a later stop releases the clock limit as usual\""
  else
    error "msg=\"could not remove the keep-clocks marker after a failed run\"" \
      "path=\"$KEEP_CLOCKS_MARKER\"" "hint=\"rm -f $KEEP_CLOCKS_MARKER\""
  fi
  return 0
}

stop_instances() {
  local list unit
  [ "$SYSTEMD_OK" -eq 1 ] || return 0

  if ! list="$(systemctl list-units --all --plain --no-legend 'nvidia-idle-clock@*.service' 2>/dev/null)"; then
    # Without the list we cannot know what is still running: stop here rather
    # than deleting unit files behind a live daemon.
    error "msg=\"could not list nvidia-idle-clock instances; files were left in place\""
    exit 1
  fi

  local -a units=()
  while IFS= read -r unit; do
    unit="${unit%% *}"
    [ -n "$unit" ] || continue
    units+=("$unit")
  done <<<"$list"

  for unit in ${units[@]+"${units[@]}"}; do
    if [ "$DRY_RUN" -eq 1 ]; then
      info "msg=\"would disable\" unit=\"$unit\""
      continue
    fi
    if systemctl disable --now "$unit"; then
      info "msg=\"disabled\" unit=\"$unit\""
    else
      error "msg=\"could not stop and disable\" unit=\"$unit\" hint=\"systemctl disable --now $unit\""
      FAIL=1
    fi
  done
}

stop_legacy_unit() {
  local load_state
  [ "$SYSTEMD_OK" -eq 1 ] || return 0
  [ -e "$LEGACY_UNIT" ] || return 0

  load_state="$(systemctl show -p LoadState --value "$LEGACY_UNIT_NAME" 2>/dev/null || true)"
  if [ "$load_state" = "not-found" ]; then
    info "msg=\"legacy unit is not loaded, skipping disable\" unit=\"$LEGACY_UNIT_NAME\""
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "msg=\"would disable legacy unit\" unit=\"$LEGACY_UNIT_NAME\""
    return 0
  fi
  if systemctl disable --now "$LEGACY_UNIT_NAME"; then
    info "msg=\"disabled legacy unit\" unit=\"$LEGACY_UNIT_NAME\""
  else
    error "msg=\"could not stop and disable legacy unit\" unit=\"$LEGACY_UNIT_NAME\""
    FAIL=1
  fi
}

# Remove a file or directory; failures are collected instead of aborting the
# run, so the remaining cleanup still happens.
remove_path() {
  local path="$1" flag="${2:-}"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    info "msg=\"not present\" path=\"$path\""
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    info "msg=\"would remove\" path=\"$path\""
    return 0
  fi
  if [ -n "$flag" ]; then
    if rm -rf -- "$path"; then
      info "msg=\"removed\" path=\"$path\""
    else
      error "msg=\"could not remove\" path=\"$path\""
      FAIL=1
    fi
    return 0
  fi
  if rm -f -- "$path"; then
    info "msg=\"removed\" path=\"$path\""
  else
    error "msg=\"could not remove\" path=\"$path\""
    FAIL=1
  fi
}

remove_files() {
  local dir
  remove_path "$UNIT_TEMPLATE"
  remove_path "$LEGACY_UNIT"
  remove_path "$DAEMON_BIN"

  # Drop-ins are the documented place for per-GPU settings, and they survive
  # a reinstall; remove the template directory and every instance directory.
  for dir in "$UNIT_DIR"/nvidia-idle-clock@*.service.d "$UNIT_DIR/nvidia-idle-clock@.service.d"; do
    [ -d "$dir" ] || continue
    remove_path "$dir" recursive
  done
}

reload_systemd() {
  [ "$SYSTEMD_OK" -eq 1 ] || return 0
  if [ "$DRY_RUN" -eq 1 ]; then
    info "msg=\"would run systemctl daemon-reload\""
    return 0
  fi
  if systemctl daemon-reload; then
    info "msg=\"systemd reloaded\""
  else
    error "msg=\"systemctl daemon-reload failed\""
    FAIL=1
  fi
  # reset-failed is cosmetic: a unit that is gone cannot be started again.
  systemctl reset-failed 'nvidia-idle-clock@*' >/dev/null 2>&1 \
    || warn "msg=\"systemctl reset-failed failed (harmless)\""
}

# Release the clock lock with -rgc for every GPU and verify the exit code;
# the audit (#14) showed that a silent failure here leaves a GPU clamped at
# 135MHz until the next reboot.
release_clocks() {
  local gpus gpu
  local -a failed=() released=()

  if [ "$KEEP_CLOCKS" -eq 1 ]; then
    info "msg=\"clock locks kept (--keep-clocks)\"" \
      "hint=\"kept until reboot: delete $STATE_DIR or run: sudo nvidia-smi -rgc\""
    return 0
  fi

  if ! command -v nvidia-smi >/dev/null 2>&1; then
    info "msg=\"nvidia-smi not found, no clock lock to release\""
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    gpus="$(nvidia-smi --query-gpu=index --format=csv,noheader,nounits 2>/dev/null || true)"
    gpus="${gpus//[[:space:]]/ }"
    if [ -z "${gpus// /}" ]; then
      info "msg=\"would query the GPUs and release every clock lock\""
    else
      for gpu in $gpus; do
        info 'msg="would release clock lock"' "gpu=\"$gpu\""
      done
    fi
    return 0
  fi

  if ! gpus="$(nvidia-smi --query-gpu=index --format=csv,noheader,nounits 2>/dev/null)"; then
    error "msg=\"could not enumerate GPUs with nvidia-smi\" hint=\"release the locks by hand: sudo nvidia-smi -i <N> -rgc\""
    FAIL=1
    return 0
  fi
  gpus="${gpus//[[:space:]]/ }"
  if [ -z "${gpus// /}" ]; then
    error "msg=\"nvidia-smi reported no GPU; cannot verify that the clock locks were released\" hint=\"sudo nvidia-smi -i <N> -rgc\""
    FAIL=1
    return 0
  fi

  for gpu in $gpus; do
    if nvidia-smi -i "$gpu" -rgc >/dev/null 2>&1; then
      info 'msg="clock lock released"' "gpu=\"$gpu\""
      released+=("$gpu")
    else
      error 'msg="could not release the clock lock"' "gpu=\"$gpu\"" "hint=\"sudo nvidia-smi -i $gpu -rgc\""
      failed+=("$gpu")
      FAIL=1
    fi
  done

  if [ "${#failed[@]}" -gt 0 ]; then
    warn "msg=\"clocks still locked\" gpus=\"${failed[*]}\""
  elif [ "${#released[@]}" -eq 0 ]; then
    error "msg=\"no GPU was released\""
    FAIL=1
  fi
}

# Verify the end state instead of trusting the exit codes alone.
verify_removed() {
  local path missing=0
  for path in "$UNIT_TEMPLATE" "$LEGACY_UNIT" "$DAEMON_BIN"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      error "msg=\"file still present after removal\" path=\"$path\""
      FAIL=1
      missing=1
    fi
  done
  for path in "$UNIT_DIR"/nvidia-idle-clock@*.service.d "$UNIT_DIR/nvidia-idle-clock@.service.d"; do
    if [ -d "$path" ]; then
      error "msg=\"drop-in directory still present after removal\" path=\"$path\""
      FAIL=1
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || return 0
  info "msg=\"verified removal\" paths=\"$UNIT_TEMPLATE $LEGACY_UNIT $DAEMON_BIN\""
}

main() {
  local clock_note
  parse_args "$@"

  if [ "$DRY_RUN" -eq 0 ]; then
    require_root
  fi
  preflight

  # Any non-zero exit (including the stop failure below) removes the marker.
  trap cleanup_keep_clocks_marker EXIT
  prepare_keep_clocks
  stop_instances
  stop_legacy_unit
  # Removing a unit file while its daemon is still running would leave the
  # clamp active with no way to stop it: abort before deleting anything.
  if [ "$FAIL" -ne 0 ]; then
    error "msg=\"at least one unit could not be stopped; files were left in place\""
    exit 1
  fi
  remove_files
  reload_systemd
  release_clocks

  if [ "$DRY_RUN" -eq 1 ]; then
    info "msg=\"dry-run complete\" dry_run=1 keep_clocks=$KEEP_CLOCKS"
    printf 'dry-run: nothing was changed\n'
    exit 0
  fi

  verify_removed

  if [ "$FAIL" -ne 0 ]; then
    error "msg=\"uninstall incomplete\" hint=\"fix the errors above and run the uninstaller again\""
    exit 1
  fi

  if [ "$KEEP_CLOCKS" -eq 1 ]; then
    clock_note="the GPU clock limit is kept until reboot"
  else
    clock_note="clock locks released"
  fi
  [ "$SYSTEMD_OK" -eq 1 ] \
    || warn 'msg="systemd was not running: unit state was not cleaned up"'
  info 'msg="uninstall complete"' "clocks=\"$clock_note\""
  printf 'uninstall complete: units removed, %s\n' "$clock_note"
  if [ "$KEEP_CLOCKS" -eq 1 ]; then
    printf 'release it earlier with: sudo nvidia-smi -rgc\n'
    printf 'or delete the state directory %s (removes the marker)\n' "$STATE_DIR"
  fi
}

main "$@"
