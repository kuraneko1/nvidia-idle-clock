# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - unreleased

First tagged release. Entries are grouped by area: **daemon**
(`nvidia-idle-clock`), **systemd** (the template unit), **installer**
(`install.sh` / `uninstall.sh`), **portability**, **docs**, **tests / CI**, and
**oss** (repository meta).

### Added

- **daemon:** `--help`, `--version`, `--once` and `--dry-run` are parsed before
  anything touches the GPU, so `--help` prints usage instead of starting the
  daemon and sending `-rgc` (#25).
- **tests:** `tests/run.sh`, a GPU-free suite that drives the daemon against a
  fake `nvidia-smi` injected through `NVSMI` — plain bash, no bats, non-zero
  exit on failure and a one-line summary (#25).
- **tests / CI:** `.github/workflows/ci.yml` runs ShellCheck (`-S warning`),
  `bash -n`, `systemd-analyze verify` and the test suite on every push and pull
  request to `main` (#25).
- **oss:** `.editorconfig` (LF, UTF-8, 2-space YAML and shell) (#25).
- **oss:** `SECURITY.md` with the supported-version table, the private advisory
  route, and what to include when a device may have been left clamped (#27).
- **oss:** `CONTRIBUTING.md`, `CHANGELOG.md`, bug and feature issue forms, and a
  pull request template (#27).

### Changed

- **daemon:** `GPU`, `IDLE_CAP`, `MIN_CLK`, `IDLE_SECONDS`, `SAMPLE_MS`,
  `UTIL_THRESHOLD`, `REASSERT_SECONDS` and `SKIP_IF_LOW` are validated at
  startup; an invalid value fails closed with a `level=error` line instead of
  silently clamping the wrong way (#3).
- **daemon:** comments, log messages and installer output are English, with
  stable `key=value` fields on every log line (#31).
- **systemd:** the unit runs with a reduced capability set and
  filesystem/device sandboxing instead of full root capabilities (#10).
- **systemd:** startup waits until the NVIDIA driver has finished probing, so a
  boot race no longer leaves a permanently `failed` unit (#11).
- **installer:** `install.sh` validates its arguments, runs a preflight check and
  rolls back a partially applied install (#12, #13); `uninstall.sh` reports
  failures instead of declaring success (#14).
- **portability:** the `nvidia-smi` path is read from `NVSMI` instead of being
  hard-coded to `/usr/bin/nvidia-smi` (#15).
- **portability:** `stdbuf` is no longer required; the utilization stream falls
  back gracefully instead of looping on "stream closed" forever (#24).

### Fixed

- **daemon:** an out-of-range `-lgc` is detected and reported, instead of logging
  success while the clock was never clamped (#1).
- **daemon:** a failing `-lgc` is logged with the driver's error text and retried
  under a bounded policy, instead of a silent retry on every sample (#2).
- **daemon:** the `EXIT` trap preserves the real exit status, so a fatal error
  reaches systemd as a failure rather than a clean stop (#4).
- **daemon:** multi-GPU instances run `-rgc` on `systemctl stop`; a leaked `IFS`
  no longer collapses the target list (#5).
- **daemon:** a failed `-rgc` is reported as a failure instead of being recorded
  as "unlocked" (#6).
- **daemon:** a stalled utilization stream is detected and reconnected with the
  clamp released, instead of holding the clamp while reconnecting forever (#7).
- **daemon:** non-numeric utilization readings (`[N/A]`) no longer freeze the
  state machine with the clamp held (#8).
- **daemon:** idle time is measured on a monotonic clock instead of counting
  samples, so a slow stream no longer stretches the configured idle window
  (#19).
- **daemon:** a hysteresis window after release stops the short clamp/release
  flapping under bursty load (#18).
- **daemon:** `-rgc` is no longer run unconditionally at start and stop, so clock
  locks owned by other tools survive; and two instances on one GPU no longer
  release each other's clamp (#20, #21).
- **daemon:** clamp and release lines log the clock observed *after* the
  operation, at severities that separate normal events from anomalies (#29).
- **systemd:** `ExecStopPost` releases the clamp when the stop path fails or
  hangs, and the instance name is validated as a GPU index so a typo fails fast
  instead of becoming a permanently failed unit (#9, #30).
- **installer:** an existing binary is no longer overwritten silently, and
  running instances are restarted after an upgrade (#22); installing from a
  writable working tree is refused unless the caller opts in, and ownership and
  permissions are checked (#23).
- **docs:** the cost section and the release-latency claim match the measured
  data instead of promising "within 200 ms" (#16).
- **docs:** the README states that the clamp applies to the whole device and
  warns about assigning the same `GPU=` index twice (#17).
- **docs:** the `-rgc` section describes the measured post-release behaviour
  (1260 MHz / +11.8 W) instead of the opposite (#28).
- **docs:** unsourced claims about `nvidia-pstate` (45 W → 10 W) and the
  P40/P100 clock ranges are sourced or removed (#32).
- **oss:** `.gitignore` keeps the whitelist — the checkout shares a directory
  with unrelated private projects — but now unignores every path the project
  ships (`.github/`, `tests/`, `docs/`, `SECURITY.md`, `CONTRIBUTING.md`,
  `CHANGELOG.md`, `.editorconfig`) and documents how to add a new file (#26).

[0.2.0]: https://github.com/kuraneko1/nvidia-idle-clock/releases/tag/v0.2.0
