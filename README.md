[English](README.en.md) | 日本語

# nvidia-idle-clock

VRAM に何か載ると高クロックに張り付いたままになる NVIDIA GPU 向け。
**アイドル時だけ** `nvidia-smi -lgc` でクロック上限を絞り、負荷を検出すると即解除する systemd デーモン。
**GPU ごとに独立したインスタンス**として動き、1枚ずつ別々の設定を割り当てられる。

| 状態 | クランプなし | クランプ 135MHz |
|---|---|---|
| V100-PCIE-32GB / VRAM 3.6GiB 保持 | 36.3W (最大 44.7W) | **24.9W** |
| PG500-216 / VRAM 8GiB 保持 | 40.9W | **28.4W** |
| VRAM 空 | 24.6W / 28.1W | 変化なし |

> **効くのは VRAM を保持している間だけ。**
> VRAM が空なら driver が自分で 135MHz まで落とすのでクランプは不要 (実測でクランプ有無の差は 0.0W)。
> 逆に **VRAM を保持している間は driver が降りない** — PG500-216 + 8GiB で
> 1260MHz / 40〜41W のまま **180秒** 経過するのを確認済み。ここが唯一の対象。
> クランプ解除後の計算能力・メモリ帯域は **誤差 0.01%** で完全復帰する。

> **V100 (Volta) では PState 強制が使えない。**
> NVAPI の `NvAPI_GPU_SetForcePstate()` は `fallback=0` で全 PState (8〜15) が `NVAPI_ERROR` を返す。
> P40/P100 向けの [nvidia-pstate](https://github.com/sasha0552/nvidia-pstate) /
> [nvidia-pstated](https://github.com/sasha0552/nvidia-pstated) は動作しない
> (`fallback=2` だと 555MHz に固定され、driver の自然アイドル 135MHz より **+3W 悪化**する)。
> そのため PState ではなくクロック範囲ロックで代用している。

## 通常との違い

![](img/timeline.png)

| | 通常 (driver 任せ) | 導入後 |
|---|---|---|
| VRAM 保持中・無負荷のクロック | 1260〜1380MHz のまま降りない | **135MHz** (30秒無負荷で) |
| そのときの電力 | 39〜45W | **24.9〜28.4W** |
| 負荷が来たとき | そのまま実行 | 200ms 以内に検出して解除 (その間だけ 135MHz) |
| 負荷が 30 秒途切れたとき | 高いクロックのまま | 135MHz に戻る |
| VRAM が空のとき | driver が自分で 135MHz まで落とす | **何もしない** (同じ) |
| PState | P0 のまま | P0 のまま (変化なし) |

### 観測される違い

クランプ中は `clocks.current.graphics` が 135MHz になるのが唯一の外形的な差。
`PState` は P0 のまま、`clocks.max.graphics` も 1380MHz のままで、`-lgc` はレポートに現れない。

```
$ nvidia-smi --query-gpu=index,pstate,clocks.gr,clocks.max.gr,power.draw --format=csv
index, pstate, clocks.current.graphics [MHz], clocks.max.graphics [MHz], power.draw [W]
0, P0, 135 MHz, 1380 MHz, 24.95 W
1, P0, 135 MHz, 1380 MHz, 27.87 W
```

### 変わらないもの

- PState (V100 は常に P0)
- プロセスの VRAM、CUDA コンテキスト、計算結果
- persistence mode、電力上限、PCIe リンク、ファン制御
- クロック上限 (解除後は 1380MHz まで戻る)
- サービス停止時は `-rgc` で元に戻る

### 代償

- 無負荷から負荷が来るまでの**最大 200ms** (`SAMPLE_MS`) は 135MHz で走る
  → 20秒ベンチで −0.49% (DtoD)、memset と SGEMM は ±0%
- 負荷が 30 秒以上途切れない GPU ではクランプされない (常時推論では効かない)

## インストール

```bash
git clone https://github.com/kuraneko1/nvidia-idle-clock.git
cd nvidia-idle-clock
sudo ./install.sh          # 検出した全 GPU に 1 インスタンスずつ
sudo ./install.sh 0 1      # GPU を指定する場合
```

手動:

```bash
sudo install -m 0755 nvidia-idle-clock          /usr/local/sbin/nvidia-idle-clock
sudo install -m 0644 nvidia-idle-clock@.service /etc/systemd/system/nvidia-idle-clock@.service
sudo systemctl daemon-reload
sudo systemctl enable --now nvidia-idle-clock@0.service   # GPU 0
sudo systemctl enable --now nvidia-idle-clock@1.service   # GPU 1
```

## GPU ごとの割り当て

インスタンス名がそのまま対象 GPU (`nvidia-smi` index) になる。
任意の GPU に割り当てたい場合や、GPU ごとに違う設定にしたい場合は drop-in で上書きする。

```bash
sudo systemctl edit nvidia-idle-clock@0.service
```

```ini
[Service]
Environment=GPU=2            # 別の GPU に割り当てる
Environment=IDLE_CAP=555     # この GPU だけクランプを緩める
Environment=IDLE_SECONDS=120
```

```bash
sudo systemctl restart nvidia-idle-clock@0.service
```

例:

| インスタンス | GPU | 用途 |
|---|---|---|
| `nvidia-idle-clock@0.service` | 0 | 既定 (`IDLE_CAP=135`) |
| `nvidia-idle-clock@1.service` | 1 | drop-in で `IDLE_SECONDS=120` など |

## アンインストール

```bash
cd nvidia-idle-clock
sudo ./uninstall.sh
```

手動:

```bash
sudo systemctl disable --now 'nvidia-idle-clock@*'
sudo rm -f /etc/systemd/system/nvidia-idle-clock@.service /usr/local/sbin/nvidia-idle-clock
sudo systemctl daemon-reload
for g in $(nvidia-smi --query-gpu=index --format=csv,noheader); do sudo nvidia-smi -i "$g" -rgc; done
```

## 実測データ

### アイドル消費電力 — VRAM 状態で効き目が変わる

![](img/idle-power.png)

### クロック上限別 (PG500-216 / VRAM 8GiB 保持中, 各20秒)

![](img/clamp-ladder.png)

| クランプ | 実クロック | 電力 |
|---|---|---|
| なし | 1260 MHz | 40.94 W |
| `-lgc 135,555` | 555 MHz | 31.73 W |
| `-lgc 135,300` | 300 MHz | 29.52 W |
| `-lgc 135,135` | 135 MHz | 28.40 W |

### クランプの性能影響 (VRAM 8GiB 保持)

![](img/perf.png)

| 項目 | クランプなし | 135MHz クランプ中 | 解除後 | 実運用パス\* |
|---|---|---|---|---|
| DtoD copy | 1024.7 GB/s | 198.7 GB/s | 1024.6 GB/s | 1019.7 GB/s (−0.49%) |
| memset | 1114.9 GB/s | 133.8 GB/s | 1114.9 GB/s | 1114.8 GB/s (−0.01%) |
| SGEMM 4096 (FP32) | 12.36 TFLOP/s | 1.10 TFLOP/s | 12.36 TFLOP/s | 12.36 TFLOP/s (±0%) |

\* クランプ状態に負荷投入 → デーモンが自動解除した場合 (20秒予算)

計測環境: Tesla V100-PCIE-32GB + Tesla PG500-216 (GV100 32GB x2) / driver 580.178.04

### 参考: 実機のログ

```
$ journalctl -u nvidia-idle-clock@0 -o cat
2026-10-19 01:59:06 gpu0 アイドル 30s 継続 (1230MHz): 135-135MHz にクランプ
2026-10-19 02:53:09 gpu0 活動検出 (util=69%): ロック解除
2026-10-19 02:53:57 gpu0 アイドル 30s 継続 (1380MHz): 135-135MHz にクランプ

$ journalctl -u nvidia-idle-clock@1 -o cat
2026-10-19 15:25:15 開始 gpu=1 cap=135-135MHz idle=30s sample=200ms skip_if_low=1
# VRAM が空の GPU1 にはクランプを当てない (driver が自分で 135MHz まで落とすため)
```

## 設定

インスタンスごとに `Environment=` で指定する。`%i` (インスタンス名) が既定の GPU。

| 変数 | 既定 | 説明 |
|---|---|---|
| `GPU` | `%i` | 対象 GPU (nvidia-smi index, カンマ区切り可) |
| `IDLE_CAP` | `135` | アイドル時にクランプする上限クロック MHz |
| `MIN_CLK` | `135` | 下限クロック MHz |
| `IDLE_SECONDS` | `30` | この秒数無負荷でクランプ |
| `SAMPLE_MS` | `200` | 利用率サンプリング間隔 ms |
| `UTIL_THRESHOLD` | `0` | これ以下の利用率をアイドルとみなす % |
| `REASSERT_SECONDS` | `30` | クランプ再適用の間隔 s |
| `SKIP_IF_LOW` | `1` | 既に低クロックでアイドル中の GPU にはクランプしない |

`GPU` に存在しない index を指定した場合は除外して警告を出す。全部無効なら起動に失敗する。

## 動作

- 対象 GPU の利用率を `SAMPLE_MS` 間隔で監視 (インスタンスごとに独立)
- `IDLE_SECONDS` 無負荷 → `nvidia-smi -i N -lgc MIN_CLK,IDLE_CAP`
- 利用率 > `UTIL_THRESHOLD` → 即 `-rgc`
- `SKIP_IF_LOW=1` のとき既に低クロックなら何もしない (VRAM が空なら不要なため)
- 利用率ストリームが切れたら 2 秒後に再接続
- 停止時は必ず `-rgc`

## 注意

- 効くのは VRAM 保持中だけ。VRAM が空の GPU では何もしない (driver が 135MHz まで落とす)。
- クランプ中は計算 0.089倍 / 帯域 0.12〜0.19倍まで落ちる。負荷検出は最速 `SAMPLE_MS`。
- VRAM を保持したまま常時推論している GPU ではアイドル判定が来ないため効かない。
- P40/P100 のように `-lgc` より PState 強制が効く世代では
  [nvidia-pstate](https://github.com/sasha0552/nvidia-pstate) の方が有効 (45W → 10W)。
- `-rgc` はロックを外すだけで、アイドル中はクロックを上げない (次の利用時に上がる)。

## ライセンス

MIT
