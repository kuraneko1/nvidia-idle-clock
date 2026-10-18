#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if [ "$(id -u)" -ne 0 ]; then
  echo "root 権限が必要です: sudo $0" >&2
  exit 1
fi

# 対象 GPU: 引数があればそれを、なければ検出した全 GPU
if [ "$#" -gt 0 ]; then
  GPUS="${*//,/ }"
else
  GPUS=$(nvidia-smi --query-gpu=index --format=csv,noheader,nounits | tr -d ' ')
fi
if [ -z "${GPUS// /}" ]; then
  echo "GPU が見つかりません" >&2
  exit 1
fi

install -m 0755 nvidia-idle-clock           /usr/local/sbin/nvidia-idle-clock
install -m 0644 nvidia-idle-clock@.service /etc/systemd/system/nvidia-idle-clock@.service

# 旧・非テンプレート版が残っていれば片付ける
if [ -f /etc/systemd/system/nvidia-idle-clock.service ]; then
  systemctl disable --now nvidia-idle-clock.service 2>/dev/null || true
  rm -f /etc/systemd/system/nvidia-idle-clock.service
fi

systemctl daemon-reload

for g in $GPUS; do
  systemctl enable --now "nvidia-idle-clock@${g}.service"
done

sleep 2
for g in $GPUS; do
  systemctl --no-pager --lines=3 status "nvidia-idle-clock@${g}.service" || true
  echo
done

echo "インストール完了 (GPU: ${GPUS// /, })"
echo "GPU ごとの個別設定:"
echo "  sudo systemctl edit nvidia-idle-clock@<GPU>.service"
echo "  sudo systemctl restart nvidia-idle-clock@<GPU>.service"
