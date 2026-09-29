#!/bin/bash
# Removes the Bluetooth A2DP receiver. Nothing Volumio ships is touched -
# bluealsa and BlueZ stay exactly as they were.
#
# Run it as the ordinary volumio user:  bash uninstall.sh
#
# Pass --purge to remove /etc/default/bt-receiver as well; by default your
# settings are kept.

set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    AS_ROOT=""
else
    AS_ROOT="sudo -n"
    if ! sudo -n /bin/systemctl --version >/dev/null 2>&1; then
        echo "Нет прав на systemctl без пароля." >&2
        echo "Запустите от root:  sudo bash $0" >&2
        exit 1
    fi
fi

$AS_ROOT /bin/systemctl disable --now bt-receiver.service 2>/dev/null || true

# rm is not in the passwordless list, but mv is: park the files somewhere
# harmless instead of leaving them active.
$AS_ROOT /bin/mv -f /etc/systemd/system/bt-receiver.service /tmp/bt-receiver.service.removed 2>/dev/null || true
$AS_ROOT /bin/mv -f /usr/local/bin/bt-receiver /tmp/bt-receiver.removed 2>/dev/null || true
$AS_ROOT /bin/systemctl daemon-reload

if [ "${1:-}" = "--purge" ]; then
    $AS_ROOT /bin/mv -f /etc/default/bt-receiver /tmp/bt-receiver.default.removed 2>/dev/null || true
    echo "Приёмник и настройки удалены (файлы отложены в /tmp)."
else
    echo "Приёмник удалён. Настройки в /etc/default/bt-receiver оставлены"
    echo "(удалить: $0 --purge)."
fi
