English | [日本語](README.md)

# nvidia-idle-clock

For NVIDIA GPUs that park at a high clock and never come down while something sits in VRAM.
A systemd daemon that clamps the clock ceiling with `nvidia-smi -lgc` **only while idle** and
releases it when load appears; it runs one independent instance per GPU and needs only bash
and `nvidia-smi`.

**Measured: 26.2W saved while VRAM is held (two-card total), 0W when VRAM is empty** → [Measurements](docs/reference.en.md#measurements)

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

## Choose GPUs

With no argument every detected GPU is used. Pick indices with `sudo ./install.sh 0 1` or
`sudo ./install.sh --gpus 0,2` (GPU UUIDs are accepted too). One
`nvidia-idle-clock@<index>.service` runs per GPU; change settings per GPU with a
`systemctl edit` drop-in (→ [Per-GPU assignment](docs/reference.en.md#per-gpu-assignment)).

## Requirements

- Linux + systemd
- an NVIDIA driver with `-lgc` (Volta or newer)
- root for the install

On a shared GPU, get agreement first (→ [Shared GPUs](docs/reference.en.md#shared-gpus)).

## Documentation

- [docs/reference.en.md](docs/reference.en.md) — configuration, CLI, behaviour, state directory, shared GPUs, prior art, measurements, troubleshooting
- [docs/reference.ja.md](docs/reference.ja.md) — the same in Japanese
- [README.md](README.md) — 日本語クイックスタート

## License

MIT
