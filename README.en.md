English | [日本語](README.md)

# nvidia-idle-clock

For NVIDIA GPUs that park at a high clock and never come down while something sits in VRAM.
A systemd daemon that clamps the clock ceiling with `nvidia-smi -lgc` **only while idle** and
releases it when load appears; it runs one independent instance per GPU and needs only bash
and `nvidia-smi`.

> **Scope — read this first**
>
> - **Linux + systemd + NVIDIA Volta / sm70 (Tesla V100 family) only.** Windows, macOS, WSL and containers without systemd are not supported.
> - **Only V100-PCIE-32GB and PG500-216 are verified.** Other sm70 parts (V100-SXM2, V100-PCIE-16GB, Quadro GV100) are unverified; anything newer than Volta is unsupported (unverified). The daemon refuses to start when the requested cap exceeds the card's maximum, and never pretends to have clamped when `-lgc` is rejected.
> - bash 4.2+, root for the install (`-lgc` is root-only), and a driver whose `nvidia-smi` supports `-lgc`.
> - **It only saves power while an idle process holds VRAM.** With empty VRAM the driver already idles low and nothing happens — that is normal.

**Measured: 26.2W saved while VRAM is held (two-card total), 0W when VRAM is empty** → [Measurements](docs/reference.en.md#measurements)

![Measured: 26.2W saved across two cards while VRAM is held (per-GPU average 40.1 → 27.0W), 0W when VRAM is empty (27.3 → 27.2W)](img/en/hero.png)

## Quick install

```bash
git clone https://github.com/kuraneko1/nvidia-idle-clock.git
cd nvidia-idle-clock
sudo ./install.sh          # 1 instance per detected GPU
```

Check:

```bash
systemctl status 'nvidia-idle-clock@*'
journalctl -u nvidia-idle-clock@0 -f
```

The first clamp happens after ~30s of idle. Uninstall with `sudo ./uninstall.sh`.

## 30-second demo

On a real V100 host, with no service running. If the binary is not installed, run the repo copy `./nvidia-idle-clock` with the same arguments. Open a second terminal for the power watch.

```bash
# 1) hold 512MiB of VRAM with an idle process (the case this tool targets)
cat >/tmp/hold.cu <<'EOF'
#include <cuda_runtime.h>
#include <unistd.h>
int main(){ void*p; if (cudaMalloc(&p, 1<<29)) return 1; cudaFree(0); sleep(600); return 0; }
EOF
nvcc -o /tmp/hold /tmp/hold.cu
# no CUDA toolkit? torch instead: python3 -c 'import torch,time; x=torch.zeros(1<<27,device="cuda"); time.sleep(600)'
/tmp/hold &

# 2) watch the clocks and power (another terminal)
watch -n1 'nvidia-smi --query-gpu=index,clocks.gr,power.draw,utilization.gpu --format=csv,noheader'

# 3) run the daemon in the foreground, clamping after 5s idle (Ctrl-C releases)
sudo env GPU=0 IDLE_SECONDS=5 /usr/local/sbin/nvidia-idle-clock

# 4) cleanup (Ctrl-C already released; this is a safety net)
kill %1
sudo nvidia-smi -i 0 -rgc
```

- Within 5s of 0% utilisation the clock drops to 135MHz and power falls (V100-PCIE-32GB, measured at ~31GiB held: 37.8 → 25.2W). The foreground output shows `msg="clamp verified"` — no journal needed.
- Killing the holder, or starting any kernel, makes the daemon release. Release takes the next sample period + `-rgc` + driver recovery: about 0.2–0.5s.
- If `cudaMalloc` fails, the card has no free VRAM — free some or skip the demo.
- **With empty VRAM there is nothing to see**: the card already sits at 135MHz, so there is nothing to compare (that is normal).
- Use `GPU=0,1` for several GPUs (this demo uses `GPU=0`). If the service is already installed, stop it first with `sudo systemctl stop 'nvidia-idle-clock@*'` (a second instance exits 3). Do not run this on a shared GPU.

## Do not

- ❌ Use it on a shared GPU, or on a card another user's jobs are running on, without agreement. `-lgc` is a whole-card ceiling and root-only; co-tenants cannot release it and cannot even see it.
- ❌ Use it on anything other than sm70 / V100 (see the limits above); do not report bugs from unverified GPUs as supported.
- ❌ Run it on Windows / macOS / WSL, or in a container without systemd.
- ❌ Expect it to help on a continuously busy GPU (no idle window) — it will not clamp.
- ❌ Use it where request latency matters (a request that arrives while clamped runs up to ~11× slower until the release lands).
- ❌ Point two instances at the same GPU (`Environment=GPU=` duplicates); the second exits 3 by design.
- ❌ Enable it on MIG configurations (unverified; `-lgc` applies to the whole card, not per MIG slice).
- ❌ Hand-edit the installed binary under `/usr/local/sbin`; update with `sudo ./install.sh` (it backs up and restarts).
- ❌ Treat `uninstall.sh --keep-clocks` as persistent: the kept clamp lasts until reboot or an explicit `nvidia-smi -rgc`.

## Choose GPUs

With no argument every detected GPU is used. Pick indices with `sudo ./install.sh 0 1` or
`sudo ./install.sh --gpus 0,2` (GPU UUIDs are accepted too). One
`nvidia-idle-clock@<index>.service` runs per GPU; change settings per GPU with a
`systemctl edit` drop-in (→ [Per-GPU assignment](docs/reference.en.md#per-gpu-assignment)).

## Requirements

- Linux + systemd (tested on 255; older systemd ignores some sandbox directives with a warning, the daemon still runs). Windows / macOS / WSL / containers without systemd are not supported
- NVIDIA driver and `nvidia-smi`, with `-lgc` in `nvidia-smi -h`
- Volta or newer (sm70); only V100-PCIE-32GB and PG500-216 are verified → [Supported hardware](docs/reference.en.md#supported-hardware)
- bash 4.2+, coreutils, util-linux `flock` (optional; without it only the per-GPU exclusion is disabled)
- root for the install (`-lgc` / `-rgc` are root-only)

On a shared GPU, get agreement first (→ [Shared GPUs](docs/reference.en.md#shared-gpus)).

## Documentation

- [docs/reference.en.md](docs/reference.en.md) — configuration, CLI, behaviour, state directory, shared GPUs, prior art, measurements, troubleshooting
- [docs/reference.ja.md](docs/reference.ja.md) — the same in Japanese
- [README.md](README.md) — 日本語クイックスタート

## License

MIT
