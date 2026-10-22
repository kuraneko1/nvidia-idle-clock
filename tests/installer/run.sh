#!/usr/bin/env bash
# Tests for install.sh and uninstall.sh.
#
# Nothing outside a temporary directory is modified:
#   * every privileged command (systemctl, nvidia-smi, install) is a PATH shim
#     that only records the call,
#   * the installer paths that do not write (--help, argument errors,
#     --dry-run, source-tree trust check) run directly,
#   * the tests that need root (backup, rollback, real uninstall) run inside a
#     bubblewrap user namespace where /etc/systemd/system and /usr/local/sbin
#     are temporary directories. They are skipped when bwrap cannot create a
#     user namespace.
#
# Run as a normal user:  bash tests/installer/run.sh
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "$0")/../.." && pwd -P)"
INSTALL="$ROOT_DIR/install.sh"
UNINSTALL="$ROOT_DIR/uninstall.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/nvidia-idle-clock-installer-tests.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

SHIM_DIR="$WORK/shim"
SHIM_BWRAP="$WORK/shim-bwrap"
SHIM_LOG="$WORK/shim.log"

PASS=0
FAIL=0
SKIP=0
RC=0
OUT=""
ERR=""

ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf 'skip %s (%s)\n' "$1" "$2"; }
bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL %s\n' "$1"
  shift
  local line
  for line in "$@"; do printf '     %s\n' "$line"; done
}

assert_rc() {
  local want="$1" name="$2"
  if [ "$RC" -eq "$want" ]; then
    ok "$name"
  else
    bad "$name" "rc=$RC want=$want" "stdout:" "$OUT" "stderr:" "$ERR"
  fi
}

assert_nonzero_rc() {
  local name="$1"
  if [ "$RC" -ne 0 ]; then
    ok "$name"
  else
    bad "$name" "rc=0 want non-zero" "stdout:" "$OUT" "stderr:" "$ERR"
  fi
}

assert_contains() {
  local hay="$1" needle="$2" name="$3"
  case "$hay" in
    *"$needle"*) ok "$name" ;;
    *) bad "$name" "missing: $needle" "stdout:" "$OUT" "stderr:" "$ERR" ;;
  esac
}

assert_not_contains() {
  local hay="$1" needle="$2" name="$3"
  case "$hay" in
    *"$needle"*) bad "$name" "unexpected: $needle" "stdout:" "$OUT" "stderr:" "$ERR" ;;
    *) ok "$name" ;;
  esac
}

assert_equal() {
  local got="$1" want="$2" name="$3"
  if [ "$got" = "$want" ]; then
    ok "$name"
  else
    bad "$name" "got: $got" "want: $want"
  fi
}

assert_count() {
  local hay="$1" needle="$2" want="$3" name="$4"
  local count=0 rest="$hay"
  while :; do
    case "$rest" in
      *"$needle"*)
        count=$((count + 1))
        rest="${rest#*"$needle"}"
        ;;
      *) break ;;
    esac
  done
  if [ "$count" -eq "$want" ]; then
    ok "$name"
  else
    bad "$name" "count=$count want=$want needle: $needle" "stdout:" "$OUT" "stderr:" "$ERR"
  fi
}

first_line() {
  local line=""
  { IFS= read -r line || true; } <"$1"
  printf '%s' "$line"
}

file_mode() {
  stat -c %a -- "$1" 2>/dev/null || printf 'missing'
}

# --- shims ----------------------------------------------------------------
# The shims record "<tool> <args>" in $SHIM_LOG, so a test can prove that a
# command was (or was not) executed. Behaviour is driven by FAKE_* variables.
make_systemctl_shim() {
  cat >"$1/systemctl" <<'SHIM'
#!/bin/sh
[ -n "${SHIM_LOG:-}" ] && printf 'systemctl %s\n' "$*" >>"$SHIM_LOG"
unit=""
for arg in "$@"; do
  case "$arg" in
    -*) ;;
    *) unit="$arg" ;;
  esac
done
case "${1:-}" in
  is-system-running)
    printf '%s\n' "${FAKE_SYSTEM_STATE:-running}"
    exit 0
    ;;
  is-active)
    if [ -n "${SHIM_STATE_DIR:-}" ]; then
      [ -e "$SHIM_STATE_DIR/active/$unit" ] && exit 0
      exit 3
    fi
    case " ${FAKE_ACTIVE_UNITS:-} " in
      *" $unit "*) exit 0 ;;
      *) exit 3 ;;
    esac
    ;;
  is-enabled)
    if [ -n "${SHIM_STATE_DIR:-}" ]; then
      [ -e "$SHIM_STATE_DIR/enabled/$unit" ] && exit 0
      exit 1
    fi
    case " ${FAKE_ENABLED_UNITS:-} " in
      *" $unit "*) exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  list-units)
    for u in ${FAKE_UNITS:-}; do
      printf '%s loaded active running test\n' "$u"
    done
    exit 0
    ;;
  enable)
    if [ -n "${FAKE_ENABLE_FAIL_UNIT:-}" ] && [ "$unit" = "$FAKE_ENABLE_FAIL_UNIT" ]; then
      printf 'Job for %s failed because the control process exited with error code.\n' "$unit" >&2
      exit 1
    fi
    if [ -n "${SHIM_STATE_DIR:-}" ]; then
      mkdir -p "$SHIM_STATE_DIR/enabled" && : >"$SHIM_STATE_DIR/enabled/$unit"
      case " $* " in
        *" --now "*) mkdir -p "$SHIM_STATE_DIR/active" && : >"$SHIM_STATE_DIR/active/$unit" ;;
      esac
    fi
    exit 0
    ;;
  disable)
    # #48: record whether the --keep-clocks marker existed when the unit was
    # stopped. The shim cannot run the daemon or ExecStopPost, so this proves
    # the ordering (marker before the first stop), not the clamp itself.
    if [ -n "${TEST_MARKER:-}" ] && [ -n "${SHIM_LOG:-}" ]; then
      if [ -e "$TEST_MARKER" ]; then
        printf 'marker=present before systemctl %s\n' "$*" >>"$SHIM_LOG"
      else
        printf 'marker=absent before systemctl %s\n' "$*" >>"$SHIM_LOG"
      fi
    fi
    if [ -n "${FAKE_DISABLE_FAIL_UNIT:-}" ] && [ "$unit" = "$FAKE_DISABLE_FAIL_UNIT" ]; then
      printf 'Failed to disable unit: Unit file is read-only.\n' >&2
      exit 1
    fi
    if [ -n "${SHIM_STATE_DIR:-}" ]; then
      rm -f "$SHIM_STATE_DIR/enabled/$unit"
      case " $* " in
        *" --now "*) rm -f "$SHIM_STATE_DIR/active/$unit" ;;
      esac
    fi
    exit 0
    ;;
  start)
    if [ -n "${FAKE_START_FAIL_UNIT:-}" ] && [ "$unit" = "$FAKE_START_FAIL_UNIT" ]; then
      printf 'Job for %s failed because the control process exited with error code.\n' "$unit" >&2
      exit 1
    fi
    if [ -n "${SHIM_STATE_DIR:-}" ]; then
      mkdir -p "$SHIM_STATE_DIR/active" && : >"$SHIM_STATE_DIR/active/$unit"
    fi
    exit 0
    ;;
  stop)
    if [ -n "${SHIM_STATE_DIR:-}" ]; then
      rm -f "$SHIM_STATE_DIR/active/$unit"
    fi
    exit 0
    ;;
  show)
    printf '%s\n' "${FAKE_LOAD_STATE:-loaded}"
    exit 0
    ;;
  try-restart)
    if [ -n "${FAKE_RESTART_FAIL_UNIT:-}" ] && [ "$unit" = "$FAKE_RESTART_FAIL_UNIT" ]; then
      exit 1
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
SHIM
  chmod +x "$1/systemctl"
}

make_nvidia_smi_shim() {
  cat >"$1/nvidia-smi" <<'SHIM'
#!/bin/sh
[ -n "${SHIM_LOG:-}" ] && printf 'nvidia-smi %s\n' "$*" >>"$SHIM_LOG"
uuid0="${FAKE_UUID0:-GPU-00000000-1111-2222-3333-444444444444}"
uuid1="${FAKE_UUID1:-GPU-55555555-6666-7777-8888-999999999999}"
case "$*" in
  *--query-gpu=index,uuid*)
    printf '0, %s\n1, %s\n' "$uuid0" "$uuid1"
    ;;
  *--query-gpu=index*)
    for g in ${FAKE_GPUS:-0 1}; do printf '%s\n' "$g"; done
    ;;
  *--query-gpu=uuid*)
    printf '%s\n%s\n' "$uuid0" "$uuid1"
    ;;
  -L)
    printf 'GPU 0: Fake V100 (UUID: %s)\n' "$uuid0"
    printf '  MIG 1g.5gb Device 0: (UUID: MIG-11111111-2222-3333-4444-555555555555)\n'
    printf 'GPU 1: Fake V100 (UUID: %s)\n' "$uuid1"
    ;;
  *-rgc*)
    exit "${FAKE_RGC_RC:-0}"
    ;;
  *)
    exit 0
    ;;
esac
exit 0
SHIM
  chmod +x "$1/nvidia-smi"
}

make_install_shim() {
  cat >"$1/install" <<'SHIM'
#!/bin/sh
[ -n "${SHIM_LOG:-}" ] && printf 'install %s\n' "$*" >>"$SHIM_LOG"
exit "${FAKE_INSTALL_RC:-0}"
SHIM
  chmod +x "$1/install"
}

make_shims() {
  local dir="$1"
  mkdir -p "$dir"
  make_systemctl_shim "$dir"
  make_nvidia_smi_shim "$dir"
  make_install_shim "$dir"
}

# --- running the installer with the shims ---------------------------------
# The FAKE_* variables the test body exports are inherited by the shims.
# SUDO_UID is cleared so the trust check compares against the current user.
_run() {
  local script="$1"
  shift
  local out="$WORK/out.txt" err="$WORK/err.txt"
  env -u SUDO_UID -u SUDO_GID PATH="$SHIM_DIR:$PATH" SHIM_LOG="$SHIM_LOG" \
    "$script" "$@" >"$out" 2>"$err"
  RC=$?
  OUT="$(<"$out")"
  ERR="$(<"$err")"
}

run_install()   { _run "$INSTALL" "$@"; }
run_uninstall() { _run "$UNINSTALL" "$@"; }

shim_log() {
  if [ -f "$SHIM_LOG" ]; then cat "$SHIM_LOG"; fi
}

reset_shim_log() {
  : >"$SHIM_LOG"
}

# --- bwrap sandbox --------------------------------------------------------
BWRAP_OK=0
if command -v bwrap >/dev/null 2>&1; then
  if bwrap --ro-bind / / --dev /dev --uid 0 --gid 0 /bin/sh -c 'exit 0' >/dev/null 2>&1; then
    BWRAP_OK=1
  fi
fi

SB=""
BLOG=""

# new_sandbox <name>: temporary /etc/systemd/system + /usr/local/sbin stand-ins
new_sandbox() {
  SB="$WORK/sb-$1"
  rm -rf -- "$SB"
  mkdir -p "$SB/usr_local_sbin" "$SB/etc_systemd" "$SB/src" "$SB/tree" "$SB/out"
  cp -p "$ROOT_DIR/install.sh" "$ROOT_DIR/nvidia-idle-clock" \
    "$ROOT_DIR/nvidia-idle-clock@.service" "$SB/src/"
  BLOG="$SB/out/shim.log"
  : >"$BLOG"
}

# run_in_sandbox <sandbox> <inner-script>
run_in_sandbox() {
  local sb="$1" script="$2"
  bwrap --ro-bind / / --dev /dev \
    --bind "$sb" "$sb" \
    --bind "$sb/usr_local_sbin" /usr/local/sbin \
    --bind "$sb/etc_systemd" /etc/systemd/system \
    --uid 0 --gid 0 \
    --setenv PATH "$SHIM_BWRAP:/usr/bin:/bin" \
    --setenv SHIM_LOG "$BLOG" \
    --setenv STATE_DIR "$sb/state" \
    /bin/bash "$script" >"$sb/out/bwrap.out" 2>"$sb/out/bwrap.err"
  RC=$?
  OUT="$(<"$sb/out/bwrap.out")"
  ERR="$(<"$sb/out/bwrap.err")"
}

bwrap_log() {
  if [ -f "$BLOG" ]; then cat "$BLOG"; fi
}

# Inner script: copy the checkout into the sandbox as root-owned files, export
# the fake environment and run the installer with the given arguments.
write_inner_install() {
  local script="$1" args="${2:-}" envs="${3:-}"
  {
    printf 'set -u\n'
    if [ -n "$envs" ]; then printf '%s\n' "$envs"; fi
    cat <<EOF
cp -a '$SB/src/.' '$SB/tree/'
chown -R 0:0 '$SB/tree'
chmod -R go-w '$SB/tree'
cd '$SB/tree' || exit 99
./install.sh $args
rc=\$?
echo "INNER_RC=\$rc"
stat -c 'INSTALLED_OWNER=%u:%g' /usr/local/sbin/nvidia-idle-clock 2>/dev/null || echo 'INSTALLED_OWNER=missing'
stat -c 'INSTALLED_MODE=%a' /usr/local/sbin/nvidia-idle-clock 2>/dev/null || echo 'INSTALLED_MODE=missing'
stat -c 'UNIT_OWNER=%u:%g' /etc/systemd/system/nvidia-idle-clock@.service 2>/dev/null || echo 'UNIT_OWNER=missing'
exit \$rc
EOF
  } >"$script"
}

write_inner_uninstall() {
  local script="$1" args="${2:-}" envs="${3:-}"
  {
    printf 'set -u\n'
    if [ -n "$envs" ]; then printf '%s\n' "$envs"; fi
    cat <<EOF
'$UNINSTALL' $args
rc=\$?
echo "INNER_RC=\$rc"
exit \$rc
EOF
  } >"$script"
}

dropin_dirs() {
  local sb="$1"
  mkdir -p "$sb/etc_systemd/nvidia-idle-clock@.service.d"
  mkdir -p "$sb/etc_systemd/nvidia-idle-clock@0.service.d"
  printf '[Service]\nEnvironment=IDLE_CAP=555\n' \
    >"$sb/etc_systemd/nvidia-idle-clock@0.service.d/cap.conf"
}

backup_count() {
  local -a found=()
  shopt -s nullglob
  found=("$1"/nvidia-idle-clock.bak.*)
  shopt -u nullglob
  printf '%s' "${#found[@]}"
}

glob_count() {
  local dir="$1" pattern="$2" line count=0
  while IFS= read -r line; do
    if [ -n "$line" ]; then count=$((count + 1)); fi
  done < <(compgen -G "$dir/$pattern" || true)
  printf '%s' "$count"
}

backup_path() {
  local -a found=()
  shopt -s nullglob
  found=("$1"/nvidia-idle-clock.bak.*)
  shopt -u nullglob
  printf '%s' "${found[0]:-}"
}

# ---------------------------------------------------------------------------
make_shims "$SHIM_DIR"
mkdir -p "$SHIM_BWRAP"
make_systemctl_shim "$SHIM_BWRAP"
make_nvidia_smi_shim "$SHIM_BWRAP"

printf '== install.sh: options and validation ==\n'
reset_shim_log
run_install --help
assert_rc 0 "--help exits 0"
assert_contains "$OUT" "usage:" "--help prints usage"
assert_contains "$OUT" "--dry-run" "--help documents --dry-run"
assert_contains "$OUT" "--force" "--help documents --force"
assert_not_contains "$(shim_log)" "systemctl enable" "--help does not touch systemd"

reset_shim_log
run_install -h
assert_rc 0 "-h exits 0"
assert_contains "$OUT" "usage:" "-h prints usage"

reset_shim_log
run_install --version
assert_rc 0 "--version exits 0"
assert_contains "$OUT" "installer 0.2.4" "--version prints the installer version"
assert_contains "$OUT" "daemon sha256=" "--version prints the daemon hash"
assert_not_contains "$OUT" "sha256=unavailable" "--version finds the daemon"
assert_not_contains "$(shim_log)" "systemctl enable" "--version does not touch systemd"

reset_shim_log
run_install --bogus
assert_rc 2 "unknown option --bogus exits 2"
assert_contains "$ERR" "usage:" "unknown option prints usage"
assert_contains "$ERR" "unknown option" "unknown option is named"
assert_not_contains "$(shim_log)" "systemctl enable" "unknown option enables nothing"
assert_not_contains "$(shim_log)" "install " "unknown option installs nothing"

reset_shim_log
run_install -x
assert_rc 2 "unknown short option -x exits 2"

# A flag after "--" is a GPU argument, not an option, and must be rejected
# before it can become the instance name of a unit.
reset_shim_log
run_install -- --help
assert_rc 2 "'-- --help' is rejected as a GPU argument"
assert_contains "$ERR" "invalid GPU argument" "'-- --help' explains the rejection"
assert_not_contains "$(shim_log)" "@--help.service" "'--help' never becomes a unit name"

reset_shim_log
run_install '*'
assert_rc 2 "'*' is rejected as a GPU argument"
assert_not_contains "$(shim_log)" "@*.service" "'*' is not glob-expanded into units"

reset_shim_log
run_install 999
assert_rc 2 "missing GPU index 999 exits 2"
assert_contains "$ERR" "does not exist" "missing GPU index is explained"
assert_not_contains "$(shim_log)" "enable --now nvidia-idle-clock@999" "missing GPU is never enabled"

reset_shim_log
run_install 4notanindex
assert_rc 2 "junk GPU argument exits 2"

reset_shim_log
run_install --gpus
assert_rc 2 "--gpus without a value exits 2"

reset_shim_log
run_install --gpus= --dry-run
assert_rc 2 "--gpus= with an empty value exits 2"

reset_shim_log
run_install --gpus 0,1 --dry-run
assert_rc 0 "--gpus 0,1 --dry-run exits 0"
assert_contains "$OUT" 'would enable" unit="nvidia-idle-clock@0.service' "--gpus selects GPU 0"
assert_contains "$OUT" 'would enable" unit="nvidia-idle-clock@1.service' "--gpus selects GPU 1"

reset_shim_log
run_install --dry-run 0 0 1
assert_rc 0 "duplicate GPU list exits 0"
assert_count "$OUT" 'would enable" unit="nvidia-idle-clock@0.service' 1 "duplicate GPU 0 is enabled once"

reset_shim_log
run_install --dry-run
assert_rc 0 "no GPU argument uses every detected GPU"
assert_contains "$OUT" 'would enable" unit="nvidia-idle-clock@1.service' "every detected GPU is used"

# A GPU UUID is accepted and resolved to its index, because the daemon and the
# template unit address GPUs by index.
reset_shim_log
run_install --dry-run GPU-55555555-6666-7777-8888-999999999999
assert_rc 0 "GPU UUID is accepted"
assert_contains "$OUT" "resolved GPU UUID to index" "GPU UUID is resolved"
assert_contains "$OUT" 'would enable" unit="nvidia-idle-clock@1.service' "GPU UUID resolves to index 1"

reset_shim_log
run_install --dry-run GPU-99999999-9999-9999-9999-999999999999
assert_rc 2 "unknown GPU UUID exits 2"

reset_shim_log
run_install --dry-run MIG-11111111-2222-3333-4444-555555555555
assert_rc 0 "MIG identifier is accepted"
assert_contains "$OUT" "resolved MIG identifier to parent GPU index" "MIG identifier is mapped to its parent GPU"

# --- preflight -------------------------------------------------------------
reset_shim_log
export FAKE_SYSTEM_STATE=offline
run_install --dry-run 0
unset FAKE_SYSTEM_STATE
assert_rc 1 "systemd offline is refused"
assert_contains "$ERR" "systemd is not running" "offline systemd is explained"

reset_shim_log
export FAKE_SYSTEM_STATE=unknown
run_install --dry-run 0
unset FAKE_SYSTEM_STATE
assert_rc 1 "systemd unknown is refused"

# A degraded systemd is normal (an unrelated unit failed) and must not block
# the installation.
reset_shim_log
export FAKE_SYSTEM_STATE=degraded
run_install --dry-run 0
unset FAKE_SYSTEM_STATE
assert_rc 0 "degraded systemd is accepted"

# Without nvidia-smi in PATH the installer must stop before writing. The
# restricted PATH contains only the commands a successful run needs, so this
# test also works on a host that has the real driver installed.
PATH_NO_SMI="$WORK/path-no-smi"
mkdir -p "$PATH_NO_SMI"
for cmd in bash install sha256sum stat cp cmp date dirname basename id cat; do
  ln -sf "$(command -v "$cmd")" "$PATH_NO_SMI/$cmd"
done
ln -sf "$SHIM_DIR/systemctl" "$PATH_NO_SMI/systemctl"
env -u SUDO_UID -u SUDO_GID PATH="$PATH_NO_SMI" \
  "$INSTALL" --dry-run 0 >"$WORK/out.txt" 2>"$WORK/err.txt"
RC=$?
OUT="$(<"$WORK/out.txt")"
ERR="$(<"$WORK/err.txt")"
assert_rc 1 "missing nvidia-smi is refused"
assert_contains "$ERR" "required command" "missing nvidia-smi is explained"

# A real run (not --dry-run) needs root.
if [ "$(id -u)" -ne 0 ]; then
  reset_shim_log
  run_install 0
  assert_rc 1 "non-root install is refused"
  assert_contains "$ERR" "root privileges" "non-root install is explained"
  assert_not_contains "$(shim_log)" "install " "non-root install writes nothing"
else
  skip "non-root install is refused" "tests run as root"
fi

# --- dry-run never writes --------------------------------------------------
reset_shim_log
run_install --dry-run 0 1
assert_rc 0 "dry-run exits 0"
assert_contains "$OUT" 'would install" src=' "dry-run prints the planned install"
assert_contains "$OUT" "would run systemctl daemon-reload" "dry-run prints daemon-reload"
assert_contains "$OUT" "dry-run: nothing was written" "dry-run says nothing was written"
LOG="$(shim_log)"
assert_not_contains "$LOG" "install " "dry-run does not call install"
assert_not_contains "$LOG" "systemctl enable" "dry-run does not enable units"
assert_not_contains "$LOG" "daemon-reload" "dry-run does not reload systemd"

# #48: a stale keep-clocks marker must survive a dry run, which promises not
# to change anything.
KEEP_STATE="$WORK/keep-state"
mkdir -p "$KEEP_STATE"
: >"$KEEP_STATE/keep-clocks"
reset_shim_log
export STATE_DIR="$KEEP_STATE"
run_install --dry-run 0
assert_rc 0 "dry-run with a stale keep-clocks marker exits 0"
if [ -e "$KEEP_STATE/keep-clocks" ]; then
  ok "dry-run does not remove the keep-clocks marker"
else
  bad "dry-run does not remove the keep-clocks marker"
fi
assert_not_contains "$OUT" "cleared stale keep-clocks marker" "dry-run does not claim to clear the marker"
unset STATE_DIR

# --- source tree trust check (#23) -----------------------------------------
make_tree() {
  local dir="$1"
  mkdir -p "$dir"
  cp -p "$ROOT_DIR/install.sh" "$ROOT_DIR/nvidia-idle-clock" \
    "$ROOT_DIR/nvidia-idle-clock@.service" "$dir/"
}

TREE_OK="$WORK/tree-ok"
make_tree "$TREE_OK"
chmod -R go-w "$TREE_OK"
reset_shim_log
_run "$TREE_OK/install.sh" --dry-run 0
assert_rc 0 "clean user-owned tree is accepted"

TREE_WORLD="$WORK/tree-world"
make_tree "$TREE_WORLD"
chmod -R go-w "$TREE_WORLD"
chmod o+w "$TREE_WORLD/nvidia-idle-clock"
reset_shim_log
_run "$TREE_WORLD/install.sh" --dry-run 0
assert_rc 1 "world-writable daemon file is refused"
assert_contains "$ERR" "refusing to install from an untrusted source tree" "refusal is explained"
assert_contains "$ERR" "writable by every user" "refusal names the permission"
assert_not_contains "$(shim_log)" "install " "refused tree writes nothing"

reset_shim_log
_run "$TREE_WORLD/install.sh" --force --dry-run 0
assert_rc 0 "--force overrides the trust check"
assert_contains "$ERR" "overridden by --force" "--force override is reported"

TREE_DIR="$WORK/tree-world-dir"
make_tree "$TREE_DIR"
chmod -R go-w "$TREE_DIR"
chmod o+w "$TREE_DIR"
reset_shim_log
_run "$TREE_DIR/install.sh" --dry-run 0
assert_rc 1 "world-writable source directory is refused"

# A symlinked payload would let somebody point the root-installed file at an
# arbitrary path.
TREE_LINK="$WORK/tree-link"
make_tree "$TREE_LINK"
chmod -R go-w "$TREE_LINK"
mv "$TREE_LINK/nvidia-idle-clock" "$TREE_LINK/nvidia-idle-clock.real"
ln -s nvidia-idle-clock.real "$TREE_LINK/nvidia-idle-clock"
reset_shim_log
_run "$TREE_LINK/install.sh" --dry-run 0
assert_rc 1 "symlinked payload is refused"
assert_contains "$ERR" "not a regular file" "symlinked payload is explained"

# A checkout below a world-writable, non-sticky directory can be replaced as a
# whole, so the parent chain is checked too.
PUB="$WORK/pub"
mkdir -p "$PUB/tree"
chmod 0777 "$PUB"
cp -p "$ROOT_DIR/install.sh" "$ROOT_DIR/nvidia-idle-clock" \
  "$ROOT_DIR/nvidia-idle-clock@.service" "$PUB/tree/"
chmod -R go-w "$PUB/tree"
reset_shim_log
_run "$PUB/tree/install.sh" --dry-run 0
assert_rc 1 "checkout in a world-writable parent is refused"
assert_contains "$ERR" "parent directory" "world-writable parent is explained"
assert_contains "$ERR" "not sticky" "sticky exception is explained"

# Group writable through a shared (non-primary) group is refused too.
TREE_GROUP="$WORK/tree-group"
make_tree "$TREE_GROUP"
chmod -R go-w "$TREE_GROUP"
if chgrp users "$TREE_GROUP/nvidia-idle-clock" 2>/dev/null; then
  chmod g+w "$TREE_GROUP/nvidia-idle-clock"
  reset_shim_log
  _run "$TREE_GROUP/install.sh" --dry-run 0
  assert_rc 1 "group-writable file in a shared group is refused"
  assert_contains "$ERR" "group writable" "shared group refusal is explained"
else
  skip "group-writable file in a shared group is refused" "chgrp to a shared group not permitted"
fi

printf '\n== uninstall.sh: options and dry-run ==\n'
reset_shim_log
run_uninstall --help
assert_rc 0 "uninstall --help exits 0"
assert_contains "$OUT" "usage:" "uninstall --help prints usage"
assert_contains "$OUT" "--keep-clocks" "uninstall --help documents --keep-clocks"

reset_shim_log
run_uninstall --nope
assert_rc 2 "uninstall rejects unknown options"
assert_not_contains "$(shim_log)" "systemctl disable" "uninstall with unknown option does nothing"

reset_shim_log
run_uninstall unexpected-arg
assert_rc 2 "uninstall rejects positional arguments"

reset_shim_log
export FAKE_UNITS="nvidia-idle-clock@0.service"
run_uninstall --keep-clocks --dry-run
unset FAKE_UNITS
assert_rc 0 "uninstall --dry-run exits 0"
assert_contains "$OUT" "would disable" "uninstall --dry-run prints the stop plan"
assert_contains "$OUT" "clock locks kept" "uninstall --dry-run honours --keep-clocks"
assert_contains "$OUT" "dry-run: nothing was changed" "uninstall --dry-run writes nothing"
LOG="$(shim_log)"
assert_not_contains "$LOG" "disable --now" "uninstall --dry-run does not disable units"
assert_not_contains "$LOG" "-rgc" "uninstall --dry-run does not release clocks"

reset_shim_log
export FAKE_UNITS="nvidia-idle-clock@0.service"
run_uninstall --dry-run
unset FAKE_UNITS
assert_rc 0 "uninstall --dry-run without --keep-clocks exits 0"
assert_contains "$OUT" "would release clock lock" "uninstall --dry-run plans the clock release"
assert_not_contains "$(shim_log)" "-rgc" "uninstall --dry-run does not release clocks"

if [ "$(id -u)" -ne 0 ]; then
  reset_shim_log
  run_uninstall
  assert_rc 1 "non-root uninstall is refused"
  assert_contains "$ERR" "root privileges" "non-root uninstall is explained"
else
  skip "non-root uninstall is refused" "tests run as root"
fi

# --- root-only tests in a bwrap user namespace -----------------------------
if [ "$BWRAP_OK" -ne 1 ]; then
  for name in \
    "upgrade backs up and restarts" \
    "failed install rolls back" \
    "failed install restores the previous file" \
    "failed restart does not roll back" \
    "unchanged payload does not restart" \
    "rollback leaves a pre-existing instance alone" \
    "rollback undoes only the new enable" \
    "rollback restores a legacy unit left enabled and active" \
    "rollback does not claim a restore it could not verify" \
    "install clears a stale keep-clocks marker" \
    "uninstall removes files and releases clocks" \
    "uninstall --dry-run plans the removal" \
    "uninstall fails when -rgc fails" \
    "uninstall --keep-clocks skips -rgc" \
    "uninstall --keep-clocks writes the marker before the stop" \
    "uninstall --keep-clocks failure removes the marker" \
    "uninstall without --keep-clocks writes no marker" \
    "uninstall aborts when a unit cannot be stopped"; do
    skip "$name" "bwrap user namespace not available"
  done
else
  printf '\n== install.sh: upgrade, backup, rollback (bwrap sandbox) ==\n'

  # #22: replacing a different file keeps a backup, restarts the instance that
  # was already active, and prints the installed hash.
  new_sandbox upgrade
  printf '#!/bin/sh\n# old version\nexit 0\n' >"$SB/usr_local_sbin/nvidia-idle-clock"
  chmod 0755 "$SB/usr_local_sbin/nvidia-idle-clock"
  printf '[Unit]\nDescription=old unit\n' >"$SB/etc_systemd/nvidia-idle-clock@.service"
  # Leftover of the pre-template (non-instantiated) installation.
  printf '[Unit]\nDescription=legacy unit\n' >"$SB/etc_systemd/nvidia-idle-clock.service"
  write_inner_install "$SB/out/inner.sh" "0 1" \
    'export FAKE_ACTIVE_UNITS="nvidia-idle-clock@0.service"'
  run_in_sandbox "$SB" "$SB/out/inner.sh"
  LOG="$(bwrap_log)"
  assert_rc 0 "install in sandbox exits 0"
  assert_contains "$OUT" "backed up existing file" "existing daemon is backed up"
  assert_contains "$OUT" "restarted to load the new code" "already-active instance is restarted"
  assert_contains "$OUT" "install complete" "install reports completion"
  assert_contains "$OUT" "version=0.2.4 sha256=" "install prints the installed version and hash"
  assert_equal "$(backup_count "$SB/usr_local_sbin")" "1" "exactly one daemon backup exists"
  assert_equal "$(first_line "$(backup_path "$SB/usr_local_sbin")")" "#!/bin/sh" "backup keeps the old content"
  assert_equal "$(first_line "$SB/usr_local_sbin/nvidia-idle-clock")" "#!/usr/bin/env bash" "new daemon is installed"
  assert_equal "$(file_mode "$SB/usr_local_sbin/nvidia-idle-clock")" "755" "installed daemon is mode 0755"
  assert_contains "$OUT" "INSTALLED_OWNER=0:0" "installed daemon is owned by root:root"
  assert_contains "$OUT" "INSTALLED_MODE=755" "installed daemon mode is verified inside the sandbox"
  assert_contains "$OUT" "UNIT_OWNER=0:0" "installed unit is owned by root:root"
  assert_contains "$LOG" "systemctl enable --now nvidia-idle-clock@0.service" "GPU 0 is enabled"
  assert_contains "$LOG" "systemctl enable --now nvidia-idle-clock@1.service" "GPU 1 is enabled"
  assert_contains "$LOG" "systemctl try-restart nvidia-idle-clock@0.service" "active GPU 0 is try-restarted"
  assert_not_contains "$LOG" "systemctl try-restart nvidia-idle-clock@1.service" "inactive GPU 1 is not restarted"
  assert_contains "$LOG" "systemctl daemon-reload" "daemon-reload is called"
  assert_contains "$LOG" "systemctl disable --now nvidia-idle-clock.service" "legacy non-template unit is stopped"
  if [ -e "$SB/etc_systemd/nvidia-idle-clock.service" ]; then
    bad "legacy non-template unit is removed"
  else
    ok "legacy non-template unit is removed"
  fi
  assert_equal "$(glob_count "$SB/etc_systemd" 'nvidia-idle-clock.service.bak.*')" "1" \
    "legacy unit is backed up before removal"

  # #13: a failing enable must disable what was already enabled and remove the
  # files this run created.
  new_sandbox rollback
  write_inner_install "$SB/out/inner.sh" "0 1" \
    'export FAKE_ENABLE_FAIL_UNIT="nvidia-idle-clock@1.service"'
  run_in_sandbox "$SB" "$SB/out/inner.sh"
  LOG="$(bwrap_log)"
  assert_nonzero_rc "failed enable makes the install fail"
  assert_contains "$ERR" "rolling back" "rollback is announced"
  assert_contains "$LOG" "systemctl disable --now nvidia-idle-clock@0.service" "rollback disables the first unit"
  assert_contains "$ERR" "rollback finished" "rollback reports completion"
  assert_not_contains "$OUT" "install complete" "a failed install does not report success"
  if [ -e "$SB/usr_local_sbin/nvidia-idle-clock" ]; then
    bad "rollback removes the newly created daemon"
  else
    ok "rollback removes the newly created daemon"
  fi
  if [ -e "$SB/etc_systemd/nvidia-idle-clock@.service" ]; then
    bad "rollback removes the newly created unit"
  else
    ok "rollback removes the newly created unit"
  fi

  # #46: GPU 0 already ran before the install (enabled and active). A failed
  # enable of GPU 1 must not stop or disable that healthy instance.
  new_sandbox rollback-preexisting
  write_inner_install "$SB/out/inner.sh" "0 1" \
    'export FAKE_ACTIVE_UNITS="nvidia-idle-clock@0.service"
export FAKE_ENABLED_UNITS="nvidia-idle-clock@0.service"
export FAKE_ENABLE_FAIL_UNIT="nvidia-idle-clock@1.service"'
  run_in_sandbox "$SB" "$SB/out/inner.sh"
  LOG="$(bwrap_log)"
  assert_nonzero_rc "failed enable with a pre-existing instance exits non-zero"
  assert_contains "$ERR" "rolling back" "rollback with a pre-existing instance is announced"
  assert_not_contains "$LOG" "systemctl disable --now nvidia-idle-clock@0.service" \
    "rollback does not disable --now a pre-existing enabled+active unit"
  assert_not_contains "$LOG" "systemctl disable nvidia-idle-clock@0.service" \
    "rollback does not disable a pre-existing enabled unit"
  assert_not_contains "$LOG" "systemctl stop nvidia-idle-clock@0.service" \
    "rollback does not stop a pre-existing active unit"
  assert_contains "$LOG" "systemctl disable --now nvidia-idle-clock@1.service" \
    "rollback still cleans up the unit this run enabled"
  assert_contains "$OUT" "instances already active before this run" "the active state is captured first"
  assert_contains "$OUT" "instances already enabled before this run" "the enabled state is captured first"
  assert_contains "$ERR" "left unit alone" "rollback reports the pre-existing unit as untouched"
  assert_contains "$ERR" "rollback finished" "rollback with a pre-existing instance reports completion"

  # #46: a unit that was active but not enabled must keep running after the
  # rollback; only the enable this run added is undone.
  new_sandbox rollback-active-only
  write_inner_install "$SB/out/inner.sh" "0 1" \
    'export FAKE_ACTIVE_UNITS="nvidia-idle-clock@0.service"
export FAKE_ENABLE_FAIL_UNIT="nvidia-idle-clock@1.service"'
  run_in_sandbox "$SB" "$SB/out/inner.sh"
  LOG="$(bwrap_log)"
  assert_nonzero_rc "failed enable with an active-only instance exits non-zero"
  assert_contains "$LOG" "systemctl disable nvidia-idle-clock@0.service" \
    "rollback undoes the enable of an active-only unit"
  assert_not_contains "$LOG" "systemctl stop nvidia-idle-clock@0.service" \
    "rollback does not stop an active-only unit"
  assert_not_contains "$LOG" "disable --now nvidia-idle-clock@0.service" \
    "rollback does not stop an active-only unit with --now"
  assert_contains "$ERR" "left the running instance alone" "rollback explains that the instance was left running"

  # #55: a legacy non-template unit that was enabled and active before the run
  # was stopped and disabled by the install. A later failure must restore that
  # state, not just the file.
  new_sandbox rollback-legacy
  printf '[Unit]\nDescription=legacy unit\n' >"$SB/etc_systemd/nvidia-idle-clock.service"
  mkdir -p "$SB/state/enabled" "$SB/state/active"
  : >"$SB/state/enabled/nvidia-idle-clock.service"
  : >"$SB/state/active/nvidia-idle-clock.service"
  write_inner_install "$SB/out/inner.sh" "0" \
    "export SHIM_STATE_DIR='$SB/state'
export FAKE_ENABLE_FAIL_UNIT='nvidia-idle-clock@0.service'"
  run_in_sandbox "$SB" "$SB/out/inner.sh"
  LOG="$(bwrap_log)"
  assert_nonzero_rc "failed enable after disabling the legacy unit exits non-zero"
  assert_contains "$OUT" "legacy unit state captured before this run" "the legacy unit state is snapshotted"
  assert_contains "$LOG" "systemctl disable --now nvidia-idle-clock.service" \
    "the install disables the legacy unit"
  assert_contains "$LOG" "systemctl enable nvidia-idle-clock.service" \
    "rollback re-enables the legacy unit"
  assert_contains "$LOG" "systemctl start nvidia-idle-clock.service" \
    "rollback restarts the legacy unit"
  assert_contains "$ERR" "re-enabled the legacy unit" "the legacy re-enable is reported"
  assert_contains "$ERR" "restarted the legacy unit" "the legacy restart is reported"
  assert_contains "$ERR" "previous state was restored" "rollback reports the restored state"
  assert_not_contains "$ERR" "could not restore" "rollback reports no failed restoration"
  if [ -e "$SB/etc_systemd/nvidia-idle-clock.service" ]; then
    ok "rollback restores the legacy unit file"
  else
    bad "rollback restores the legacy unit file"
  fi
  if [ -e "$SB/state/enabled/nvidia-idle-clock.service" ] \
    && [ -e "$SB/state/active/nvidia-idle-clock.service" ]; then
    ok "the legacy unit ends enabled and active"
  else
    bad "the legacy unit ends enabled and active"
  fi

  # #55: when a snapshotted unit cannot actually be restored, rollback must
  # name it and must not print that the previous state was restored.
  new_sandbox rollback-legacy-unrestored
  printf '[Unit]\nDescription=legacy unit\n' >"$SB/etc_systemd/nvidia-idle-clock.service"
  mkdir -p "$SB/state/enabled" "$SB/state/active"
  : >"$SB/state/enabled/nvidia-idle-clock.service"
  : >"$SB/state/active/nvidia-idle-clock.service"
  write_inner_install "$SB/out/inner.sh" "0" \
    "export SHIM_STATE_DIR='$SB/state'
export FAKE_ENABLE_FAIL_UNIT='nvidia-idle-clock@0.service'
export FAKE_START_FAIL_UNIT='nvidia-idle-clock.service'"
  run_in_sandbox "$SB" "$SB/out/inner.sh"
  LOG="$(bwrap_log)"
  assert_nonzero_rc "a rollback that cannot restart the legacy unit exits non-zero"
  assert_contains "$LOG" "systemctl enable nvidia-idle-clock.service" \
    "rollback still tries to re-enable the legacy unit"
  assert_contains "$ERR" "could not restart the legacy unit" "the failed legacy restart is reported"
  assert_contains "$ERR" "could not restore the active state" \
    "rollback names the state it could not restore"
  assert_contains "$ERR" "rollback could not restore the previous state" \
    "rollback reports that the restore was incomplete"
  assert_not_contains "$ERR" "previous state was restored" \
    "rollback does not lie about the restored state"
  if [ -e "$SB/state/active/nvidia-idle-clock.service" ]; then
    bad "a failed legacy restart is not reported as active"
  else
    ok "a failed legacy restart is not reported as active"
  fi

  # #13: a replaced file must be restored when a later step fails.
  new_sandbox rollback-restore
  printf '#!/bin/sh\n# old version\nexit 0\n' >"$SB/usr_local_sbin/nvidia-idle-clock"
  chmod 0755 "$SB/usr_local_sbin/nvidia-idle-clock"
  write_inner_install "$SB/out/inner.sh" "0 1" \
    'export FAKE_ENABLE_FAIL_UNIT="nvidia-idle-clock@1.service"'
  run_in_sandbox "$SB" "$SB/out/inner.sh"
  assert_nonzero_rc "failed enable after an upgrade exits non-zero"
  assert_equal "$(first_line "$SB/usr_local_sbin/nvidia-idle-clock")" "#!/bin/sh" \
    "rollback restores the previous daemon"
  assert_equal "$(glob_count "$SB/usr_local_sbin" 'nvidia-idle-clock.bak.*')" "0" \
    "rollback removes the backup it restored from"

  # #22: a failed restart must be reported without undoing the installation.
  new_sandbox restart-fail
  printf '#!/bin/sh\n# old version\nexit 0\n' >"$SB/usr_local_sbin/nvidia-idle-clock"
  chmod 0755 "$SB/usr_local_sbin/nvidia-idle-clock"
  write_inner_install "$SB/out/inner.sh" "0" \
    'export FAKE_ACTIVE_UNITS="nvidia-idle-clock@0.service"
export FAKE_RESTART_FAIL_UNIT="nvidia-idle-clock@0.service"'
  run_in_sandbox "$SB" "$SB/out/inner.sh"
  LOG="$(bwrap_log)"
  assert_nonzero_rc "failed try-restart makes the install fail"
  assert_contains "$ERR" "still running the old code" "failed try-restart is reported"
  assert_contains "$OUT" "install finished but a restart failed" "failed try-restart changes the summary"
  assert_equal "$(first_line "$SB/usr_local_sbin/nvidia-idle-clock")" "#!/usr/bin/env bash" \
    "failed try-restart keeps the new daemon installed"
  assert_not_contains "$LOG" "systemctl disable --now" "failed try-restart does not roll back"

  # #22: with an identical payload there is nothing to restart.
  new_sandbox unchanged
  cp -p "$ROOT_DIR/nvidia-idle-clock" "$SB/usr_local_sbin/nvidia-idle-clock"
  cp -p "$ROOT_DIR/nvidia-idle-clock@.service" "$SB/etc_systemd/nvidia-idle-clock@.service"
  write_inner_install "$SB/out/inner.sh" "0" \
    'export FAKE_ACTIVE_UNITS="nvidia-idle-clock@0.service"'
  run_in_sandbox "$SB" "$SB/out/inner.sh"
  LOG="$(bwrap_log)"
  assert_rc 0 "reinstall with identical payload exits 0"
  assert_contains "$OUT" "payload unchanged" "identical payload is reported as unchanged"
  assert_not_contains "$LOG" "try-restart" "identical payload does not restart the instance"

  # #48: "uninstall.sh --keep-clocks" leaves a marker for the current boot.
  # A successful install must clear it before enabling the units, otherwise
  # the new daemon would honour it forever; nothing else in the state
  # directory may be touched.
  new_sandbox keep-clocks-stale
  mkdir -p "$SB/state"
  : >"$SB/state/keep-clocks"
  : >"$SB/state/unrelated"
  write_inner_install "$SB/out/inner.sh" "0" \
    "export STATE_DIR='$SB/state'"
  run_in_sandbox "$SB" "$SB/out/inner.sh"
  LOG="$(bwrap_log)"
  assert_rc 0 "install with a stale keep-clocks marker exits 0"
  assert_contains "$OUT" "cleared stale keep-clocks marker" "the stale keep-clocks marker is cleared"
  assert_contains "$OUT" "install complete" "the install still completes"
  assert_contains "$LOG" "systemctl enable --now nvidia-idle-clock@0.service" \
    "the units are enabled after the marker is cleared"
  if [ -e "$SB/state/keep-clocks" ]; then
    bad "the keep-clocks marker is gone after a successful install"
  else
    ok "the keep-clocks marker is gone after a successful install"
  fi
  if [ -e "$SB/state/unrelated" ]; then
    ok "the rest of the state directory is left alone"
  else
    bad "the rest of the state directory is left alone"
  fi

  printf '\n== uninstall.sh: removal and clock release (bwrap sandbox) ==\n'

  new_sandbox uninstall
  printf '#!/usr/bin/env bash\nexit 0\n' >"$SB/usr_local_sbin/nvidia-idle-clock"
  printf '[Unit]\nDescription=unit\n' >"$SB/etc_systemd/nvidia-idle-clock@.service"
  dropin_dirs "$SB"
  write_inner_uninstall "$SB/out/inner.sh" "" 'export FAKE_UNITS="nvidia-idle-clock@0.service"'
  run_in_sandbox "$SB" "$SB/out/inner.sh"
  LOG="$(bwrap_log)"
  assert_rc 0 "uninstall in sandbox exits 0"
  assert_contains "$OUT" "uninstall complete" "uninstall reports success"
  assert_contains "$LOG" "systemctl disable --now nvidia-idle-clock@0.service" "instance is stopped"
  assert_contains "$LOG" "systemctl daemon-reload" "daemon-reload is called"
  assert_contains "$LOG" "nvidia-smi -i 0 -rgc" "clock lock of GPU 0 is released"
  assert_contains "$LOG" "nvidia-smi -i 1 -rgc" "clock lock of GPU 1 is released"
  assert_contains "$OUT" "verified removal" "removal is verified"
  for name in nvidia-idle-clock nvidia-idle-clock@.service \
              nvidia-idle-clock@.service.d nvidia-idle-clock@0.service.d; do
    if [ -e "$SB/usr_local_sbin/$name" ] || [ -e "$SB/etc_systemd/$name" ]; then
      bad "uninstall removes $name"
    else
      ok "uninstall removes $name"
    fi
  done

  # The drop-ins of an installed instance must be planned and removed too.
  new_sandbox uninstall-dry
  printf '#!/usr/bin/env bash\nexit 0\n' >"$SB/usr_local_sbin/nvidia-idle-clock"
  dropin_dirs "$SB"
  write_inner_uninstall "$SB/out/inner.sh" "--dry-run" 'export FAKE_UNITS="nvidia-idle-clock@0.service"'
  run_in_sandbox "$SB" "$SB/out/inner.sh"
  assert_rc 0 "uninstall --dry-run in sandbox exits 0"
  assert_contains "$OUT" "would remove" "uninstall --dry-run plans the removal"
  assert_contains "$OUT" 'would remove" path="/etc/systemd/system/nvidia-idle-clock@.service.d"' \
    "uninstall --dry-run plans the template drop-in removal"
  if [ -d "$SB/usr_local_sbin" ] && [ -f "$SB/usr_local_sbin/nvidia-idle-clock" ]; then
    ok "uninstall --dry-run removes nothing"
  else
    bad "uninstall --dry-run removes nothing"
  fi

  # #14: a failed -rgc must not be reported as "released".
  new_sandbox uninstall-rgc
  printf '#!/usr/bin/env bash\nexit 0\n' >"$SB/usr_local_sbin/nvidia-idle-clock"
  write_inner_uninstall "$SB/out/inner.sh" "" \
    'export FAKE_UNITS="nvidia-idle-clock@0.service"
export FAKE_RGC_RC=6'
  run_in_sandbox "$SB" "$SB/out/inner.sh"
  assert_nonzero_rc "failed -rgc makes the uninstall fail"
  assert_contains "$ERR" "could not release the clock lock" "failed -rgc is reported"
  assert_not_contains "$OUT" "uninstall complete" "failed -rgc does not claim success"
  assert_contains "$ERR" "uninstall incomplete" "failed -rgc is summarised"

  # #48: --keep-clocks must create the marker before the first stop, because
  # the daemon's shutdown and ExecStopPost --unlock release the clamp from
  # inside "systemctl disable --now". The shim records the marker state at
  # every disable call instead of running the real daemon.
  new_sandbox uninstall-keep
  printf '#!/usr/bin/env bash\nexit 0\n' >"$SB/usr_local_sbin/nvidia-idle-clock"
  write_inner_uninstall "$SB/out/inner.sh" "--keep-clocks" \
    'export FAKE_UNITS="nvidia-idle-clock@0.service"
export STATE_DIR="'"$SB"'/state"
export TEST_MARKER="'"$SB"'/state/keep-clocks"'
  run_in_sandbox "$SB" "$SB/out/inner.sh"
  LOG="$(bwrap_log)"
  assert_rc 0 "uninstall --keep-clocks exits 0"
  assert_contains "$OUT" "clock locks kept" "--keep-clocks reports the kept clocks"
  assert_contains "$OUT" "kept until reboot" "--keep-clocks says the limit lasts until reboot"
  assert_not_contains "$LOG" "-rgc" "--keep-clocks does not release clocks"
  assert_contains "$LOG" "marker=present before systemctl disable --now nvidia-idle-clock@0.service" \
    "the keep-clocks marker exists before the first disable --now"
  assert_equal "$(file_mode "$SB/state/keep-clocks")" "600" "the keep-clocks marker is mode 0600"
  assert_equal "$(file_mode "$SB/state")" "700" "the state directory is mode 0700"

  # #48: a failed run must remove the marker again, so a later stop behaves
  # normally instead of silently keeping a clamp nobody asked to keep.
  new_sandbox uninstall-keep-fail
  printf '#!/usr/bin/env bash\nexit 0\n' >"$SB/usr_local_sbin/nvidia-idle-clock"
  write_inner_uninstall "$SB/out/inner.sh" "--keep-clocks" \
    'export FAKE_UNITS="nvidia-idle-clock@0.service"
export FAKE_DISABLE_FAIL_UNIT="nvidia-idle-clock@0.service"
export STATE_DIR="'"$SB"'/state"
export TEST_MARKER="'"$SB"'/state/keep-clocks"'
  run_in_sandbox "$SB" "$SB/out/inner.sh"
  LOG="$(bwrap_log)"
  assert_nonzero_rc "failed stop with --keep-clocks exits non-zero"
  assert_contains "$LOG" "marker=present before systemctl disable --now nvidia-idle-clock@0.service" \
    "the marker exists before the stop that fails"
  if [ -e "$SB/state/keep-clocks" ]; then
    bad "a failed run removes the keep-clocks marker"
  else
    ok "a failed run removes the keep-clocks marker"
  fi
  assert_contains "$ERR" "removed the keep-clocks marker after a failed run" \
    "the marker removal after a failure is reported"

  # #48: without --keep-clocks nothing is created and the stop releases as usual.
  new_sandbox uninstall-no-keep
  printf '#!/usr/bin/env bash\nexit 0\n' >"$SB/usr_local_sbin/nvidia-idle-clock"
  write_inner_uninstall "$SB/out/inner.sh" "" \
    'export FAKE_UNITS="nvidia-idle-clock@0.service"
export STATE_DIR="'"$SB"'/state"
export TEST_MARKER="'"$SB"'/state/keep-clocks"'
  run_in_sandbox "$SB" "$SB/out/inner.sh"
  LOG="$(bwrap_log)"
  assert_rc 0 "uninstall without --keep-clocks exits 0"
  assert_contains "$LOG" "marker=absent before systemctl disable --now nvidia-idle-clock@0.service" \
    "the stop runs without a keep-clocks marker"
  if [ -e "$SB/state/keep-clocks" ]; then
    bad "no keep-clocks marker is created without --keep-clocks"
  else
    ok "no keep-clocks marker is created without --keep-clocks"
  fi

  # #14: if a unit cannot be stopped, the files must stay in place.
  new_sandbox uninstall-stop
  printf '#!/usr/bin/env bash\nexit 0\n' >"$SB/usr_local_sbin/nvidia-idle-clock"
  printf '[Unit]\nDescription=unit\n' >"$SB/etc_systemd/nvidia-idle-clock@.service"
  write_inner_uninstall "$SB/out/inner.sh" "" \
    'export FAKE_UNITS="nvidia-idle-clock@0.service"
export FAKE_DISABLE_FAIL_UNIT="nvidia-idle-clock@0.service"'
  run_in_sandbox "$SB" "$SB/out/inner.sh"
  assert_nonzero_rc "failed stop makes the uninstall fail"
  assert_contains "$ERR" "could not be stopped" "failed stop is explained"
  if [ -e "$SB/etc_systemd/nvidia-idle-clock@.service" ] && [ -e "$SB/usr_local_sbin/nvidia-idle-clock" ]; then
    ok "files are left in place when a unit cannot be stopped"
  else
    bad "files are left in place when a unit cannot be stopped"
  fi
fi

printf '\n%s: %d passed, %d failed, %d skipped\n' \
  "$(basename -- "$0")" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
