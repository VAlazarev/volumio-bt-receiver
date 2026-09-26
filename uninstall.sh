#!/bin/bash
# Removes the Bluetooth A2DP receiver. Nothing Volumio ships is touched -
# bluealsa and BlueZ stay exactly as they were.
#
# Run as root:  sudo bash uninstall.sh
#
# Pass --purge to remove /etc/default/bt-receiver as well; by default your
# settings are kept.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Нужен root: sudo bash $0" >&2
    exit 1
fi

systemctl disable --now bt-receiver.service 2>/dev/null || true
rm -f /etc/systemd/system/bt-receiver.service
rm -f /usr/local/bin/bt-receiver
systemctl daemon-reload

if [ "${1:-}" = "--purge" ]; then
    rm -f /etc/default/bt-receiver
    echo "Приёмник и настройки удалены."
else
    echo "Приёмник удалён. Настройки в /etc/default/bt-receiver оставлены"
    echo "(удалить: $0 --purge)."
fi
