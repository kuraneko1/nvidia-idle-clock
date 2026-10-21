[English](README.en.md) | 日本語

# nvidia-idle-clock

VRAM に何か載ると高クロックに張り付いたままになる NVIDIA GPU 向け。
**アイドル時だけ** `nvidia-smi -lgc` でクロック上限を絞り、負荷を検出すると解除する systemd デーモン。
**GPU ごとに独立したインスタンス**として動き、1枚ずつ別々の設定を割り当てられる。
依存は bash と `nvidia-smi` だけで、NVAPI も CUDA toolkit もビルドも要らない。

| 状態 | クランプなし | クランプ 135MHz |
|---|---|---|
| V100-PCIE-32GB / VRAM 3.6GiB 保持 | 36.3W (最大 44.7W) | **24.9W** |
| PG500-216 / VRAM 8GiB 保持 | 40.9W | **28.4W** |
| VRAM 空 | 24.6W / 28.1W | 変化なし |

同条件での再測定は 25.1W / 28.5W (V100 / PG500-216)。計測環境と生データは「実測データ」を参照。

> **効くのは VRAM を保持している間だけ。**
> VRAM が空なら driver が自分で 135MHz まで落とすのでクランプは不要 (実測でクランプ有無の差は 0.0W)。
> 逆に **VRAM を保持している間は driver が降りない** — PG500-216 + 8GiB で
> 1260MHz / 40〜41W のまま **180秒** 経過するのを確認済み。ここが唯一の対象。
> 解除後の計算能力・メモリ帯域は **誤差 0.01%** で復帰する (PG500-216 / 8GiB 保持での実測)。

> **V100 (Volta) では PState 強制が使えない。**
> NVAPI の `NvAPI_GPU_SetForcePstate()` は、検証環境 (driver **580.178.04**) では
> `fallback=0` で全 PState (8〜15) が `NVAPI_ERROR` を返す。この制限は上流の
> [nvidia-pstated issue #6](https://github.com/sasha0552/nvidia-pstated/issues/6) (2025年1月) で
> 既に分析され、V100 での実測も報告されている。
> リリース済みの [nvidia-pstate](https://github.com/sasha0552/nvidia-pstate) /
> [nvidia-pstated](https://github.com/sasha0552/nvidia-pstated) **v1.0.9 (2025-08-30)** は P-State 強制のみで、
> V100 では動作しない (同じ環境で `fallback=2` にすると 555MHz に固定され、driver の自然アイドル
> 135MHz より +3W 悪化した)。単一 P-State の GPU 向けのクロックロックは nvidia-pstated の
> [PR #10](https://github.com/sasha0552/nvidia-pstated/pull/10) で提案中 (2026-10-22 時点で未マージ)。
> そのため本プロジェクトは PState ではなくクロック範囲ロックを使う。

## 通常との違い

![実測タイムライン: 135MHz クランプ中は 27.8W、負荷検出後 0.5 秒以内に 1260MHz / 39.5W へ戻り、30.2 秒無負荷で再クランプする](img/timeline.png)

| | 通常 (driver 任せ) | 導入後 |
|---|---|---|
| VRAM 保持中・無負荷のクロック | 1260〜1380MHz のまま降りない | **135MHz** (30秒無負荷で) |
| そのときの電力 | 36〜41W | **24.9〜28.4W** |
| 負荷が来たとき | そのまま実行 | 次のサンプルで検出し、`nvidia-smi -rgc` の起動と driver の復帰を経て解除。タイムライン図の測定では 0.5 秒以内、カーネル内計測では 0.18〜0.22 秒で 1300MHz 到達 |
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

(ある時点の 1 サンプル。値は `IDLE_CAP=135` でクランプ中のもの)

### 変わらないもの

- PState (V100 は常に P0)
- プロセスの VRAM、CUDA コンテキスト、計算結果
- persistence mode、電力上限、PCIe リンク、ファン制御
- クロック上限 (解除後は 1380MHz まで戻る。停止・再起動時は `-rgc` で driver 既定に戻るが、
  「元のロックを復元」ではなく「既定値にリセット」。VRAM を保持していると数秒で driver 管理の
  クロックに戻る — 下記「注意」を参照)

### 代償

**負荷検出から解除まで**は、次のサンプル周期 + `nvidia-smi -rgc` の起動 + driver のクロック復帰の
合計で、ハードな上限はない。既定値 (`SAMPLE_MS=200`) では次のようになる。

| 項目 | 実測 |
|---|---|
| サンプル周期 | 平均 200.7 / 201.1ms、最大 207.6ms (24 サンプル) |
| `nvidia-smi -rgc` の起動 | 30〜50ms (5 回) |
| 解除 → 1300MHz 到達 | 180 / 215 / 215ms (3 試行) |
| タイムライン図の注記 | 0.5 秒以内 |

つまり既定値でも **0.2〜0.5 秒**かかる。`SAMPLE_MS` を上げれば比例して伸びる。
NVML の利用率は 1/6〜1 秒の[窓平均](https://docs.nvidia.com/deploy/nvml-api/index.html)なので、
窓が 1 秒の製品では最悪 1.2 秒程度になる。

**短いリクエストはこの間ずっと 135MHz で走る。** クランプ中の計算能力は 0.089 倍 (約 11 倍遅い) なので、
解除が終わる前に終わるリクエストは丸ごと影響を受ける。カーネル内で SM クロックを測ったところ、
クランプ中に投入した処理は最初の 80 / 95 / 110ms (3 試行) が 126〜127MHz で、1300MHz に達したのは
180 / 215 / 215ms 後だった。0.5 秒の処理は 500ms のうち 185ms (37%) を 126MHz で走った。

- 20 秒ベンチの平均 (下記 −0.49%) は、この 0.2〜0.5 秒の停止を平均に埋もれさせる。
  影響の判断は上のレイテンシで行うこと。
- 負荷が 30 秒以上途切れない GPU ではクランプされない。ただしリクエスト駆動のサーバでも
  合間が 30 秒を超えればクランプする (実測: 稼働中の推論サーバで 24 時間に **141 回**)。
  不要なら `IDLE_SECONDS` を上げる (例: `120`)。
- デーモン自身のコスト: 約 **380 CPU 秒/日/インスタンス** (1 コアの約 0.44%)、RSS 17〜23MB。
  大半は `SAMPLE_MS=200` のポーリング。

## 必要環境

- Linux + systemd (テンプレートユニット `nvidia-idle-clock@.service` を使う)
- NVIDIA driver と `nvidia-smi`。`-lgc` / `-rgc` が使えること (`nvidia-smi -h` に `-lgc` があること)
- Volta 以降 (sm70+)。`-lgc` は Volta 以降でのみ使える
- root (`-lgc` / `-rgc` は root 専用)
- bash 4.2+ と coreutils。それ以外の依存はない (NVAPI / CUDA toolkit / ビルド不要)

## 対応ハードウェア

| GPU | 状態 |
|---|---|
| Tesla V100-PCIE-32GB (sm70) | **検証済み** — レイテンシ測定とアイドル電力 (36.3W → 24.9W) |
| Tesla PG500-216 (GV100 32GB, sm70) | **検証済み** — クランプ梯子・性能測定とアイドル電力 (40.9W → 28.4W) |
| Tesla V100-SXM2 / V100-PCIE-16GB | 未検証 (同じ sm70 で 135MHz 下限も同じだが、実機確認はしていない) |
| その他の sm70 (Quadro GV100 など) | 未検証 |
| Volta より新しい世代 (Turing / Ampere / Ada / Hopper) | **非対応** — `-lgc` は使えるが、このプロジェクトでは検証していない (節電効果も未検証) |
| Volta より前の世代 (Pascal など) | **非対応** — `nvidia-smi` に `-lgc` が無い |

要求したクロック範囲はデーモンが実行時に検証し、その GPU が受け付けない場合は警告して
その GPU をスキップする (黙って「クランプした」ことにしない)。
`IDLE_CAP` / `MIN_CLK` の既定値 135MHz は V100 の下限なので、他のカードでは実機の下限に合わせる。

## インストール

**共有 GPU では、事前の合意なしに使わないこと** (`-lgc` はカード全体に効く。→「共有 GPU での注意」)。

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

**`GPU=` に既存インスタンスと同じ GPU を指定しないこと。** 同じカードを 2 つのインスタンスが
取り合い、片方の起動・停止時の `-rgc` がもう片方のクランプを解除する (警告は出ない)。
既定ではインスタンス名 = GPU index なので、通常は重複しない。

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

計測環境: Tesla V100-PCIE-32GB + Tesla PG500-216 (GV100 32GB x2) / driver 580.178.04。
VRAM 保持は CUDA コンテキストで 3.6GiB / 8GiB を確保した状態。特記なき限り 20 秒平均。

26 時間の実運用でのクランプ時間率は 77.6% / 71.0% (GPU0 / GPU1)、24 時間のクランプ回数は 141 回。

### アイドル消費電力 — VRAM 状態で効き目が変わる

![アイドル時消費電力の棒グラフ: V100-PCIE-32GB は VRAM 3.6GiB 保持で 36.3W → 24.9W、PG500-216 は 8GiB 保持で 40.9W → 28.4W に下がり、VRAM が空のときは 24.6/28.1W から変化しない](img/idle-power.png)

<!--POWER_MEASUREMENT_TABLE-->

### クロック上限別 (PG500-216 / VRAM 8GiB 保持中, 各20秒)

![クランプ梯子の棒グラフ: クランプなしは 1260MHz / 40.94W、-lgc 135,555 で 555MHz / 31.73W、-lgc 135,300 で 300MHz / 29.52W、-lgc 135,135 で 135MHz / 28.40W](img/clamp-ladder.png)

| クランプ | 実クロック | 電力 |
|---|---|---|
| なし | 1260 MHz | 40.94 W |
| `-lgc 135,555` | 555 MHz | 31.73 W |
| `-lgc 135,300` | 300 MHz | 29.52 W |
| `-lgc 135,135` | 135 MHz | 28.40 W |

### クランプの性能影響 (PG500-216 / VRAM 8GiB 保持)

![スループット比の棒グラフ: クランプ中は DtoD copy 19.4%、memset 12.0%、SGEMM 4096 8.9% まで落ち、解除後と実運用パス (負荷投入後に自動解除) ではいずれも 100% 前後に戻る](img/perf.png)

| 項目 | クランプなし | 135MHz クランプ中 | 解除後 | 実運用パス\* |
|---|---|---|---|---|
| DtoD copy | 1024.7 GB/s | 198.7 GB/s | 1024.6 GB/s | 1019.7 GB/s (−0.49%) |
| memset | 1114.9 GB/s | 133.8 GB/s | 1114.9 GB/s | 1114.8 GB/s (−0.01%) |
| SGEMM 4096 (FP32) | 12.36 TFLOP/s | 1.10 TFLOP/s | 12.36 TFLOP/s | 12.36 TFLOP/s (±0%) |

\* クランプ状態に負荷投入 → デーモンが自動解除した場合 (20秒予算)

> **図のタイトルに関する注意。** `img/perf.png` のタイトルは "Tesla V100" だが、この 8GiB 保持の
> 測定は **PG500-216** (GV100 32GB) で行ったもの。V100-PCIE-32GB の理論帯域
> (4096bit HBM2 / 877MHz で約 898GB/s) では memset 1114.9GB/s は出ないため、
> この表を V100-PCIE-32GB の絶対値として読まないこと。絶対値はカード依存なので、
> クランプ中と解除後の比だけを見ること。図の凡例がプロット内に重なっている点も既知。

### 参考: 実機のログ

1 インスタンスで複数 GPU (`GPU=0,1`) を持つ場合の例。タイムスタンプは journald が付けるので、
スクリプト自身は出力しない。

```
$ journalctl -u nvidia-idle-clock@0 -o cat
level=info msg="started" gpu=0,1 min_mhz=135 cap_mhz=135 idle_s=30 sample_ms=200 util_threshold_pct=0 reassert_s=30 skip_if_low=1 nvidia_smi=/usr/bin/nvidia-smi
level=info msg="clamp verified" gpu=0 trigger=idle was_mhz=1260 observed_mhz=135 min_mhz=135 cap_mhz=135
level=info msg="clamp verified" gpu=1 trigger=idle was_mhz=1260 observed_mhz=135 min_mhz=135 cap_mhz=135
level=info msg="unlocked" gpu=0 trigger=util util_pct=42
level=info msg="stream lost" retry_s=2 stderr=""
level=info msg="exit" gpu=0,1 rc=0
```

- `level=` と `msg="..."` が先頭の 2 フィールド。`msg` は固定の識別子なので、自由文ではなく
  `msg="..."` で grep する。
- `level=` は syslog priority ではないため `journalctl -p warning` では絞れない。
  `journalctl -u nvidia-idle-clock@0 -g 'level=(warn|error)'` を使う。
- SIGTERM での正常停止では最後の行が `msg="exit" rc=0`。解除に失敗した場合は
  `msg="unlock failed"` のあとに `msg="exit" rc=1` が続く。

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
| `NVSMI` | `PATH` 上の `nvidia-smi` | 使う `nvidia-smi` のパス (テスト・特殊な配置用) |

`GPU` に存在しない index を指定した場合は除外して警告を出す。全部無効なら起動に失敗する。
設定値が不正なら `msg="invalid config"` を出して exit 2、`nvidia-smi` が見つからなければ exit 1 で
終了する (どちらも GPU に触る前)。

## 動作

- 対象 GPU の利用率を `SAMPLE_MS` 間隔で監視 (インスタンスごとに独立)
- `IDLE_SECONDS` 無負荷 → `nvidia-smi -i N -lgc MIN_CLK,IDLE_CAP`
- 利用率 > `UTIL_THRESHOLD` → `-rgc` で解除
- `SKIP_IF_LOW=1` のとき既に低クロックなら何もしない (VRAM が空なら不要なため)
- 利用率ストリームが切れたら 2 秒後に再接続
- 起動時にも対象 GPU に `-rgc` を実行する (このデーモンが付けたロックだけを外す実装ではない。
  他ツールのクロックロックと併用しないこと)
- 停止・再起動時は `-rgc` で解除する。ただし SIGKILL・OOM・`TimeoutStopSec` 超過では
  シェルの trap が走らないため解除できない。**ユニット側で supervisor が解除するよう現在
  hardening 中** (ExecStopPost)

## 注意

- クランプは **カード全体 (デバイス全体)** に効く。変更・解除は root のみ。
  共有 GPU では「共有 GPU での注意」を必ず読むこと。
- 効くのは VRAM 保持中だけ。VRAM が空の GPU では何もしない (driver が 135MHz まで落とす)。
- クランプ中は計算 0.089 倍 / 帯域 0.12〜0.19 倍まで落ちる。解除までの時間は
  「次のサンプル周期 + `-rgc` の起動 + driver の復帰」で、既定 0.2〜0.5 秒。`SAMPLE_MS` に比例する。
- VRAM を保持したまま常時推論している GPU ではアイドル判定が来ないため効かない。
  ただし合間が 30 秒を超えるリクエスト駆動のサーバではクランプする (実測 141 回/24 時間)。
- 複数の P-State を持つ世代 (P40 など) では P-State 強制の方が向いている場合がある。
  [nvidia-pstate](https://github.com/sasha0552/nvidia-pstate) /
  [nvidia-pstated](https://github.com/sasha0552/nvidia-pstated) が該当する。
  上流の README には消費電力の数値が無く、当方で P40 を測ったこともないため、
  この README からは数値を引用しない。
- `-rgc` は driver 既定のポリシーに戻すだけで、低クロックを強制しない。VRAM を保持していると
  数秒で driver 管理のクロックまで戻る (実測: 135MHz / 28.51W → 3 秒後に 1260MHz / 38.97W、
  10 秒平均 28.51W → 40.31W、**+11.8W / +29.3%**)。クランプによる節電は次の再適用
  (既定 30 秒) まで失われる。ロックが無い、または VRAM が空のときだけ no-op。

## 共有 GPU での注意

**合意のない共有 GPU では使わないこと。** `-lgc` はカード全体のクロック上限で、プロセス単位ではない。

- 変更・解除は root だけができる。非 root の同居テナントは `-lgc` も `-rgc` も実行できず
  (exit 4)、自分ではクランプを解除できない。
- **同居テナントはクランプされていることを知ることすらできない。** ロックは
  `nvidia-smi -q -d CLOCK` にも `nvidia-smi -q` のどの項目にも出ない。見えるのは
  `clocks.current.graphics` が 135MHz になっていることだけ。
- カードの利用率が 0 の間、同じカードの全プロセス・全コンテキストが 135MHz で走る
  (MIG のコンピュートインスタンスもクロックを共有する)。解除は次のサンプル周期 + `-rgc` 起動 +
  driver 復帰 (既定 0.2〜0.5 秒) 後。
- `Environment=GPU=` の重複で 2 つのインスタンスが同じカードを指すと、片方の起動・停止時の
  `-rgc` が相手のクランプを最大 `REASSERT_SECONDS` (既定 30 秒) 解除する。警告は出ない。
- 自分の管理下のカード (ワークステーション、単独利用の推論サーバ) でのみ使うこと。

## 先行事例

アイドル時にデータセンター GPU のクロックを絞る、という発想自体は新しくない。
本プロジェクトはそれを「依存なしの小さな実装」として提供するもので、最初でも唯一でもない。
以下は同じ問題に対する先行・関連実装で、GPU によってはこちらの方が適切な場合がある。

- **[sasha0552/nvidia-pstated](https://github.com/sasha0552/nvidia-pstated)** (GPL-3.0) —
  この分野の参照実装。NVAPI で P-State を強制し、アイドル時に自動で切り替える。
  複数の P-State を持つ P40 系のカードならこちらが適切。オープンな
  **[PR #10](https://github.com/sasha0552/nvidia-pstated/pull/10)** は **V100** を含む単一 P-State の
  GPU 向けに、NVML でクロックをロックする `--clock-mode` を追加するもの (2026-09-12 時点で
  メンテナのレビュー中・コミットあり、未マージ)。マージされれば本リポジトリと同等のことを
  より高機能に行うので、まずそちらを確認してほしい。
  V100 で P-State 強制が効かない点と、クロックロックによる V100 の実測は
  **[issue #6](https://github.com/sasha0552/nvidia-pstated/issues/6)** (2025年1月) で既に検討済み。
- **[sasha0552/nvidia-pstate](https://github.com/sasha0552/nvidia-pstate)** (MIT) — 上記の前身の
  CLI / Python ライブラリ。P-State を手動で切り替える。
- **[dqs105/nvidia-powermizer](https://github.com/dqs105/nvidia-powermizer)** (GPL-3.0) —
  利用率連動でクロックを絞るデーモン (対象はメモリクロック)。ヒステリシス付き。
- **[UzixLS/cmp50hx-unlock の idle-governor](https://github.com/UzixLS/cmp50hx-unlock/blob/master/idle-governor/README.md)**
  — CMP 50HX 向けの同種の制御ループ。`-lgc` の範囲指定では下がらない場合がある、という
  実測が参考になる。
- **[mu-b/ai-dgxspark-power](https://github.com/mu-b/ai-dgxspark-power)** — `-lgc` をスケジュールで
  適用し、定期的に再適用する (GB10 向け)。
- **[andyljones/coolgpus](https://github.com/andyljones/coolgpus)** (MIT) /
  **[LACT](https://github.com/ilya-zlobintsev/LACT)** (MIT) — ファン・電力上限側の隣接ツール。
  アイドル時のクロックは触らない。

NVIDIA 純正機能では実現できない。`nvidia-persistenced` はドライバを常駐させるだけで
([docs](https://docs.nvidia.com/deploy/driver-persistence/persistence-daemon.html))、
`nvidia-powerd` はノート PC で電力を上乗せする方向
([docs](https://download.nvidia.com/XFree86/Linux-x86_64/580.76.05/README/dynamicboost.html))、
`-lgc` にアイドル連動機能は無い ([man](https://man.archlinux.org/man/nvidia-utils/nvidia-smi.1.en))。

本プロジェクトの差分は次の 4 点。

- **既存の非標準依存が無い** — bash と `nvidia-smi` だけ。NVAPI ライブラリも CUDA toolkit も
  ビルドも要らない
- **GPU ごとの systemd テンプレートインスタンス** — `nvidia-idle-clock@N.service` と
  drop-in で、カードごとに別の設定を持てる
- **MIT ライセンス** — 上記の主要な先行実装は GPL-3.0
- **実測を出典付きで載せている** — クランプ梯子、解除後の復帰、レイテンシ、デーモン自身のコスト

## ライセンス

MIT
