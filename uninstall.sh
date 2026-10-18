#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "root 権限が必要です: sudo $0" >&2
  exit 1
fi

systemctl disable --now nvidia-idle-clock.service 2>/dev/null || true
rm -f /etc/systemd/system/nvidia-idle-clock.service /usr/local/sbin/nvidia-idle-clock
systemctl daemon-reload
systemctl reset-failed nvidia-idle-clock.service 2>/dev/null || true

# 残っているクロックロックを解除
for g in $(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null); do
  nvidia-smi -i "$g" -rgc >/dev/null 2>&1 || true
done

echo "アンインストール完了 (クロックロックは解除済み)"
