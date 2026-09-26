#!/bin/bash
# Removes the Bluetooth A2DP receiver. Nothing Volumio ships is touched -
# bluealsa and BlueZ stay exactly as they were.
#
# Run as root:  sudo bash uninstall.sh

set -euo pipefail

UNIT=/etc/systemd/system/bt-receiver.service

if [ "$(id -u)" -ne 0 ]; then
    echo "Нужен root: sudo bash $0" >&2
    exit 1
fi

systemctl disable --now bt-receiver.service 2>/dev/null || true
rm -f "$UNIT"
systemctl daemon-reload

echo "Приёмник удалён."
