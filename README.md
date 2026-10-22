[English](README.en.md) | 日本語

# nvidia-idle-clock

VRAM に何か載ると高クロックに張り付いたままになる NVIDIA GPU 向け。
**アイドル時だけ** `nvidia-smi -lgc` でクロック上限を絞り、負荷を検出すると解除する systemd デーモンで、
GPU ごとに独立したインスタンスとして動く (依存は bash と `nvidia-smi` だけ)。

> **対応範囲 — 先にここを読む**
>
> - **Linux + systemd + NVIDIA Volta / sm70 (Tesla V100 系) のみ。** Windows・macOS・WSL・systemd の無いコンテナは非対応。
> - **検証済みは V100-PCIE-32GB と PG500-216 のみ。** 他の sm70 (V100-SXM2 / V100-PCIE-16GB / Quadro GV100) は未検証、Volta より新しい世代は非対応 (未検証)。要求した上限がカードの最大を超える場合は起動を拒否し、`-lgc` が拒否されても黙って「クランプした」ことにはしない。
> - bash 4.2+、インストール時の root (`-lgc` は root 専用)、`nvidia-smi -lgc` が使える driver が必要。
> - **VRAM をアイドルプロセスが保持している間だけ効く。** VRAM が空なら driver が既に低クロックまで落としているので、何も起きない (これが正常)。

**実測: VRAM 保持中は 2 枚合計で 26.2W 節電、VRAM が空なら 0W** → [実測データ](docs/reference.ja.md#実測データ)

![実測: VRAM 保持中は 2 枚合計 26.2W 節電 (1 枚あたり平均 40.1 → 27.0W)、VRAM が空なら 0W (27.3 → 27.2W)](img/ja/hero.png)

## クイックインストール

```bash
git clone https://github.com/kuraneko1/nvidia-idle-clock.git
cd nvidia-idle-clock
sudo ./install.sh          # 検出した全 GPU に 1 インスタンスずつ
```

確認:

```bash
systemctl status 'nvidia-idle-clock@*'
journalctl -u nvidia-idle-clock@0 -f
```

30 秒無負荷が続くと最初のクランプが入る。アンインストールは `sudo ./uninstall.sh`。

## 30秒デモ

V100 実機で、サービスを動かさずにクランプと解除を確認する。未インストールならリポジトリ内の `./nvidia-idle-clock` を同じ引数で実行する。電力を見るターミナルを別に開く。

```bash
# 1) VRAM を 512MiB だけ保持するアイドルプロセス (ツールの対象ケース)
cat >/tmp/hold.cu <<'EOF'
#include <cuda_runtime.h>
#include <unistd.h>
int main(){ void*p; if (cudaMalloc(&p, 1<<29)) return 1; cudaFree(0); sleep(600); return 0; }
EOF
nvcc -o /tmp/hold /tmp/hold.cu
# CUDA toolkit が無ければ torch 版: python3 -c 'import torch,time; x=torch.zeros(1<<27,device="cuda"); time.sleep(600)'
/tmp/hold &

# 2) クロックと電力を監視 (別ターミナル)
watch -n1 'nvidia-smi --query-gpu=index,clocks.gr,power.draw,utilization.gpu --format=csv,noheader'

# 3) 5 秒無負荷でクランプするデーモンをフォアグラウンド実行 (Ctrl-C で解除)
sudo env GPU=0 IDLE_SECONDS=5 /usr/local/sbin/nvidia-idle-clock

# 4) 後片付け (通常は Ctrl-C で解除済み。念のため)
kill %1
sudo nvidia-smi -i 0 -rgc
```

- 利用率 0% が 5 秒続くと 135MHz に落ち、電力が下がる (V100-PCIE-32GB / 約31GiB 保持の実測で 37.8 → 25.2W)。フォアグラウンド出力に `msg="clamp verified"` が出る (journal 不要)。
- ホルダを kill するか、カーネルを 1 つ動かすと解除される。解除は次のサンプル周期 + `-rgc` + driver 復帰で約 0.2〜0.5 秒。
- `cudaMalloc` が失敗する場合は空き VRAM が無い。何か解放するか、デモを諦める。
- **VRAM が空だと何も見えない。** driver が既に 135MHz なので比較対象が無い (これが正常)。
- GPU を複数使うなら `GPU=0,1` (このデモは `GPU=0`)。サービスを既に入れている場合は先に `sudo systemctl stop 'nvidia-idle-clock@*'` (二重起動は exit 3)。共有 GPU では行わない。

## やってはいけないこと

- ❌ 共有 GPU / 他人のジョブが動いているカードで、合意なく使う。`-lgc` はカード全体の上限で root 専用、同居テナントは解除できず、クランプされていることすら見えない。
- ❌ sm70 / V100 以外で使う (上記の対応範囲)。未検証 GPU の不具合を「対応済み」として報告しない。
- ❌ Windows / macOS / WSL / systemd の無いコンテナで動かす。
- ❌ 常時ビジーな GPU で効果を期待する (無負荷の窓が無いのでクランプしない)。
- ❌ レイテンシが重要な用途で使う (クランプ中に届いたリクエストは解除が入るまで最大約 11 倍遅い)。
- ❌ 同じ GPU に 2 インスタンスを向ける (`Environment=GPU=` の重複)。2 つ目は仕様どおり exit 3 で終了する。
- ❌ MIG 構成で有効化する (未検証。`-lgc` は MIG 単位ではなくカード全体に効く)。
- ❌ インストール先のバイナリを直接編集する。更新は `sudo ./install.sh` (バックアップして再起動する)。
- ❌ `uninstall.sh --keep-clocks` を恒久設定と思う。保持されるクランプは再起動か `nvidia-smi -rgc` まで。

## GPU を選ぶ

引数なしなら検出した全 GPU。`sudo ./install.sh 0 1` や `sudo ./install.sh --gpus 0,2` で
index を選べる (GPU UUID も可)。GPU ごとに `nvidia-idle-clock@<index>.service` が 1 つ動き、
設定は `systemctl edit` の drop-in で変える (→ [GPU ごとの割り当て](docs/reference.ja.md#gpu-ごとの割り当て))。

## 必要なもの

- Linux + systemd (255 で検証、240 以降を想定)。Windows / macOS / WSL / systemd の無いコンテナは非対応
- NVIDIA driver と `nvidia-smi`。`nvidia-smi -h` に `-lgc` があること
- Volta 以降 (sm70)。検証済みは V100-PCIE-32GB と PG500-216 のみ → [対応ハードウェア](docs/reference.ja.md#対応ハードウェア)
- bash 4.2+、coreutils、util-linux の `flock` (任意。無い場合は GPU 排他だけ無効)
- インストール時の root (`-lgc` / `-rgc` は root 専用)

共有 GPU では事前の合意が必要 (→ [共有 GPU](docs/reference.ja.md#共有-gpu))。

## ドキュメント

- [docs/reference.ja.md](docs/reference.ja.md) — 設定・CLI・動作・状態ディレクトリ・共有 GPU・先行事例・実測データ・トラブルシュート
- [docs/reference.en.md](docs/reference.en.md) — 同じ内容の英語版
- [README.en.md](README.en.md) — English quick start

## ライセンス

MIT
