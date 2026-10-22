#!/usr/bin/env bash
# Tests for nvidia-idle-clock. No GPU, no root, no systemd.
#
#   bash tests/run.sh        # exit 0 = pass, 1 = at least one failure
#
# Every case gets its own directory holding the fake nvidia-smi state, the
# daemon's stdout and its stderr. The fake is described in tests/fake-nvidia-smi.
set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/.." && pwd)
SCRIPT="$REPO/nvidia-idle-clock"
FAKE="$HERE/fake-nvidia-smi"
BASH_BIN="${BASH:-/bin/bash}"
TIMEOUT_BIN=$(command -v timeout || true)
TIMEOUT_BIN="${TIMEOUT_BIN:-timeout}"

# Guard: this suite must never reach a real GPU. Every case either passes
# NVSMI=$FAKE or runs with a PATH that contains no nvidia-smi at all.
if [ ! -x "$FAKE" ]; then
  printf 'tests: %s is missing or not executable\n' "$FAKE" >&2
  exit 1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/nidc-test.XXXXXX")
CASE_DIR="$WORK"
OUT="$WORK/out.log"
ERR="$WORK/err.log"
ARGV="$WORK/state/argv.log"
RUN_PID=""
RUN_PGID=""
RUN_RC=0
PASS=0
FAIL=0
FAILED=()
SETSID_BIN=$(command -v setsid || true)

# True when PID is one of this suite's fake nvidia-smi processes: checked on
# argv[1], so a shell whose *command line* merely mentions the path never
# matches. Killing is limited to those, never to another worktree's processes.
is_our_fake_pid() { # pid
  local pid="$1" script=""
  [ -r "/proc/$pid/cmdline" ] || return 1
  script=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | sed -n '2p')
  [ "$script" = "$FAKE" ]
}

# Tear down whatever the previous case left behind: the daemon's process group
# (it runs under setsid) and, as a fallback, the stream child recorded by the
# fake. Called after the case's assertions, so a test can still prove that the
# daemon itself killed its child.
reap_case_processes() {
  local pid="" members=""
  if [ -n "${RUN_PGID:-}" ]; then
    # Only a group that still holds one of *our* processes is killed: a recycled
    # process group id must never hit another worktree's daemon.
    if command -v pgrep >/dev/null 2>&1; then
      members=$(pgrep -g "$RUN_PGID" -f -- "$FAKE" 2>/dev/null || true)
      if [ -z "$members" ]; then
        members=$(pgrep -g "$RUN_PGID" -f -- "${SCRIPT_UNDER_TEST:-$SCRIPT}" 2>/dev/null || true)
      fi
      if [ -n "$members" ]; then
        kill -KILL -- "-$RUN_PGID" 2>/dev/null || true
      fi
    else
      kill -KILL -- "-$RUN_PGID" 2>/dev/null || true
    fi
    RUN_PGID=""
  fi
  if [ -n "${RUN_PID:-}" ]; then
    if [ -r "/proc/$RUN_PID/cmdline" ] \
       && tr '\0' ' ' < "/proc/$RUN_PID/cmdline" 2>/dev/null \
          | grep -qF -- "${SCRIPT_UNDER_TEST:-$SCRIPT}"; then
      kill -KILL "$RUN_PID" 2>/dev/null || true
    fi
    RUN_PID=""
  fi
  if [ -n "${STATE:-}" ] && [ -f "$STATE/stream.pid" ]; then
    read -r pid < "$STATE/stream.pid" || pid=""
    if [ -n "$pid" ] && is_our_fake_pid "$pid"; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
}

suite_cleanup() {
  reap_case_processes
  # NIDC_KEEP=1 keeps the case directories for debugging a failure.
  if [ "${NIDC_KEEP:-0}" = "1" ]; then
    printf 'kept: %s\n' "$WORK"
    return
  fi
  rm -rf "$WORK"
}
trap suite_cleanup EXIT

pass() { PASS=$(( PASS + 1 )); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$(( FAIL + 1 )); FAILED+=("$1"); printf 'FAIL %s: %s\n' "$1" "$2"; }

assert_eq() { # name expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi
}
assert_rc() { # name expected actual
  if [ "$2" -eq "$3" ]; then pass "$1"; else fail "$1" "expected rc $2, got rc $3"; fi
}
assert_ge() { # name minimum actual
  if [ "$3" -ge "$2" ]; then pass "$1"; else fail "$1" "expected >= $2, got $3"; fi
}
grep_count() { # file fixed-string -> count on stdout
  local n
  n=$(grep -cF -- "$2" "$1" 2>/dev/null)
  printf '%s' "${n:-0}"
}
assert_has() { # name file fixed-string
  if grep -qF -- "$3" "$2" 2>/dev/null; then pass "$1"; else fail "$1" "no line matching [$3]"; fi
}
assert_lacks() { # name file fixed-string
  if grep -qF -- "$3" "$2" 2>/dev/null; then fail "$1" "unexpected line matching [$3]"; else pass "$1"; fi
}
assert_count() { # name file fixed-string expected
  local n
  n=$(grep_count "$2" "$3")
  if [ "$n" -eq "$4" ]; then pass "$1"; else fail "$1" "expected $4 line(s) matching [$3], got $n"; fi
}
assert_no_gpu_calls() { # name
  local n=0
  if [ -f "$ARGV" ]; then n=$(wc -l < "$ARGV"); fi
  if [ "$n" -eq 0 ]; then pass "$1"; else fail "$1" "nvidia-smi was called $n time(s)"; fi
}

new_case() { # name
  reap_case_processes
  CASE_DIR="$WORK/$1"
  STATE="$CASE_DIR/state"
  OUT="$CASE_DIR/out.log"
  ERR="$CASE_DIR/err.log"
  ARGV="$STATE/argv.log"
  mkdir -p "$STATE"
  : > "$OUT"
  : > "$ERR"
}

# Foreground run: always points NVSMI at the fake unless the case overrides it.
run_daemon() { # [NAME=VALUE ...]
  local rc=0 under_test="${SCRIPT_UNDER_TEST:-$SCRIPT}"
  env NVSMI="$FAKE" FAKE_STATE="$STATE" "$@" \
    "$TIMEOUT_BIN" 10 "$BASH_BIN" "$under_test" >>"$OUT" 2>>"$ERR" || rc=$?
  RUN_RC=$rc
}

# Background run, used when the case has to send SIGTERM. The daemon gets its
# own process group (setsid) so the suite can reap it together with its
# utilization-stream child instead of leaking that child into the user session.
start_daemon() { # [NAME=VALUE ...]
  local under_test="${SCRIPT_UNDER_TEST:-$SCRIPT}"
  RUN_PID=""
  RUN_PGID=""
  if [ -n "$SETSID_BIN" ]; then
    env NVSMI="$FAKE" FAKE_STATE="$STATE" "$@" \
      "$SETSID_BIN" "$BASH_BIN" "$under_test" >>"$OUT" 2>>"$ERR" &
    RUN_PID=$!
    # setsid() and exec in one step: the daemon is a session leader, so its PID
    # is also the process group to reap.
    RUN_PGID=$RUN_PID
  else
    env NVSMI="$FAKE" FAKE_STATE="$STATE" "$@" \
      "$BASH_BIN" "$under_test" >>"$OUT" 2>>"$ERR" &
    RUN_PID=$!
  fi
}

# Background watchdog for one daemon: if the daemon has not exited after 10 s,
# kill its whole process group. It only ever touches the PID/PGID it was started
# with, it re-checks the command line (so a recycled PID is never killed), and
# the flag file disarms it when the daemon exited on its own.
watchdog_kill() { # daemon-pid pgid flag script
  local i=0
  while [ ! -e "$3" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$(( i + 1 ))
  done
  if [ -e "$3" ] || [ ! -r "/proc/$1/cmdline" ]; then return 0; fi
  if ! tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -qF -- "$4"; then
    return 0
  fi
  if [ -n "$2" ]; then
    kill -KILL -- "-$2" 2>/dev/null || true
  else
    kill -KILL "$1" 2>/dev/null || true
  fi
}

stop_daemon() { # seconds to run before SIGTERM
  local watchdog rc=0 flag="$CASE_DIR/watchdog.disarm"
  local target="${SCRIPT_UNDER_TEST:-$SCRIPT}"
  sleep "$1"
  rm -f "$flag"
  watchdog_kill "$RUN_PID" "$RUN_PGID" "$flag" "$target" &
  watchdog=$!
  kill -TERM "$RUN_PID" 2>/dev/null
  wait "$RUN_PID" || rc=$?
  # Disarm before killing the watchdog: whether the TERM is delivered promptly
  # or late, a surviving watchdog can no longer touch anything.
  : > "$flag"
  kill -TERM "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  RUN_RC=$rc
  RUN_PID=""
  # RUN_PGID is kept: the next new_case reaps a stream child that the daemon
  # failed to kill, after this case has had the chance to assert on it.
}

# PATH containing everything the daemon and the fake need, and nothing else. Used
# to prove that stdbuf is optional (issue #24) and that nvidia-smi is resolved
# from PATH (issue #15).
make_shim() { # dir [extra symlink name:target ...]
  local dir="$1" t pair
  shift
  mkdir -p "$dir"
  for t in bash env sleep date mktemp rm; do
    if ln -sf "$(command -v "$t")" "$dir/$t" 2>/dev/null; then :; fi
  done
  for pair in "$@"; do
    ln -sf "${pair#*:}" "$dir/${pair%%:*}"
  done
}

# Poll until $1 holds at least $3 lines matching $2, for at most $4 tenths of a
# second. Used where a fixed sleep would have to guess how long a reconnect
# takes (#19, #5).
wait_for_count() { # file fixed-string expected tenths
  local i=0
  while [ "$i" -lt "$4" ]; do
    if [ "$(grep_count "$1" "$2")" -ge "$3" ]; then return 0; fi
    sleep 0.1
    i=$(( i + 1 ))
  done
  return 1
}

# The utilization stream child must not outlive the daemon (issue #7). The fake
# records its own PID on every stream start. Polled, because after a SIGKILL the
# child can only notice that its reader vanished on the next write.
assert_stream_child_gone() { # name pidfile
  local pid="" i=0
  if [ -f "$2" ]; then read -r pid < "$2" || pid=""; fi
  if [ -z "$pid" ]; then
    fail "$1" "no stream pid was recorded in $2"
    return
  fi
  while [ "$i" -lt 20 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then pass "$1"; return; fi
    sleep 0.1
    i=$(( i + 1 ))
  done
  fail "$1" "the utilization stream child (pid $pid) is still alive"
}

# nvidia-smi stand-in that records every argument quoted, so one call with a
# space-joined GPU list ([0 1]) can be told apart from two per-GPU calls
# (issue #5). The real fake is exec'd afterwards, so behaviour is unchanged.
make_argv_wrapper() { # directory -> path on stdout
  local dir="$1" wrapper="$1/nvidia-smi-argv"
  mkdir -p "$dir"
  cat > "$wrapper" <<'WRAPPER'
#!/usr/bin/env bash
printf 'call' >> "$FAKE_ARGV_QUOTED"
for a in "$@"; do printf ' [%s]' "$a" >> "$FAKE_ARGV_QUOTED"; done
printf '\n' >> "$FAKE_ARGV_QUOTED"
exec "$FAKE_REAL" "$@"
WRAPPER
  chmod +x "$wrapper"
  printf '%s' "$wrapper"
}

# Copy of the daemon with a fast reconnect backoff, so the bounded-attempt path
# of issue #7 can be reached inside the test budget.
make_retry_copy() { # destination
  sed -e 's/^RETRY_MIN_S=2$/RETRY_MIN_S=1/' -e 's/^RETRY_MAX_S=30$/RETRY_MAX_S=1/' \
    "$SCRIPT" > "$1"
  chmod +x "$1"
  if ! grep -q '^RETRY_MIN_S=1$' "$1"; then
    printf 'tests: could not build the fast-retry copy\n' >&2
  fi
}

# Copy of the daemon with one line injected into the main loop, so the "a fatal
# error must not be reported as success" path can be exercised (#4).
make_fatal_copy() { # destination
  local dest="$1" line
  : > "$dest"
  while IFS= read -r line; do
    printf '%s\n' "$line" >> "$dest"
    if [ "$line" = "while :; do" ]; then
      printf '  : "$(( 0 + ${FAKE_FATAL_SENTINEL} ))"\n' >> "$dest"
    fi
  done < "$SCRIPT"
  chmod +x "$dest"
}

# --- #3: numeric / boolean environment values are validated -----------------
case_config_util_threshold() {
  new_case cfg-util-threshold
  run_daemon UTIL_THRESHOLD=10%
  assert_rc "invalid UTIL_THRESHOLD exits 2" 2 "$RUN_RC"
  assert_has "invalid UTIL_THRESHOLD is logged" "$OUT" 'msg="invalid config" var=UTIL_THRESHOLD'
  assert_no_gpu_calls "invalid config never runs nvidia-smi"
}

case_config_gpu_glob() {
  local here
  new_case cfg-gpu-glob
  here=$(pwd)
  cd "$REPO" || return
  run_daemon GPU='*'                       # would glob to the repo files before #3
  cd "$here" || return
  assert_rc "GPU='*' exits 2" 2 "$RUN_RC"
  assert_has "GPU='*' is rejected as a config error" "$OUT" 'msg="invalid config" var=GPU'
  assert_lacks "GPU='*' is not expanded to file names" "$OUT" 'README'
  assert_no_gpu_calls "GPU='*' never runs nvidia-smi"
}

case_config_gpu_mixed() {
  new_case cfg-gpu-mixed
  run_daemon GPU=0,abc
  assert_rc "GPU=0,abc exits 2" 2 "$RUN_RC"
  assert_has "the bad GPU element is named" "$OUT" "element 'abc'"
  assert_no_gpu_calls "a bad GPU element never runs nvidia-smi"
}

case_config_seconds_suffix() {
  new_case cfg-seconds
  run_daemon IDLE_SECONDS=30s
  assert_rc "IDLE_SECONDS=30s exits 2" 2 "$RUN_RC"
  assert_has "IDLE_SECONDS=30s is rejected" "$OUT" 'msg="invalid config" var=IDLE_SECONDS'
  assert_no_gpu_calls "IDLE_SECONDS=30s never runs nvidia-smi"
}

case_config_sample_ms() {
  new_case cfg-sample
  run_daemon SAMPLE_MS=10
  assert_rc "SAMPLE_MS=10 exits 2" 2 "$RUN_RC"
  assert_has "SAMPLE_MS=10 is out of range" "$OUT" "out of range 50..60000"
  assert_no_gpu_calls "SAMPLE_MS=10 never runs nvidia-smi"
}

case_config_skip_if_low() {
  new_case cfg-skip
  run_daemon SKIP_IF_LOW=yes
  assert_rc "SKIP_IF_LOW=yes exits 2" 2 "$RUN_RC"
  assert_has "SKIP_IF_LOW=yes is rejected" "$OUT" 'msg="invalid config" var=SKIP_IF_LOW'
}

case_config_range_order() {
  new_case cfg-range
  run_daemon MIN_CLK=200 IDLE_CAP=135
  assert_rc "MIN_CLK > IDLE_CAP exits 2" 2 "$RUN_RC"
  assert_has "MIN_CLK > IDLE_CAP explains itself" "$OUT" 'var=MIN_CLK'
  assert_has "MIN_CLK > IDLE_CAP names IDLE_CAP" "$OUT" "must not be greater than IDLE_CAP (135)"
  assert_no_gpu_calls "MIN_CLK > IDLE_CAP never runs nvidia-smi"
}

case_config_cap_above_max() {
  new_case cfg-cap-max
  run_daemon IDLE_CAP=2000
  assert_rc "IDLE_CAP above clocks.max.gr exits 2" 2 "$RUN_RC"
  assert_has "the clock cap is checked against clocks.max.gr" "$OUT" \
    "exceeds clocks.max.gr (1380) of gpu 0"
  assert_count "clocks.max.gr is queried once" "$ARGV" '--query-gpu=clocks.max.gr' 1
  assert_lacks "a rejected configuration never clamps" "$ARGV" ' -lgc '
}

case_config_cap_nonnumeric() {
  new_case cfg-cap-numeric
  run_daemon IDLE_CAP=abc
  assert_rc "IDLE_CAP=abc exits 2" 2 "$RUN_RC"
  assert_has "IDLE_CAP=abc is rejected as non-numeric" "$OUT" "not a non-negative integer"
  assert_no_gpu_calls "IDLE_CAP=abc never runs nvidia-smi"
}

# --- #15: nvidia-smi is discoverable ---------------------------------------
case_nvsmi_missing() {
  local shim="$WORK/shim-no-nvsmi"
  new_case nvsmi-missing
  make_shim "$shim"
  run_daemon NVSMI=/nonexistent/nvidia-smi PATH="$shim"
  assert_rc "an unusable NVSMI exits 1" 1 "$RUN_RC"
  assert_has "the missing binary is reported" "$OUT" 'msg="nvidia-smi not found"'
  assert_has "the missing path is reported" "$OUT" 'nvidia_smi=/nonexistent/nvidia-smi'
  assert_has "the error suggests NVSMI" "$OUT" 'hint="set NVSMI='
  assert_no_gpu_calls "a missing nvidia-smi never runs anything"
}

case_nvsmi_from_path() {
  local shim="$WORK/shim-with-nvsmi"
  new_case nvsmi-path
  make_shim "$shim" "nvidia-smi:$FAKE"
  # NVSMI is deliberately unset: resolution has to come from PATH.
  env -u NVSMI FAKE_STATE="$STATE" PATH="$shim" \
    "$BASH_BIN" "$SCRIPT" >>"$OUT" 2>>"$ERR" &
  RUN_PID=$!
  stop_daemon 0.8
  assert_rc "nvidia-smi found on PATH starts the daemon" 0 "$RUN_RC"
  assert_has "the resolved path is logged" "$OUT" "nvidia_smi=$shim/nvidia-smi"
  assert_has "the daemon reached its start line" "$OUT" 'msg="started"'
}

# --- #1 / #29: a clamp is only claimed after a verified read-back -----------
case_clamp_verified() {
  new_case clamp-verified
  start_daemon IDLE_SECONDS=0 SAMPLE_MS=50 SKIP_IF_LOW=1
  stop_daemon 1.2
  assert_rc "a stopped daemon exits 0" 0 "$RUN_RC"
  assert_has "the clamp is verified by reading the clock back" "$OUT" 'msg="clamp verified"'
  assert_has "the clamp log reports the clock before the clamp" "$OUT" 'was_mhz=1260'
  assert_has "the clamp log reports the clock after the clamp" "$OUT" 'observed_mhz=135'
  assert_count "the verified clamp happens once" "$OUT" 'msg="clamp verified"' 1
  assert_has "the start line names the resolved nvidia-smi" "$OUT" "nvidia_smi=$FAKE"
  assert_has "the start line carries the configuration" "$OUT" 'idle_s=0'
  assert_count "a clean stop logs exactly one exit line" "$OUT" 'msg="exit"' 1
  assert_has "the clean stop preserves status 0" "$OUT" 'msg="exit" gpu=0 rc=0'
  assert_has "the lock is released on stop" "$OUT" 'msg="unlocked" gpu=0 trigger=exit'
}

case_clamp_not_applied() {
  new_case clamp-not-applied
  start_daemon IDLE_SECONDS=0 SAMPLE_MS=50 SKIP_IF_LOW=1 \
    FAKE_LGC_APPLIES=0 \
    FAKE_LGC_STDERR='Specified clock combination is not supported; treating as warning and moving on.'
  stop_daemon 1.2
  assert_has "an ineffective clamp is reported as an error" "$OUT" 'level=error msg="clamp not applied"'
  assert_has "the ineffective clamp reports the observed clock" "$OUT" 'observed_mhz=1260'
  assert_has "the ineffective clamp keeps nvidia-smi stderr" "$OUT" "treating as warning and moving on."
  assert_lacks "an ineffective clamp is never called verified" "$OUT" 'msg="clamp verified"'
  assert_count "a rejected clamp is not retried on every sample" "$ARGV" ' -lgc ' 1
}

# --- #2: a failing clamp is logged once and backed off ----------------------
case_clamp_failed_backoff_short() {
  new_case clamp-failed-short
  start_daemon IDLE_SECONDS=0 SAMPLE_MS=50 SKIP_IF_LOW=1 \
    FAKE_LGC_RC=4 \
    FAKE_LGC_STDERR='The current user does not have permission to change clocks'
  stop_daemon 1.2
  assert_has "a rejected clamp is logged" "$OUT" 'level=error msg="clamp failed"'
  assert_has "the clamp failure carries the return code" "$OUT" 'rc=4'
  assert_has "the clamp failure carries nvidia-smi stderr" "$OUT" 'does not have permission'
  assert_has "the clamp failure announces the backoff" "$OUT" 'retry_s=5'
  assert_count "a failing clamp logs once, not per sample" "$OUT" 'msg="clamp failed"' 1
  assert_count "a failing clamp does not fork nvidia-smi per sample" "$ARGV" ' -lgc ' 1
}

case_clamp_failed_backoff_grows() {
  local -a stamps=() ts rest
  new_case clamp-failed-backoff
  start_daemon IDLE_SECONDS=0 SAMPLE_MS=50 SKIP_IF_LOW=1 FAKE_LGC_RC=4
  stop_daemon 5.6
  while read -r ts rest; do
    case "$rest" in
      *" -lgc "*) stamps+=("$ts") ;;
    esac
  done < "$ARGV"
  assert_eq "a persistently failing clamp is retried once after the backoff" 2 "${#stamps[@]}"
  if [ "${#stamps[@]}" -eq 2 ]; then
    assert_ge "the retry waits for the 5 s backoff" 4 "$(( stamps[1] - stamps[0] ))"
  fi
  assert_count "the failure is logged only on the state change" "$OUT" 'msg="clamp failed"' 1
}

case_clamp_reassert() {
  new_case clamp-reassert
  start_daemon IDLE_SECONDS=0 SAMPLE_MS=50 SKIP_IF_LOW=1 \
    REASSERT_SECONDS=1 \
    FAKE_LGC_FAIL_FROM=2 \
    FAKE_LGC_STDERR='Unable to set clocks: GPU is lost'
  stop_daemon 2.2
  assert_count "the first clamp is verified" "$OUT" 'msg="clamp verified"' 1
  assert_has "a failed re-assert is visible" "$OUT" 'level=warn msg="clamp reassert failed"'
  assert_has "the failed re-assert reports its stderr" "$OUT" 'Unable to set clocks'
  assert_count "a repeated re-assert failure is logged once" "$OUT" 'msg="clamp reassert failed"' 1
  assert_lacks "a failed re-assert is not reported as a new clamp" "$OUT" 'trigger=reassert observed_mhz=135'
}

# --- #6: a failed unlock is never reported as success ----------------------
case_unlock_failed_activity() {
  new_case unlock-activity
  start_daemon IDLE_SECONDS=0 SAMPLE_MS=50 SKIP_IF_LOW=1 \
    FAKE_STREAM_UTILS='0 0 0 90' \
    FAKE_RGC_FAIL_FROM=2 \
    FAKE_RGC_STDERR='Unable to reset clocks: GPU is lost'
  stop_daemon 1.8
  assert_has "a failed unlock is reported" "$OUT" 'msg="unlock failed" gpu=0 trigger=util'
  assert_has "the failed unlock keeps nvidia-smi stderr" "$OUT" 'Unable to reset clocks'
  assert_lacks "a failed unlock is never called unlocked" "$OUT" 'msg="unlocked"'
  assert_count "a failed unlock is logged once per streak" "$OUT" 'msg="unlock failed"' 1
  assert_rc "a stop with a failed unlock exits non-zero" 1 "$RUN_RC"
  assert_has "the failing stop is reflected in the exit line" "$OUT" 'msg="exit" gpu=0 rc=1 reason=unlock_failed'
  assert_count "the failing stop still logs exactly one exit line" "$OUT" 'msg="exit"' 1
}

case_unlock_failed_stop() {
  new_case unlock-stop
  start_daemon IDLE_SECONDS=30 FAKE_RGC_RC=1 FAKE_RGC_STDERR='Unable to reset clocks: GPU is lost'
  stop_daemon 0.7
  assert_rc "a deliberate stop with a failed unlock exits non-zero" 1 "$RUN_RC"
  assert_lacks "no unlock success is claimed" "$OUT" 'msg="unlocked"'
  assert_has "the exit line says why" "$OUT" 'reason=unlock_failed'
}

# --- #4: the exit status survives the EXIT trap ----------------------------
case_stop_is_success() {
  new_case stop-clean
  start_daemon IDLE_SECONDS=30
  stop_daemon 0.7
  assert_rc "SIGTERM is a successful stop" 0 "$RUN_RC"
  assert_count "a successful stop logs one exit line" "$OUT" 'msg="exit"' 1
  assert_has "the exit line reports rc=0" "$OUT" 'rc=0'
}

case_fatal_status_preserved() {
  local copy="$WORK/fatal-copy"
  new_case fatal-status
  make_fatal_copy "$copy"
  SCRIPT_UNDER_TEST="$copy" run_daemon FAKE_FATAL_SENTINEL=abc
  assert_rc "a fatal runtime error exits non-zero" 1 "$RUN_RC"
  assert_has "the fatal exit is logged" "$OUT" 'msg="exit" gpu=0 rc=1'
  assert_count "the fatal error exits exactly once" "$OUT" 'msg="exit"' 1
  assert_has "cleanup still releases clocks on a fatal error" "$ARGV" ' -rgc'
}

# --- #24: stdbuf is optional and stream errors are visible -----------------
case_stream_without_stdbuf() {
  local shim="$WORK/shim-no-stdbuf"
  new_case no-stdbuf
  make_shim "$shim"
  if [ -x "$shim/stdbuf" ]; then
    fail "the no-stdbuf shim must not contain stdbuf" "unexpected $shim/stdbuf"
    return
  fi
  start_daemon PATH="$shim" IDLE_SECONDS=0 SAMPLE_MS=50 SKIP_IF_LOW=1 \
    FAKE_STREAM_LINES=40 FAKE_STREAM_SLEEP=0.05
  stop_daemon 1.2
  assert_rc "the daemon runs without stdbuf" 0 "$RUN_RC"
  assert_has "the utilization stream is read without stdbuf" "$OUT" 'msg="clamp verified"'
  assert_lacks "no stdbuf error is hidden or shown" "$OUT" 'stdbuf'
  assert_lacks "no stdbuf error reaches stderr" "$ERR" 'stdbuf'
}

case_stream_error_visible() {
  new_case stream-error
  start_daemon IDLE_SECONDS=30 \
    FAKE_STREAM_LINES=1 FAKE_STREAM_EXIT_RC=127 \
    FAKE_STREAM_STDERR='nvidia-smi: command not found'
  stop_daemon 0.9
  assert_has "a lost stream is reported" "$OUT" 'level=warn msg="stream lost"'
  assert_has "the lost stream keeps its stderr" "$OUT" 'nvidia-smi: command not found'
  assert_has "the lost stream announces the reconnect delay" "$OUT" 'retry_s=2'
  assert_count "an identical stream error is not repeated" "$OUT" 'msg="stream lost"' 1
}

# --- #3 / #15: GPU selection ---------------------------------------------
case_gpu_index_selected() {
  new_case gpu-index
  start_daemon GPU=1 FAKE_GPUS='0 1' IDLE_SECONDS=0 SAMPLE_MS=50 SKIP_IF_LOW=1
  stop_daemon 1.0
  assert_has "the requested index is the only target" "$OUT" 'msg="started" gpu=1'
  assert_has "the clamp targets the requested GPU" "$ARGV" '-i 1 -lgc 135,135'
  assert_lacks "the other GPU is never clamped" "$ARGV" '-i 0 -lgc'
}

case_gpu_uuid_selected() {
  new_case gpu-uuid
  start_daemon GPU='GPU-01234567-89ab-cdef-0123-456789abcd01' FAKE_GPUS='0 1' \
    IDLE_SECONDS=30
  stop_daemon 0.8
  assert_has "a UUID selector resolves to its index" "$OUT" 'msg="started" gpu=1'
  assert_rc "a UUID selector starts cleanly" 0 "$RUN_RC"
}

case_gpu_unknown() {
  new_case gpu-unknown
  run_daemon GPU=9
  assert_rc "an unknown GPU exits 1" 1 "$RUN_RC"
  assert_has "the unknown GPU is named" "$OUT" 'msg="gpu not found" gpu=9'
  assert_has "no usable GPU is reported" "$OUT" 'msg="no usable gpu"'
  assert_count "an unknown GPU is only looked up, never clamped" "$ARGV" '--query-gpu=index,uuid' 1
  assert_lacks "an unknown GPU is never clamped" "$ARGV" ' -lgc '
  assert_lacks "an unknown GPU is never unlocked" "$ARGV" ' -rgc'
}

# --- #29 / #31: log shape and language ------------------------------------
case_log_format() {
  local bad
  new_case log-shape
  start_daemon IDLE_SECONDS=0 SAMPLE_MS=50 SKIP_IF_LOW=1
  stop_daemon 1.0
  bad=$(grep -cvE '^level=(info|warn|error) msg="' "$OUT")
  assert_eq "every log line is structured level=... msg=..." 0 "$bad"
  bad=$(grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T]' "$OUT")
  assert_eq "log lines carry no own timestamp" 0 "$bad"
  bad=$(LC_ALL=C grep -c '[^ -~]' "$OUT")
  assert_eq "log lines are ASCII only" 0 "$bad"
  bad=$(LC_ALL=C grep -c '[^ -~]' "$SCRIPT")
  assert_eq "the daemon source is ASCII only (English)" 0 "$bad"
}

# --- #5: a stop while blocked in read unlocks every GPU separately ----------
case_sigterm_multigpu_unlock() {
  local wrapper argvq
  new_case sigterm-multigpu
  wrapper=$(make_argv_wrapper "$CASE_DIR/bin")
  argvq="$CASE_DIR/argv-quoted.log"
  : > "$argvq"
  # SAMPLE_MS/FAKE_STREAM_SLEEP keep the daemon blocked inside `read` when the
  # signal arrives, which is the state in which a leaked empty IFS used to break
  # word splitting of the GPU list.
  start_daemon GPU=0,1 FAKE_GPUS='0 1' IDLE_SECONDS=30 SAMPLE_MS=5000 \
    FAKE_STREAM_SLEEP=5 \
    NVSMI="$wrapper" FAKE_REAL="$FAKE" FAKE_ARGV_QUOTED="$argvq"
  stop_daemon 0.8
  assert_rc "a multi-GPU stop exits 0" 0 "$RUN_RC"
  assert_count "the startup and stop unlocks are one -rgc per GPU" "$argvq" '[-rgc]' 4
  assert_count "gpu 0 is reset with its own -i argument" "$argvq" '[-i] [0] [-rgc]' 2
  assert_count "gpu 1 is reset with its own -i argument" "$argvq" '[-i] [1] [-rgc]' 2
  assert_lacks "no space-joined GPU list is passed to -i" "$argvq" '[-i] [0 1] [-rgc]'
  assert_lacks "no comma-joined GPU list is passed to -i" "$argvq" '[-i] [0,1] [-rgc]'
  assert_stream_child_gone "the stream child does not outlive a stop" "$STATE/stream.pid"
}

# --- #7: a stalled stream is detected, the child is killed, the unit fails ---
case_stream_stale() {
  new_case stream-stale
  run_daemon IDLE_SECONDS=0 SAMPLE_MS=50 SKIP_IF_LOW=1 FAKE_STREAM_STALL_AFTER=2
  assert_rc "a stalled utilization stream exits non-zero" 1 "$RUN_RC"
  assert_has "the stall is reported as an error" "$OUT" 'level=error msg="utilization stream stale"'
  assert_has "the stall reports the read timeout" "$OUT" 'timeout_s=5'
  assert_has "the clamp is released before the restart" "$OUT" 'msg="unlocked" gpu=0 trigger=exit'
  assert_has "the exit line keeps the failure" "$OUT" 'msg="exit" gpu=0 rc=1'
  assert_stream_child_gone "the stalled nvidia-smi child is killed" "$STATE/stream.pid"
}

case_stream_reconnect_bounded() {
  local copy="$WORK/bounded-retry"
  new_case stream-bounded
  make_retry_copy "$copy"
  SCRIPT_UNDER_TEST="$copy" run_daemon IDLE_SECONDS=30 FAKE_STREAM_LINES=1 \
    FAKE_STREAM_EXIT_RC=1 FAKE_STREAM_STDERR='video driver unavailable'
  assert_rc "a stream that never returns exits non-zero" 1 "$RUN_RC"
  assert_has "the exhausted reconnect budget is an error" "$OUT" \
    'level=error msg="utilization stream unavailable"'
  assert_has "the reconnect budget is reported" "$OUT" 'attempts=5'
  assert_has "the stream loss is reported" "$OUT" 'msg="stream lost"'
  assert_count "the budget failure exits exactly once" "$OUT" 'msg="exit"' 1
  assert_has "the failure is reflected in the exit line" "$OUT" 'msg="exit" gpu=0 rc=1'
}

# A SIGKILL cannot be trapped, so the stream child has to notice that its stdout
# reader is gone and exit by itself; nothing may be left polling the driver.
case_sigkill_stream_child() {
  local pidfile="$STATE/stream.pid"
  new_case sigkill-child
  start_daemon IDLE_SECONDS=30 SAMPLE_MS=50
  if ! wait_for_count "$ARGV" '--loop-ms' 1 30; then
    fail "the utilization stream is started" "no stream within 3 s"
    stop_daemon 0.1
    return
  fi
  kill -KILL "$RUN_PID" 2>/dev/null
  wait "$RUN_PID" 2>/dev/null || true
  RUN_PID=""
  assert_stream_child_gone "the stream child exits after the daemon is SIGKILLed" "$pidfile"
}

# --- #8: unreadable utilization releases the clamp and never counts as idle --
case_util_unavailable_releases() {
  new_case util-unavailable
  start_daemon IDLE_SECONDS=0 SAMPLE_MS=50 SKIP_IF_LOW=1 FAKE_STREAM_UTILS='0 [N/A]'
  stop_daemon 1.0
  assert_has "the clamp is applied on the numeric sample" "$OUT" 'msg="clamp verified"'
  assert_has "unreadable utilization is reported" "$OUT" 'level=warn msg="utilization unavailable"'
  assert_count "unreadable utilization is logged once per streak" "$OUT" \
    'msg="utilization unavailable"' 1
  assert_has "the unreadable sample is kept in the log" "$OUT" 'raw="0, [N/A]"'
  assert_has "the clamp is released while utilization is unreadable" "$OUT" \
    'msg="unlocked" gpu=0 trigger=unavailable'
  assert_rc "an unreadable sample is not a fatal error" 0 "$RUN_RC"
}

case_util_unavailable_not_idle() {
  new_case util-unavailable-idle
  start_daemon IDLE_SECONDS=1 SAMPLE_MS=50 SKIP_IF_LOW=1 FAKE_STREAM_UTILS='[N/A]'
  stop_daemon 1.6
  assert_has "unreadable utilization is reported" "$OUT" 'msg="utilization unavailable"'
  assert_count "unreadable utilization never accumulates idle time" "$ARGV" ' -lgc ' 0
}

# --- #19: idle time is wall-clock time, not a count of CSV lines -------------
case_idle_timer_wall_clock() {
  new_case idle-wall-clock
  # The stream delivers every 0.6 s while SAMPLE_MS claims 50 ms: a line counter
  # would need 40 samples (24 s) to reach IDLE_SECONDS=2 and never clamp here.
  start_daemon IDLE_SECONDS=2 SAMPLE_MS=50 SKIP_IF_LOW=1 FAKE_STREAM_SLEEP=0.6
  sleep 1.2
  assert_lacks "idle time is not inferred from the sample count" "$OUT" 'msg="clamp verified"'
  stop_daemon 2.2
  assert_has "the configured idle seconds are wall-clock seconds" "$OUT" 'msg="clamp verified"'
}

case_idle_timer_reconnect_gap() {
  new_case idle-reconnect
  start_daemon IDLE_SECONDS=1 SAMPLE_MS=50 SKIP_IF_LOW=1 \
    FAKE_STREAM_LINES_ONCE=3 FAKE_STREAM_SLEEP=0.1
  if ! wait_for_count "$ARGV" '--loop-ms' 2 50; then
    fail "the utilization stream reconnects" "no second connection within 5 s"
    stop_daemon 0.2
    return
  fi
  # The 2 s reconnect gap has just ended. Without a reset of the per-GPU
  # timestamp it would be counted as idle and the clamp would already be in
  # flight; with the reset the timer starts again from zero.
  sleep 0.6
  assert_lacks "the blind reconnect gap is not counted as idle" "$OUT" 'msg="clamp verified"'
  sleep 1.0
  assert_has "the idle timer restarts after a reconnect" "$OUT" 'msg="clamp verified"'
  stop_daemon 0.4
}

# --- run everything --------------------------------------------------------
case_config_util_threshold
case_config_gpu_glob
case_config_gpu_mixed
case_config_seconds_suffix
case_config_sample_ms
case_config_skip_if_low
case_config_range_order
case_config_cap_above_max
case_config_cap_nonnumeric
case_nvsmi_missing
case_nvsmi_from_path
case_clamp_verified
case_clamp_not_applied
case_clamp_failed_backoff_short
case_clamp_failed_backoff_grows
case_clamp_reassert
case_unlock_failed_activity
case_unlock_failed_stop
case_stop_is_success
case_fatal_status_preserved
case_stream_without_stdbuf
case_stream_error_visible
case_sigterm_multigpu_unlock
case_stream_stale
case_sigkill_stream_child
case_stream_reconnect_bounded
case_util_unavailable_releases
case_util_unavailable_not_idle
case_idle_timer_wall_clock
case_idle_timer_reconnect_gap
case_gpu_index_selected
case_gpu_uuid_selected
case_gpu_unknown
case_log_format

# --- no leaked stream children --------------------------------------------
# The daemon kills its utilization-stream child on the way out (issue #7), and
# the suite reaps the daemon's process group. This check proves it: a leftover
# fake would keep polling for the rest of the session.
reap_case_processes
if command -v pgrep >/dev/null 2>&1; then
  leftover=$(pgrep -f -- "$FAKE" 2>/dev/null || true)
  if [ -z "$leftover" ]; then
    pass "the suite leaves no fake nvidia-smi process behind"
  else
    fail "the suite leaves no fake nvidia-smi process behind" \
      "still running: $(printf '%s' "$leftover" | tr '\n' ' ')"
    for p in $leftover; do kill -KILL "$p" 2>/dev/null || true; done
  fi
fi

if [ "$FAIL" -eq 0 ]; then
  printf '\nsummary: %d checks passed, 0 failed\n' "$PASS"
  exit 0
fi
printf '\nsummary: %d checks passed, %d failed\n' "$PASS" "$FAIL"
printf 'failed:\n'
for name in "${FAILED[@]}"; do printf '  - %s\n' "$name"; done
exit 1
