English | [日本語](README.md)

# nvidia-idle-clock

For NVIDIA GPUs that park at a high clock and never come down while something sits in VRAM.
A systemd daemon that clamps the clock ceiling with `nvidia-smi -lgc` **only while idle**,
and releases it the moment load appears. It runs **one independent instance per GPU**,
so each card can have its own settings.

| State | No clamp | Clamped @135MHz |
|---|---|---|
| V100-PCIE-32GB / 3.6GiB in VRAM | 36.3W (peak 44.7W) | **24.9W** |
| PG500-216 / 8GiB in VRAM | 40.9W | **28.4W** |
| VRAM empty | 24.6W / 28.1W | no change |

> **It only helps while VRAM is held.**
> With VRAM empty the driver comes down to 135MHz by itself, so the clamp makes no difference
> (measured delta: 0.0W). Conversely, **while VRAM is held the driver never comes down** —
> PG500-216 + 8GiB stayed at 1260MHz / 40–41W for a full **180 seconds**.
> That is the only case this tool targets.
> Compute and memory bandwidth are **fully restored (0.01% error)** after the clamp is released.

> **P-State forcing does not work on V100 (Volta).**
> NVAPI `NvAPI_GPU_SetForcePstate()` returns `NVAPI_ERROR` for every P-State (8–15) with `fallback=0`.
> [nvidia-pstate](https://github.com/sasha0552/nvidia-pstate) /
> [nvidia-pstated](https://github.com/sasha0552/nvidia-pstated), which target P40/P100, do not work here
> (with `fallback=2` the GPU just pins to 555MHz, **+3W worse** than the driver's natural 135MHz idle).
> Hence a clock-range lock instead of P-State forcing.

## How it differs from stock

![](img/timeline.png)

| | Stock (driver-managed) | With this daemon |
|---|---|---|
| Clock while VRAM held and idle | stays at 1260–1380MHz, never drops | **135MHz** (after 30s idle) |
| Power in that state | 39–45W | **24.9–28.4W** |
| When load arrives | runs as-is | detected within 200ms and released (only that window runs at 135MHz) |
| 30s after load stops | still at the high clock | back to 135MHz |
| When VRAM is empty | driver drops to 135MHz by itself | **does nothing** (same) |
| P-State | stays P0 | stays P0 (unchanged) |

### What you can observe

The only externally visible difference is `clocks.current.graphics` reading 135MHz.
`PState` stays P0, `clocks.max.graphics` stays 1380MHz, and the `-lgc` lock never shows up in the report.

```
$ nvidia-smi --query-gpu=index,pstate,clocks.gr,clocks.max.gr,power.draw --format=csv
index, pstate, clocks.current.graphics [MHz], clocks.max.graphics [MHz], power.draw [W]
0, P0, 135 MHz, 1380 MHz, 24.95 W
1, P0, 135 MHz, 1380 MHz, 27.87 W
```

### What does not change

- P-State (V100 is always P0)
- Process VRAM, CUDA contexts, numerical results
- persistence mode, power limits, PCIe link, fan control
- Maximum clock (returns to 1380MHz once released)
- Stopping the service runs `-rgc`, restoring the original state

### Cost

- The first **≤200ms** (`SAMPLE_MS`) after load arrives runs at 135MHz
  → −0.49% on a 20s DtoD benchmark; memset and SGEMM are ±0%
- A GPU that never goes 30s without load is never clamped (no benefit for continuous inference)

## Install

```bash
git clone https://github.com/kuraneko1/nvidia-idle-clock.git
cd nvidia-idle-clock
sudo ./install.sh          # one instance per detected GPU
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

### Idle power — effectiveness depends on VRAM state

![](img/idle-power.png)

### Clock ceiling (PG500-216 / 8GiB in VRAM, 20s each)

![](img/clamp-ladder.png)

| Clamp | Actual clock | Power |
|---|---|---|
| none | 1260 MHz | 40.94 W |
| `-lgc 135,555` | 555 MHz | 31.73 W |
| `-lgc 135,300` | 300 MHz | 29.52 W |
| `-lgc 135,135` | 135 MHz | 28.40 W |

### Performance impact (8GiB in VRAM)

![](img/perf.png)

| Test | No clamp | Clamped @135MHz | After release | Realistic path\* |
|---|---|---|---|---|
| DtoD copy | 1024.7 GB/s | 198.7 GB/s | 1024.6 GB/s | 1019.7 GB/s (−0.49%) |
| memset | 1114.9 GB/s | 133.8 GB/s | 1114.9 GB/s | 1114.8 GB/s (−0.01%) |
| SGEMM 4096 (FP32) | 12.36 TFLOP/s | 1.10 TFLOP/s | 12.36 TFLOP/s | 12.36 TFLOP/s (±0%) |

\* load injected while clamped, daemon auto-releases (20s budget)

Test rig: Tesla V100-PCIE-32GB + Tesla PG500-216 (GV100 32GB x2) / driver 580.178.04

### Sample log

```
$ journalctl -u nvidia-idle-clock@0 -o cat
2026-10-19 01:59:06 gpu0 アイドル 30s 継続 (1230MHz): 135-135MHz にクランプ
2026-10-19 02:53:09 gpu0 活動検出 (util=69%): ロック解除
2026-10-19 02:53:57 gpu0 アイドル 30s 継続 (1380MHz): 135-135MHz にクランプ

$ journalctl -u nvidia-idle-clock@1 -o cat
2026-10-19 15:25:15 開始 gpu=1 cap=135-135MHz idle=30s sample=200ms skip_if_low=1
# GPU1 has empty VRAM, so it is never clamped (the driver comes down to 135MHz on its own)
```

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

A non-existent index in `GPU` is dropped with a warning; if none remain, startup fails.

## Behaviour

- Polls target GPU utilization every `SAMPLE_MS` (each instance independent)
- `IDLE_SECONDS` idle → `nvidia-smi -i N -lgc MIN_CLK,IDLE_CAP`
- Utilization > `UTIL_THRESHOLD` → immediate `-rgc`
- With `SKIP_IF_LOW=1`, already-low GPUs are left alone (nothing to do when VRAM is empty)
- Reconnects 2s after the utilization stream drops
- Always runs `-rgc` on exit

## Notes

- Only effective while VRAM is held. On a GPU with empty VRAM it does nothing.
- While clamped, compute drops to 0.089x and bandwidth to 0.12–0.19x. Detection is as fast as `SAMPLE_MS`.
- A GPU that is continuously inferring never reaches the idle state, so it is never clamped.
- On generations where P-State forcing works (P40/P100), prefer
  [nvidia-pstate](https://github.com/sasha0552/nvidia-pstate) (45W → 10W).
- `-rgc` only removes the lock; it does not raise the clock while idle (it rises on next use).

## License

MIT
