# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.4] - 2026-10-22

Documentation release: the README now states its limits and its footguns up front. No code change.

### Changed

- **Limits before the install steps.** Linux + systemd + Volta/sm70 only; V100-PCIE-32GB and
  PG500-216 are the only verified parts; newer generations are unsupported (the daemon refuses an
  out-of-range cap and never reports a clamp it could not verify); bash 4.2+, root for the install.
- **`30-second demo`.** A copy-paste, service-free walkthrough: hold 512 MiB of VRAM with an idle
  process, watch clocks and power, run the daemon in the foreground with `IDLE_SECONDS=5`, then let
  it release on Ctrl-C or on any kernel launch.
- **`Do not` / `やってはいけないこと`.** Nine explicit don'ts: shared GPUs, non-V100 hardware,
  Windows/macOS/WSL/no-systemd containers, permanently busy GPUs, latency-critical use, two
  instances on one GPU, MIG, hand-editing the installed binary, and treating `--keep-clocks` as a
  permanent setting.
- **Requirements** now list systemd (255 tested; older releases warn on unknown sandbox
  directives), the driver's `-lgc`, coreutils, optional `flock`, and the root requirement.

## [0.2.3] - 2026-10-22

Documentation release: bilingual figures. No code change.

### Changed

- The README and reference figures now come in Japanese (`img/ja/`) and English (`img/en/`)
  variants, generated from one deterministic script (`docs/make-images.py`) with a per-language
  string table; the Japanese set is rendered with Noto Sans CJK JP. Each README/reference links to
  its own language's figures.
- `img/hero.png`, `img/clamp-ladder.png`, `img/perf.png` and `img/timeline.png` moved to
  `img/en/` (the English variants of the same figures).

## [0.2.2] - 2026-10-22

Follow-up to the v0.2.1 release audit. The daemon's control loop is unchanged; these are
installer, unit and periphery fixes.

### Fixed

- **installer:** a failed install now restores a pre-existing legacy
  `nvidia-idle-clock.service` (enabled and, if it was running, active) on rollback, and no longer
  claims "the previous state was restored" when a unit could not be restored.
- **installer:** a stale `${STATE_DIR:-/run/nvidia-idle-clock}/keep-clocks` marker left by
  `uninstall.sh --keep-clocks` is cleared by the next install, so reinstalling can no longer produce
  a daemon that never releases clocks and a `--unlock` that silently does nothing.
- **daemon:** no empty `nvidia-idle-clock.XXXXXX` temp file is left behind on exit 1 (runtime error)
  or exit 3 (GPU already managed); the file is allocated after the exclusion check and the trap.
- **systemd:** exit 2 (invalid configuration or arguments) is no longer retried — a permanent
  mistake fails immediately instead of burning the 30-restart budget (`RestartPreventExitStatus=2 3`).
- **systemd:** the driver-node check runs through `/bin/sh -c` instead of `/usr/bin/test`, so it
  works on hosts without coreutils at `/usr/bin` (e.g. NixOS).

### Changed

- Documented two deliberate trade-offs in the source headers: a start ignores `keep-clocks` (the
  keep covers the stop paths only), and the recovery marker is written before `-lgc`, so a later
  `--unlock` can reset a lock that another tool set in between.

## [0.2.1] - 2026-10-22

Follow-up fixes from an independent review of 0.2.0. No behaviour change for a
correctly configured host.

### Fixed

- **daemon:** clamp recovery intent is recorded before `-lgc`, and an
  unverifiable read-back keeps the GPU as a release target (#44); a failed
  startup release of a stale marker is retried when the GPU becomes busy
  instead of being forgotten (#45).
- **installer:** rollback no longer stops/disables instances that were running
  before the run (#46).
- **systemd:** a missing `/dev/nvidiactl` at boot is a retried `ExecStartPre=`
  failure instead of a silent skip (#47).
- **installer:** `--keep-clocks` now really keeps the clamp through the stop
  path; the daemon honours `$STATE_DIR/keep-clocks` (#48).

### Changed

- **systemd:** the boot check moved from `ConditionPathExists=` to
  `ExecStartPre=`.
- **installer:** `--keep-clocks` writes a marker before stopping.

### Docs

- **docs:** reference updated for the above.

## [0.2.0] - 2026-10-22

First tagged release. Entries are grouped by area: **daemon**
(`nvidia-idle-clock`), **systemd** (the template unit), **installer**
(`install.sh` / `uninstall.sh`), **portability**, **docs**, **tests / CI**, and
**oss** (repository meta).

### Added

- **daemon:** `-h`/`--help`, `-V`/`--version`, `-n`/`--dry-run` and
  `-u`/`--unlock` are parsed before configuration validation and before any
  `nvidia-smi` call, so `--help` cannot start the daemon or touch a GPU.
  `--version` prints `nvidia-idle-clock 0.2.0`; `--dry-run` validates the
  configuration, prints the resolved plan and exits without calling
  `-lgc`/`-rgc`. Unknown options and positional arguments print usage on
  stderr and exit 2 (#38).
- **daemon:** the exit-status contract is documented and enforced: 0 for a
  clean stop (or a successful `--help`/`--version`/`--dry-run`/`--unlock`),
  1 for a runtime failure, 2 for an invalid configuration or argument, and 3
  for a GPU already managed by another instance (#38, #41).
- **daemon:** `--unlock` releases exactly the GPUs that carry a state marker:
  exit 0 when there was nothing to do, 1 if `-rgc` failed, and a GPU held by a
  live instance is skipped. `$STATE_DIR` (default `/run/nvidia-idle-clock`,
  mode 0700) holds the `gpu<N>.locked` marker written after a verified clamp
  and the `gpu<N>.lock` used for exclusion (#9, #20).
- **daemon:** `COOLDOWN_SECONDS` (default 60, 0 disables) keeps the same GPU
  from being re-clamped for that long after a release, so bursty load cannot
  make the clock flap. Releases are never delayed (#18).
- **daemon:** a non-blocking `flock` on `$STATE_DIR/gpu<N>.lock` gives one
  instance exclusive ownership of a GPU; a second instance targeting it logs
  `msg="gpu already managed"` and exits 3 (#21).
- **systemd:** `ExecStopPost=-/usr/local/sbin/nvidia-idle-clock --unlock`
  releases exactly the marked GPUs after every stop, including SIGKILL, OOM
  and a `TimeoutStopSec` overrun (#9).
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
  `UTIL_THRESHOLD`, `REASSERT_SECONDS`, `SKIP_IF_LOW` and `COOLDOWN_SECONDS`
  are validated at startup (and `STATE_DIR` must not be empty); an invalid
  value fails closed with a `level=error` line instead of silently clamping
  the wrong way (#3).
- **daemon:** comments, log messages and installer output are English, with
  stable `key=value` fields on every log line (#31).
- **systemd:** the unit runs with filesystem, namespace and kernel-interface
  sandboxing (`ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, ...) instead
  of plain root with no restrictions. `CapabilityBoundingSet=` and
  `SystemCallFilter=` are deliberately left at the systemd defaults because the
  capability set that NVML `-lgc`/`-rgc` needs has not been validated on
  hardware. The state directory needs one writable path, so the unit grants
  `ReadWritePaths=/run` and keeps `ReadOnlyPaths=/run/systemd /run/udev
  /run/log`: a narrower `ReadWritePaths=/run/nvidia-idle-clock` fails with
  `226/NAMESPACE` on a fresh boot, and `RuntimeDirectory=` is deliberately not
  used because it would delete the markers on stop (#10, #20).
- **systemd:** startup waits until the NVIDIA driver has finished probing
  (`ConditionPathExists=/dev/nvidiactl`, `After=dev-nvidiactl.device`) and the
  restart budget/interval are sized so a boot race can recover instead of
  leaving a permanently `failed` unit (#11).
- **systemd:** the instance name is validated as a GPU index before the daemon
  starts, so a typo fails fast instead of becoming a permanently failed unit
  (#30).
- **systemd:** `RestartPreventExitStatus=3` keeps "GPU already managed" from
  turning into a restart loop (#21).
- **daemon:** startup no longer runs `-rgc` unconditionally: it releases only
  GPUs carrying a stale marker from an interrupted instance, so a clock lock
  another tool set on another GPU is never touched. A clean stop releases only
  the GPUs this instance clamped and holds the lock for (#20).
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
- **daemon:** a clamp can no longer be left on the device by SIGKILL, OOM or a
  stop timeout: the marker survives and `--unlock` (unit `ExecStopPost`) or
  the next start releases it (#9).
- **daemon:** short clamp/release flapping under bursty load is suppressed by
  the re-clamp cooldown (#18).
- **daemon:** startup and stop no longer reset clock locks this instance did
  not set, and two instances on one GPU no longer release each other's clamp
  (#20, #21).
- **docs:** the README documents the state directory, `--unlock`, the
  supervisor release, the re-clamp cooldown and the per-GPU exclusion, and its
  sample log now shows the merged log lines (#41).
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

[0.2.1]: https://github.com/kuraneko1/nvidia-idle-clock/releases/tag/v0.2.1
[0.2.0]: https://github.com/kuraneko1/nvidia-idle-clock/releases/tag/v0.2.0
