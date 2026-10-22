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

- **daemon:** `-h`/`--help`, `-V`/`--version` and `-n`/`--dry-run` are parsed
  before configuration validation and before any `nvidia-smi` call, so
  `--help` cannot start the daemon or touch a GPU. `--version` prints
  `nvidia-idle-clock 0.2.0`; `--dry-run` validates the configuration, prints
  the resolved plan and exits without calling `-lgc`/`-rgc`. Unknown options
  and positional arguments print usage on stderr and exit 2 (#38).
- **daemon:** the exit-status contract is documented and enforced: 0 for a
  clean stop (or a successful `--help`/`--version`/`--dry-run`), 1 for a
  runtime failure, 2 for an invalid configuration or argument (#38).
- **docs:** the idle-power section now carries the measured A/B table
  (4 × 600s samples, ~31GiB/GPU held in VRAM vs empty, clamped vs unclamped)
  with its method and caveats, the annual kWh at 25/50/75/100% idle duty, a
  Shizuoka tariff example, and the per-board default idle step (GPU0 1230MHz,
  GPU1 1260MHz).
- **tests:** `tests/run.sh`, a GPU-free suite that drives the daemon against a
  fake `nvidia-smi` injected through `NVSMI` — plain bash, no bats, non-zero
  exit on failure and a one-line summary (#25).
- **tests:** `tests/installer/run.sh`, an installer/uninstaller suite that shims
  every privileged command and runs the root-only cases in a bubblewrap user
  namespace; the bwrap-only assertions skip themselves when that namespace is
  unavailable (#37).
- **tests / CI:** `.github/workflows/ci.yml` runs ShellCheck (`-S warning`),
  `bash -n`, `systemd-analyze verify`, `tests/run.sh` and
  `tests/installer/run.sh` on every push and pull request to `main` (#25, #37).
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
- **systemd:** the unit runs with filesystem, namespace and kernel-interface
  sandboxing (`ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, ...) instead
  of plain root with no restrictions. `CapabilityBoundingSet=` and
  `SystemCallFilter=` are deliberately left at the systemd defaults because the
  capability set that NVML `-lgc`/`-rgc` needs has not been validated on
  hardware (#10).
- **systemd:** startup waits until the NVIDIA driver has finished probing
  (`ConditionPathExists=/dev/nvidiactl`, `After=dev-nvidiactl.device`) and the
  restart budget/interval are sized so a boot race can recover instead of
  leaving a permanently `failed` unit (#11).
- **systemd:** the instance name is validated as a GPU index before the daemon
  starts, so a typo fails fast instead of becoming a permanently failed unit
  (#30).
- **installer:** `install.sh` parses its own options (`-h`/`--help`,
  `-V`/`--version`, `-n`/`--dry-run`, `--force`, `--gpus LIST`, `--`), rejects
  unknown options and invalid GPU arguments with usage on stderr and exit 2,
  and runs a preflight (required commands, systemd state, payload files) before
  the first write (#12, #37).
- **installer:** a failed install rolls back — newly created files are removed
  and replaced files are restored from the timestamped backup
  (`<path>.bak.<YYYYMMDDTHHMMSS>`) taken before the replacement (#13, #37).
- **installer:** `uninstall.sh` gains `-h`/`--help`, `-n`/`--dry-run` and
  `--keep-clocks`; it leaves the files in place when a unit cannot be stopped,
  and verifies both the removal and the `-rgc` result instead of declaring
  success (#14, #37).
- **portability:** the `nvidia-smi` path is read from `NVSMI` instead of being
  hard-coded to `/usr/bin/nvidia-smi` (#15).
- **portability:** `stdbuf` is optional; when the utilization stream ends, the
  first stderr line is logged and the reconnect uses exponential backoff
  (2→30s) instead of a fixed 2s retry (#24).

### Fixed

- **daemon:** an out-of-range `-lgc` is rejected before start (`IDLE_CAP` above
  the GPU's `clocks.max.gr`) and an accepted-but-ineffective request is caught
  with a read-back, instead of logging success while the clock was never
  clamped (#1).
- **daemon:** a failing `-lgc` is logged with the driver's error text and
  retried under a bounded backoff policy (5→60s), instead of a silent retry on
  every sample (#2).
- **daemon:** the `EXIT` trap preserves the real exit status, so a fatal error
  reaches systemd as a failure rather than a clean stop (#4).
- **daemon:** multi-GPU instances run `-rgc` on `systemctl stop`; the unlock
  path iterates the GPU array and pins a sane `IFS` inside `unlock_all`, so a
  leaked `IFS` cannot collapse the target list (#5).
- **daemon:** a failed `-rgc` is reported as a failure instead of being recorded
  as "unlocked" (#6).
- **daemon:** a stalled utilization stream is detected with `read -t`
  (max(5s, 5×`SAMPLE_MS`)), the `nvidia-smi` child is killed, and the daemon
  exits 1 so `Restart=on-failure` rebuilds the unit; five failed reconnects
  inside 60s also end it instead of reconnecting forever (#7).
- **daemon:** non-numeric utilization (`[N/A]`) is treated as unavailable: a
  held clamp is released (safe side), the idle clock is reset, and the event is
  logged once per streak (#8).
- **daemon:** idle time is measured on a wall clock (`EPOCHREALTIME`, GNU
  `date`, `SECONDS` fallback) instead of counting CSV lines, so
  `IDLE_SECONDS` holds at a different stream cadence and reconnect gaps do not
  count as idle (#19).
- **daemon:** clamp lines log the clock observed *after* the operation, unlock
  lines log the trigger/utilization, and failures use `level=warn`/
  `level=error`, so anomalies can be filtered out of the journal (#29).
- **installer:** an existing binary is no longer overwritten silently, and
  running instances are switched to the new code after an upgrade when the
  payload changed (#22).
- **installer:** installing from a checkout owned by another user, world
  writable, or group writable through a shared group is refused unless the
  caller passes `--force`, and ownership and permissions are checked (#23).
- **docs:** the cost section and the release-latency claim match the measured
  data instead of the previous fixed upper-bound promise (#16).
- **docs:** the README states that the clamp applies to the whole device and
  warns about assigning the same `GPU=` index twice (#17).
- **docs:** the `-rgc` section describes the measured post-release behaviour
  (back to the driver-managed clock within seconds, +11.8 W) instead of the
  opposite (#28).
- **docs:** unsourced claims about `nvidia-pstate` (45 W → 10 W) and the
  P40/P100 clock ranges are sourced or removed (#32).
- **oss:** `.gitignore` keeps the whitelist — the checkout shares a directory
  with unrelated private projects — but now unignores every path the project
  ships (`.github/`, `tests/`, `docs/`, `SECURITY.md`, `CONTRIBUTING.md`,
  `CHANGELOG.md`, `.editorconfig`) and documents how to add a new file (#26).

[0.2.0]: https://github.com/kuraneko1/nvidia-idle-clock/releases/tag/v0.2.0
