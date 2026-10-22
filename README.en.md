English | [日本語](README.md)

# nvidia-idle-clock

For NVIDIA GPUs that park at a high clock and never come down while something sits in VRAM.
A systemd daemon that clamps the clock ceiling with `nvidia-smi -lgc` **only while idle**,
and releases it when load appears. It runs **one independent instance per GPU**,
so each card can have its own settings.
Dependencies are bash and `nvidia-smi` — no NVAPI, no CUDA toolkit, no build step.

| State | No clamp | Clamped @135MHz | Saving |
|---|---|---|---|
| V100-PCIE-32GB / ~31GiB in VRAM | 37.85W | **25.22W** | **−12.63W** |
| PG500-216 / ~31GiB in VRAM | 42.43W | **28.85W** | **−13.58W** |
| VRAM empty | 25.50W / 29.20W | 25.45W / 28.97W | −0.05W / −0.23W (noise) |

4 × 600s samples (n≈1060–1067 per GPU, stdev 0.05–0.33W, `utilization.gpu` 0.0 in every
sample). The older 3.6GiB / 8GiB-held runs measured 36.3W → 24.9W / 40.9W → 28.4W, and a
repeat run 25.1W / 28.5W, consistent with the values above. See Measurements for the
conditions and raw numbers.

> **It only helps while VRAM is held.**
> With VRAM empty the driver comes down to 135MHz by itself, so the clamp makes no difference
> (measured delta: 0.05W / 0.23W, i.e. noise). Conversely, **while VRAM is held the driver never
> comes down** — PG500-216 (GPU1) + 8GiB stayed at 1260MHz / 40–41W for a full **180 seconds**.
> That is the only case this tool targets. The default idle step differs per board
> (measured: GPU0 1230MHz, GPU1 1260MHz).
> Compute and memory bandwidth are **restored to within 0.01%** after the clamp is released
> (measured on PG500-216 with 8GiB held).

> **P-State forcing does not work on V100 (Volta).**
> On our test rig (driver **580.178.04**) NVAPI `NvAPI_GPU_SetForcePstate()` returns `NVAPI_ERROR`
> for every P-State (8–15) with `fallback=0`. The limitation was already analysed upstream in
> [nvidia-pstated issue #6](https://github.com/sasha0552/nvidia-pstated/issues/6) (January 2025),
> together with V100 measurements.
> The released [nvidia-pstate](https://github.com/sasha0552/nvidia-pstate) /
> [nvidia-pstated](https://github.com/sasha0552/nvidia-pstated) **v1.0.9 (2025-08-30)** only force
> P-States and do not work on V100 (on the same rig, `fallback=2` just pins the GPU to 555MHz,
> **+3W worse** than the driver's natural 135MHz idle). Clock locking for single-P-State GPUs is
> proposed in nvidia-pstated [PR #10](https://github.com/sasha0552/nvidia-pstated/pull/10)
> (still open as of 2026-10-22). Hence a clock-range lock instead of P-State forcing.

## How it differs from stock

![Measured timeline (PG500-216 / 8GiB held, older run): 27.8W while clamped at 135MHz, back to 1260MHz / 39.5W within 0.5s of load being detected, then re-clamped after 30.2s of no load](img/timeline.png)

| | Stock (driver-managed) | With this daemon |
|---|---|---|
| Clock while VRAM held and idle | stays at 1230–1380MHz (GPU0 1230 / GPU1 1260MHz), never drops | **135MHz** (after 30s idle) |
| Power in that state | 37.9–42.4W | **25.2–28.9W** |
| When load arrives | runs as-is | detected on the next sample, then `nvidia-smi -rgc` spawn and driver ramp: ≤0.5s in the timeline figure, 0.18–0.22s to reach 1300MHz measured in-kernel |
| 30s after load stops | still at the high clock | back to 135MHz |
| When VRAM is empty | driver drops to 135MHz by itself | **does nothing** (same) |
| P-State | stays P0 | stays P0 (unchanged) |

### What you can observe

The only externally visible difference is `clocks.current.graphics` reading 135MHz.
`PState` stays P0, `clocks.max.graphics` stays 1380MHz, and the `-lgc` lock never shows up in the report.

```
$ nvidia-smi --query-gpu=index,pstate,clocks.gr,clocks.max.gr,power.draw --format=csv
index, pstate, clocks.current.graphics [MHz], clocks.max.graphics [MHz], power.draw [W]
0, P0, 135 MHz, 1380 MHz, 25.22 W
1, P0, 135 MHz, 1380 MHz, 28.85 W
```

(One sample at one point in time, clamped with `IDLE_CAP=135`.)

### What does not change

- P-State (V100 is always P0)
- Process VRAM, CUDA contexts, numerical results
- persistence mode, power limits, PCIe link, fan control
- Maximum clock (returns to 1380MHz once released; stop/restart also resets the clocks to the
  driver default with `-rgc`, which *resets to the default* rather than restoring a previous lock —
  with VRAM still held the clock is back at the driver-managed value within seconds, see Notes)

### Cost

**Release latency** is the next sample period plus the `nvidia-smi -rgc` spawn plus the driver's
clock ramp, and it has no hard upper bound. At the defaults (`SAMPLE_MS=200`):

| Item | Measured |
|---|---|
| Sample period | mean 200.7 / 201.1ms, max 207.6ms (24 samples) |
| `nvidia-smi -rgc` spawn | 30–50ms (5 runs) |
| Release → 1300MHz | 180 / 215 / 215ms (3 trials) |
| Timeline figure annotation | within 0.5s |

So at the defaults it takes **0.2–0.5s**, and it grows linearly with `SAMPLE_MS`.
NVML reports utilization as a [windowed average](https://docs.nvidia.com/deploy/nvml-api/index.html)
of 1/6s to 1s, so on a product with the 1s window the worst case is about 1.2s.

**A short request runs at 135MHz for that entire window.** While clamped, compute is 0.089x
(~11x slower), so a request that finishes before the release completes pays the full penalty.
Measuring the SM clock from inside the kernel: work launched while clamped ran at 126–127MHz for
its first 80 / 95 / 110ms (three trials) and only reached 1300MHz after 180 / 215 / 215ms. A 0.5s
workload spent 185ms of its 500ms (37%) at 126MHz.

- The 20s benchmark averages below (−0.49%) dilute that 0.2–0.5s stall. Judge the impact by the
  latency numbers above, not by the aggregate.
- A GPU that never goes 30s without load is never clamped. But request-driven servers do have
  >30s gaps: on our live inference box the clamp engaged **141 times in 24h**. Raise
  `IDLE_SECONDS` (e.g. `120`) if you do not want that.
- The daemon itself costs about **380 CPU-seconds/day/instance** (~0.44% of one core) and
  17–23MB RSS, most of it the `SAMPLE_MS=200` poller.

## Requirements

- Linux + systemd (the template unit `nvidia-idle-clock@.service` is used)
- NVIDIA driver and `nvidia-smi`, with `-lgc` / `-rgc` available (`nvidia-smi -h` lists `-lgc`)
- Volta or newer (sm70+); `-lgc` only exists from Volta on
- root (`-lgc` / `-rgc` are root-only)
- bash 4.2+ and coreutils. Nothing else — no NVAPI, no CUDA toolkit, no build step

## Supported hardware

| GPU | Status |
|---|---|
| Tesla V100-PCIE-32GB (sm70) | **Verified** — latency measurements and idle power (37.85W → 25.22W, ~31GiB held in VRAM) |
| Tesla PG500-216 (GV100 32GB, sm70) | **Verified** — clamp ladder, performance measurements and idle power (42.43W → 28.85W, ~31GiB held in VRAM) |
| Tesla V100-SXM2 / V100-PCIE-16GB | Unverified (same sm70 with the same 135MHz floor, but not tested on hardware) |
| Other sm70 parts (Quadro GV100 etc.) | Unverified |
| Newer than Volta (Turing / Ampere / Ada / Hopper) | **Unsupported** — `-lgc` exists, but this project has not been tested on them (the saving is unverified too) |
| Older than Volta (Pascal etc.) | **Unsupported** — `nvidia-smi` has no `-lgc` |

The daemon validates the requested clock range at startup and refuses to start if `IDLE_CAP`
exceeds that GPU's `clocks.max.gr`. If `-lgc` is rejected at runtime it warns with the driver's
error and retries with backoff instead of pretending to have clamped. The default `IDLE_CAP` /
`MIN_CLK` of 135MHz is the V100 floor — set it to the real floor on other cards.

## Install

**Do not use this on a shared GPU without agreement** (`-lgc` affects the whole card — see
"Shared GPUs").

```bash
git clone https://github.com/kuraneko1/nvidia-idle-clock.git
cd nvidia-idle-clock
sudo ./install.sh          # 1 instance per detected GPU
sudo ./install.sh 0 1      # pick GPUs explicitly
```

Manual:

```bash
sudo install -m 0755 nvidia-idle-clock          /usr/local/sbin/nvidia-idle-clock
sudo install -m 0644 nvidia-idle-clock@.service /etc/systemd/system/nvidia-idle-clock@.service
sudo systemctl daemon-reload
sudo systemctl enable --now nvidia-idle-clock@0.service   # GPU 0
sudo systemctl enable --now nvidia-idle-clock@1.service   # GPU 1
```

### Installer options

`install.sh` parses its own options instead of treating argv as GPU names.

| Option | Effect |
|---|---|
| `-h`, `--help` | print usage and exit |
| `-V`, `--version` | print the installer version and the daemon sha256, exit |
| `-n`, `--dry-run` | print every action without writing anything (does not need root) |
| `--force` | skip the source-tree trust check only |
| `--gpus LIST` | GPU list, comma or space separated (may be repeated) |
| `--` | treat every following argument as a GPU |
| `[GPU ...]` | `nvidia-smi` index, GPU UUID or MIG identifier |

`uninstall.sh`:

| Option | Effect |
|---|---|
| `-h`, `--help` | print usage and exit |
| `-n`, `--dry-run` | print every action without changing anything |
| `--keep-clocks` | remove the units and files but leave the clock locks in place |

Both validate before writing. The `install.sh` preflight checks the required commands
(`nvidia-smi`, `systemctl`, `install`, `sha256sum`, `stat`, `cp`, `cmp`, `date`), that systemd is
running, and that the payload files exist; an argument error exits 2 and an environment error
exits 1, in both cases **before anything is written**. Once writing has started, a failure runs
the rollback: newly created files are removed and replaced files are restored from a timestamped
backup (`<path>.bak.<YYYYMMDDTHHMMSS>`).

- Replacing an existing file always leaves a `.bak.<timestamp>` copy (a second install within the
  same second adds the PID).
- Instances that were already active are switched to the new code with `systemctl try-restart`
  only when the payload changed. A failed restart is reported with exit 1 but the installed units
  are kept.
- A checkout used for a root install must be owned by root or by the user running sudo, must not
  be world writable, and must not be group writable through a shared group; otherwise it is
  refused without `--force` (nothing is written).
- `uninstall.sh` leaves the files in place when a unit cannot be stopped (a running daemon must
  not be left without its unit). After removal it verifies that the files are gone and checks the
  `-rgc` result.

## Daemon command line

```
usage: nvidia-idle-clock [-h|--help] [-V|--version] [-n|--dry-run]
```

| Option | Effect |
|---|---|
| `-h`, `--help` | print usage and exit |
| `-V`, `--version` | print `nvidia-idle-clock 0.2.0` and exit |
| `-n`, `--dry-run` | validate the configuration, print the resolved plan and exit; never calls `-lgc` / `-rgc` |
| none | run the daemon in the foreground (systemd `Type=simple`) |

`--help` / `--version` are handled before configuration validation; `--dry-run` runs after
validation and GPU resolution but before the first `-lgc` / `-rgc`. Unknown options and positional
arguments print `level=error msg="unknown argument"` plus the usage line on stderr and exit **2**.

```
$ nvidia-idle-clock --dry-run
level=info msg="dry run" gpu=0 min_mhz=135 cap_mhz=135 idle_s=30 sample_ms=200 nvidia_smi=/usr/bin/nvidia-smi
level=info msg="would clamp when idle" gpu=0 after_idle_s=30 util_threshold_pct=0 min_mhz=135 cap_mhz=135 skip_if_low=1
level=info msg="would unlock on use or exit" gpu=0 trigger=util,exit
```

Exit status:

| Code | Meaning |
|---|---|
| `0` | clean stop (SIGTERM / SIGINT), or `--help` / `--version` / `--dry-run` succeeded |
| `1` | runtime failure (no usable GPU, `nvidia-smi` missing, stalled stream, unlock failed, ...) |
| `2` | invalid configuration or unknown argument |

Configuration is validated before any GPU is touched: an invalid value logs
`level=error msg="invalid config"` and exits 2, a missing `nvidia-smi` exits 1.

## Per-GPU assignment

The instance name is the target GPU (`nvidia-smi` index).
To assign an instance to an arbitrary GPU, or to give one GPU different settings, use a drop-in:

```bash
sudo systemctl edit nvidia-idle-clock@0.service
```

```ini
[Service]
Environment=GPU=2            # assign to another GPU
Environment=IDLE_CAP=555     # relax the clamp for this GPU only
Environment=IDLE_SECONDS=120
```

```bash
sudo systemctl restart nvidia-idle-clock@0.service
```

**Do not point `GPU=` at a GPU that another instance already uses.** Two instances then fight over
the same card, and the `-rgc` on one instance's start/stop releases the other's clamp (with no
warning). By default the instance name *is* the GPU index, so this cannot happen by accident.

Example:

| Instance | GPU | Notes |
|---|---|---|
| `nvidia-idle-clock@0.service` | 0 | default (`IDLE_CAP=135`) |
| `nvidia-idle-clock@1.service` | 1 | drop-in with `IDLE_SECONDS=120`, etc. |

## Uninstall

```bash
cd nvidia-idle-clock
sudo ./uninstall.sh
```

Manual:

```bash
sudo systemctl disable --now 'nvidia-idle-clock@*'
sudo rm -f /etc/systemd/system/nvidia-idle-clock@.service /usr/local/sbin/nvidia-idle-clock
sudo systemctl daemon-reload
for g in $(nvidia-smi --query-gpu=index --format=csv,noheader); do sudo nvidia-smi -i "$g" -rgc; done
```

## Measurements

Rig: Tesla V100-PCIE-32GB + Tesla PG500-216 (GV100 32GB x2) / driver 580.178.04 / no NVLink.
20s averages unless stated otherwise. Power is the GPU board sensor (`power.draw`), so PSU
losses, CPU and disks are excluded. The older "VRAM held" runs used a CUDA context holding
3.6GiB / 8GiB. The new A/B measurement had an inference server holding ~31GiB/GPU (the GPUs
themselves were idle).

Over a 26h production run the clamp was held 77.6% / 71.0% of the time (GPU0 / GPU1),
with 141 clamp events in 24h.

### Idle power — effectiveness depends on VRAM state

![Bar chart of idle power (older 3.6GiB / 8GiB-held run): V100-PCIE-32GB drops from 36.3W to 24.9W, PG500-216 from 40.9W to 28.4W, and with VRAM empty both cards stay at 24.6/28.1W](img/idle-power.png)

**Method.** 4 × 600s samples, `nvidia-smi --loop-ms=500`, first 60s dropped. n≈1060–1067
samples per GPU, stdev 0.05–0.33W. `utilization.gpu` was 0.0 (mean and maximum) in every
sample — the GPUs were idle, the LLM server only held VRAM. A1/A2 and B1/B2 are adjacent pairs
on the same board, so thermal drift cancels.

| State | GPU0 (V100-PCIE-32GB) | GPU1 (PG500-216) | Combined |
|---|---|---|---|
| VRAM held (~31GiB/GPU), clamped 135MHz (A1) | 25.22W | 28.85W | 27.04W |
| VRAM held, no clamp (driver 1230/1260MHz) (A2) | 37.85W | 42.43W | 40.14W |
| **Saving while VRAM is held** | **12.63W** | **13.58W** | **26.21W** |
| VRAM empty, no clamp (B1) | 25.50W | 29.20W | 27.35W |
| VRAM empty, clamped (B2) | 25.45W | 28.97W | 27.21W |
| **Saving while VRAM is empty** | **0.05W** | **0.23W** | **0.28W ≈ 0 (noise)** |

- **Only the VRAM-held case saves anything.** With VRAM empty the driver drops to 135MHz by
  itself, so the clamp makes no difference (0.05W / 0.23W is noise). While VRAM is held the
  driver never comes down, which is the only case this tool targets.
- The measured default idle step differs per board (GPU0 1230MHz, GPU1 1260MHz). "1260MHz" is
  the GPU1 (PG500-216) value, not something that applies to both cards.
- Held for a full year, the combined 26.21W saving is **229.6kWh/year**. At idle duties of
  25/50/75/100% that is **57.4 / 114.8 / 172.2 / 229.6kWh/year**.
- At **37 JPY/kWh** — the Chubu Electric Power 従量電灯B marginal rate for the 300kWh+ tier
  including the fuel-cost adjustment and the renewable surcharge, effective 2026-11-01 — that
  is about **8,494 JPY/year**. At the 32.89 JPY/kWh rate through 2026-10-31 it is
  **7,551 JPY/year**. This is a Shizuoka example and the fuel-cost adjustment changes monthly.
- Conditions: driver 580.178.04, two V100-class boards, no NVLink, GPU board power only
  (PSU losses, CPU and disks are excluded). The figures are the delta of adjacent same-board
  pairs.

### Clock ceiling (PG500-216 / 8GiB in VRAM, 20s each)

![Bar chart of the clamp ladder: no clamp 1260MHz / 40.94W, -lgc 135,555 gives 555MHz / 31.73W, -lgc 135,300 gives 300MHz / 29.52W, -lgc 135,135 gives 135MHz / 28.40W](img/clamp-ladder.png)

| Clamp | Actual clock | Power |
|---|---|---|
| none | 1260 MHz | 40.94 W |
| `-lgc 135,555` | 555 MHz | 31.73 W |
| `-lgc 135,300` | 300 MHz | 29.52 W |
| `-lgc 135,135` | 135 MHz | 28.40 W |

### Performance impact (PG500-216 / 8GiB in VRAM)

![Bar chart of throughput ratios: while clamped DtoD copy is 19.4%, memset 12.0% and SGEMM 4096 8.9%; after release and on the realistic path (load injected, daemon auto-releases) all return to about 100%](img/perf.png)

| Test | No clamp | Clamped @135MHz | After release | Realistic path\* |
|---|---|---|---|---|
| DtoD copy | 1024.7 GB/s | 198.7 GB/s | 1024.6 GB/s | 1019.7 GB/s (−0.49%) |
| memset | 1114.9 GB/s | 133.8 GB/s | 1114.9 GB/s | 1114.8 GB/s (−0.01%) |
| SGEMM 4096 (FP32) | 12.36 TFLOP/s | 1.10 TFLOP/s | 12.36 TFLOP/s | 12.36 TFLOP/s (±0%) |

\* load injected while clamped, daemon auto-releases (20s budget)

> **Note on the figure title.** `img/perf.png` is titled "Tesla V100", but the 8GiB-held run behind it
> was made on the **PG500-216** (GV100 32GB). A V100-PCIE-32GB (4096-bit HBM2 at 877MHz,
> ~898GB/s theoretical) cannot reach the memset figure of 1114.9GB/s, so do not read this table as
> V100-PCIE-32GB absolute numbers. Absolute values are card-dependent; compare the clamped and
> released ratios instead. The legend overlapping the plot is a known cosmetic issue.

### Sample log

One instance covering several GPUs (`GPU=0,1`). journald adds the timestamp, the script does not
print one.

```
$ journalctl -u nvidia-idle-clock@0 -o cat
level=info msg="started" gpu=0,1 min_mhz=135 cap_mhz=135 idle_s=30 sample_ms=200 util_threshold_pct=0 reassert_s=30 skip_if_low=1 nvidia_smi=/usr/bin/nvidia-smi
level=info msg="clamp verified" gpu=0 trigger=idle was_mhz=1230 observed_mhz=135 min_mhz=135 cap_mhz=135
level=info msg="clamp verified" gpu=1 trigger=idle was_mhz=1260 observed_mhz=135 min_mhz=135 cap_mhz=135
level=info msg="unlocked" gpu=0 trigger=util util_pct=42
level=info msg="stream lost" retry_s=2 stderr=""
level=info msg="unlocked" gpu=0 trigger=exit
level=info msg="unlocked" gpu=1 trigger=exit
level=info msg="exit" gpu=0,1 rc=0
```

- `level=` and `msg="..."` are the first two fields. `msg` is a stable identifier, so grep for
  `msg="..."`, never for free text.
- `level=` is not a syslog priority, so `journalctl -p warning` will not filter on it; use
  `journalctl -u nvidia-idle-clock@0 -g 'level=(warn|error)'`.
- A clean SIGTERM stop ends with `msg="exit" rc=0`; if the release failed, `msg="unlock failed"`
  is followed by `msg="exit" rc=1`.
- `was_mhz` is 1230 for GPU0 but 1260 for GPU1 because the default idle step differs per board.
  Do not assume a single 1260MHz value.

## Configuration

Set `Environment=` per instance. `%i` (the instance name) is the default GPU.

| Variable | Default | Description |
|---|---|---|
| `GPU` | `%i` | Target GPU (nvidia-smi index, comma-separated) |
| `IDLE_CAP` | `135` | Clock ceiling clamped to while idle (MHz) |
| `MIN_CLK` | `135` | Clock floor (MHz) |
| `IDLE_SECONDS` | `30` | Idle seconds before clamping |
| `SAMPLE_MS` | `200` | Utilization sampling interval (ms) |
| `UTIL_THRESHOLD` | `0` | Utilization at or below this counts as idle (%) |
| `REASSERT_SECONDS` | `30` | Re-apply interval for the clamp (s) |
| `SKIP_IF_LOW` | `1` | Do not clamp GPUs already idling at a low clock |
| `NVSMI` | `nvidia-smi` on `PATH` | Path to the `nvidia-smi` to use (testing, unusual layouts) |

A non-existent index in `GPU` is dropped with a warning; if none remain, startup fails.
An invalid value logs `msg="invalid config"` and exits 2; a missing `nvidia-smi` exits 1.
Both happen before the daemon touches any GPU.

## Behaviour

- Polls target GPU utilization every `SAMPLE_MS` (each instance independent)
- `IDLE_SECONDS` idle → `nvidia-smi -i N -lgc MIN_CLK,IDLE_CAP`
- Utilization > `UTIL_THRESHOLD` → release with `-rgc`
- With `SKIP_IF_LOW=1`, already-low GPUs are left alone (nothing to do when VRAM is empty)
- If the utilization stream delivers nothing for `max(5s, 5×SAMPLE_MS)`, the `nvidia-smi` child is
  stopped and the daemon exits 1 (`msg="utilization stream stale"`); systemd restarts it through
  `Restart=on-failure`
- When the stream ends, reconnect with exponential backoff (2→30s) and report the first stderr
  line in `msg="stream lost"`; 5 failed reconnects inside 60s log
  `msg="utilization stream unavailable"` and exit 1
- Non-numeric utilization (`[N/A]`) is treated as unavailable: a held clamp is released (safe
  side), the idle clock is reset, and the warning is logged once per streak
- Also runs `-rgc` at startup (this is not a "release only what I locked" implementation, so do not
  run it next to another tool that manages clocks)
- Releases with `-rgc` on stop/restart. SIGKILL, OOM and a `TimeoutStopSec` overrun cannot run the
  shell trap, so those paths cannot release (the unit has no `ExecStopPost`). The next start does
  run `-rgc` on every target GPU, which resets the clocks to the driver default

## Notes

- The clamp is **device-wide**. Only root can set or clear it. On shared GPUs, read "Shared GPUs"
  first.
- Only effective while VRAM is held. On a GPU with empty VRAM it does nothing (the driver drops
  to 135MHz by itself).
- While clamped, compute drops to 0.089x and bandwidth to 0.12–0.19x. Release takes the next sample
  period + the `-rgc` spawn + the driver ramp: 0.2–0.5s at the defaults, proportional to `SAMPLE_MS`.
- A GPU that is continuously inferring never reaches the idle state, so it is never clamped.
  Request-driven servers with >30s gaps do clamp (measured 141 times in 24h).
- On generations with several P-States (P40 etc.), P-State forcing may fit better:
  [nvidia-pstate](https://github.com/sasha0552/nvidia-pstate) /
  [nvidia-pstated](https://github.com/sasha0552/nvidia-pstated). Their READMEs carry no power
  figures and we have not measured a P40, so this README quotes no numbers.
- `-rgc` only restores the driver's default policy; it does not force a low clock. With VRAM held
  the clock is back at the driver-managed value within seconds (measured on PG500-216 / 8GiB held,
  1260MHz default: 135MHz / 28.51W → 3s later 1260MHz / 38.97W; 10s average 28.51W → 40.31W,
  **+11.8W / +29.3%**), and the saving is lost until the next re-assert (30s by default). It is a
  no-op only when there is no lock or VRAM is empty.

## Shared GPUs

**Do not use this on a shared GPU without agreement.** `-lgc` is a whole-card ceiling, not a
per-process setting.

- Only root can set or clear it. A non-root co-tenant can run neither `-lgc` nor `-rgc` (exit 4)
  and cannot release the clamp on their own.
- **A co-tenant cannot even tell the card is clamped.** The lock appears in neither
  `nvidia-smi -q -d CLOCK` nor any other `nvidia-smi -q` field; the only visible sign is
  `clocks.current.graphics` reading 135MHz.
- While device utilization is 0, every process and context on the card runs at 135MHz
  (MIG compute instances share the clock). The release comes one sample period + `-rgc` spawn +
  driver ramp later (0.2–0.5s at the defaults).
- If `Environment=GPU=` makes two instances point at the same card, the `-rgc` on one instance's
  start/stop releases the other's clamp for up to `REASSERT_SECONDS` (30s by default). No warning.
- Use it only on cards you own and nobody else uses (a workstation, a single-tenant inference box).

## Prior art / related work

Clocking down an idle datacenter GPU is not a new idea, and this project is deliberately a small,
dependency-free take on it. It is neither the first nor the only implementation; these are the
prior and related ones, and one of them may fit your GPUs better.

- **[sasha0552/nvidia-pstated](https://github.com/sasha0552/nvidia-pstated)** (GPL-3.0) — the
  reference daemon in this space. It forces P-States over NVAPI and idles GPUs automatically; the
  right answer for P40-class cards with several P-States. Its open
  **[PR #10](https://github.com/sasha0552/nvidia-pstated/pull/10)** adds a `--clock-mode` that locks
  clocks through NVML specifically for single-P-State GPUs including **V100** (maintainer review and
  commits as of 2026-09-12, not merged). If it lands it will do what this repo does, with more
  polish — check it first. The V100 limitation and V100 measurements were already documented in
  **[issue #6](https://github.com/sasha0552/nvidia-pstated/issues/6)** (January 2025).
- **[sasha0552/nvidia-pstate](https://github.com/sasha0552/nvidia-pstate)** (MIT) — the CLI / Python
  predecessor of the above, for manual P-State switching.
- **[dqs105/nvidia-powermizer](https://github.com/dqs105/nvidia-powermizer)** (GPL-3.0) —
  utilization-driven clock locking with hysteresis, on memory clocks.
- **[UzixLS/cmp50hx-unlock `idle-governor`](https://github.com/UzixLS/cmp50hx-unlock/blob/master/idle-governor/README.md)**
  — the same control loop in C for CMP 50HX, with the clearest measurements of how `-lgc` behaves
  (a *range* may not clamp at all; a single value does).
- **[mu-b/ai-dgxspark-power](https://github.com/mu-b/ai-dgxspark-power)** — `-lgc` on a schedule for
  GB10, with periodic re-assertion.
- **[andyljones/coolgpus](https://github.com/andyljones/coolgpus)** (MIT) /
  **[LACT](https://github.com/ilya-zlobintsev/LACT)** (MIT) — the fan/power-cap side of the same
  problem; neither touches idle clocks.

NVIDIA itself does not provide this: `nvidia-persistenced` only keeps the driver loaded
([docs](https://docs.nvidia.com/deploy/driver-persistence/persistence-daemon.html)),
`nvidia-powerd` only raises the power budget on laptops
([docs](https://download.nvidia.com/XFree86/Linux-x86_64/580.76.05/README/dynamicboost.html)),
and `-lgc` has no idle-tracking variant
([man](https://man.archlinux.org/man/nvidia-utils/nvidia-smi.1.en)).

What this project actually adds:

- **No non-stock dependencies** — bash and `nvidia-smi` only; no NVAPI library, no CUDA toolkit,
  no build step
- **Per-GPU systemd template instances** — `nvidia-idle-clock@N.service` plus drop-ins, so each
  card can have its own settings
- **MIT license** — the main prior implementations above are GPL-3.0
- **Measurement-first documentation** — clamp ladder, post-release restoration, latency, and the
  daemon's own cost, all with the numbers and conditions stated

## License

MIT
