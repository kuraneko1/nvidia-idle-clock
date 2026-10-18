English | [日本語](README.md)

# nvidia-idle-clock

A systemd daemon for NVIDIA GPUs that park at a high clock and burn 36–45W while idle
as soon as anything sits in VRAM. It clamps the clock ceiling with `nvidia-smi -lgc`
while idle, and releases it the moment load appears.
It runs **one independent instance per GPU**, so each card can have its own settings.

| Tesla V100-PCIE-32GB (3.6GiB in VRAM) | Before | After |
|---|---|---|
| Idle power | 36.3W (peak 44.7W) | **24.9W** |
| Compute / memory bandwidth (after release) | — | **fully restored, 0.01% error** |

> **P-State forcing does not work on V100 (Volta).**
> NVAPI `NvAPI_GPU_SetForcePstate()` returns `NVAPI_ERROR` for every P-State (8–15) with `fallback=0`.
> [nvidia-pstate](https://github.com/sasha0552/nvidia-pstate) /
> [nvidia-pstated](https://github.com/sasha0552/nvidia-pstated), which target P40/P100, do not work here
> (with `fallback=2` the GPU just pins to 555MHz, **+3W worse** than the driver's natural 135MHz idle).
> Hence a clock-range lock instead of P-State forcing.

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

![](img/idle-power.png)

![](img/clamp-ladder.png)

![](img/perf.png)

| Test | No clamp | Clamped @135MHz | After release | Realistic path\* |
|---|---|---|---|---|
| DtoD copy | 1024.7 GB/s | 198.7 GB/s | 1024.6 GB/s | 1019.7 GB/s (−0.49%) |
| memset | 1114.9 GB/s | 133.8 GB/s | 1114.9 GB/s | 1114.8 GB/s (−0.01%) |
| SGEMM 4096 (FP32) | 12.36 TFLOP/s | 1.10 TFLOP/s | 12.36 TFLOP/s | 12.36 TFLOP/s (±0%) |

\* load injected while clamped, daemon auto-releases (20s budget)

Test rig: Tesla V100-PCIE-32GB + Tesla PG500-216 (GV100 32GB x2) / driver 580.178.04

### Sample output

```
$ nvidia-smi --query-gpu=index,name,clocks.gr,power.draw --format=csv
index, name, clocks.current.graphics [MHz], power.draw [W]
0, Tesla V100-PCIE-32GB, 135 MHz, 24.94 W
1, Tesla PG500-216,       135 MHz, 27.67 W

$ journalctl -u nvidia-idle-clock@0 -o cat
01:41:02 開始 gpu=0 cap=135-135MHz idle=30s sample=200ms skip_if_low=1
01:41:37 gpu0 アイドル 30s 継続 (1380MHz): 135-135MHz にクランプ
01:44:10 gpu0 活動検出 (util=58%): ロック解除
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
- With `SKIP_IF_LOW=1`, already-low GPUs are left alone (clamping an empty GPU costs +0.7–2W)
- Reconnects 2s after the utilization stream drops
- Always runs `-rgc` on exit

## Notes

- While clamped, compute drops to 0.089x and bandwidth to 0.12–0.19x. Detection is as fast as `SAMPLE_MS`.
- On generations where P-State forcing works (P40/P100), prefer
  [nvidia-pstate](https://github.com/sasha0552/nvidia-pstate) (45W → 10W).
- `-rgc` only removes the lock; it does not raise the clock while idle (it rises on next use).

## License

MIT
