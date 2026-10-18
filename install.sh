#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if [ "$(id -u)" -ne 0 ]; then
  echo "root 権限が必要です: sudo $0" >&2
  exit 1
fi

install -m 0755 nvidia-idle-clock         /usr/local/sbin/nvidia-idle-clock
install -m 0644 nvidia-idle-clock.service /etc/systemd/system/nvidia-idle-clock.service

systemctl daemon-reload
systemctl enable --now nvidia-idle-clock.service
sleep 2
systemctl --no-pager --lines=5 status nvidia-idle-clock.service || true

echo
echo "インストール完了。対象 GPU を変える場合は次を編集して再起動:"
echo "  sudo systemctl edit nvidia-idle-clock.service   # 例: Environment=GPU=0,1"
echo "  sudo systemctl restart nvidia-idle-clock.service"
