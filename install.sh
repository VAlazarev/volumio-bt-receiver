#!/bin/bash
# Bluetooth A2DP receiver for Volumio - installer.
#
# Nothing here unlocks, patches or circumvents anything. The stock Volumio
# image already ships BlueZ and bluez-alsa, already runs bluealsa with
# -p a2dp-sink, and already advertises the A2DP AudioSink UUID. The only
# missing piece is a process that takes the incoming stream and plays it on
# the output device. This installs that, and nothing else.
#
# Everything it puts on the system is a file in this repository:
#
#   bin/bt-receiver              -> /usr/local/bin/bt-receiver
#   default/bt-receiver          -> /etc/default/bt-receiver   (kept if present)
#   systemd/bt-receiver.service  -> /etc/systemd/system/bt-receiver.service
#
# Run as root:  sudo bash install.sh

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "Нужен root: sudo bash $0" >&2
    exit 1
fi

for f in bin/bt-receiver default/bt-receiver systemd/bt-receiver.service; do
    if [ ! -f "$SRC/$f" ]; then
        echo "Нет файла $SRC/$f - репозиторий неполный" >&2
        exit 1
    fi
done

install -m 0755 "$SRC/bin/bt-receiver" /usr/local/bin/bt-receiver
echo "  /usr/local/bin/bt-receiver"

# Settings the user may have edited are left alone.
if [ -f /etc/default/bt-receiver ]; then
    echo "  /etc/default/bt-receiver — уже есть, не трогаю"
else
    install -m 0644 "$SRC/default/bt-receiver" /etc/default/bt-receiver
    echo "  /etc/default/bt-receiver"
fi

install -m 0644 "$SRC/systemd/bt-receiver.service" /etc/systemd/system/bt-receiver.service
echo "  /etc/systemd/system/bt-receiver.service"

systemctl daemon-reload
systemctl enable --now bt-receiver.service

echo
systemctl --no-pager --lines=8 status bt-receiver.service || true
echo
echo "Готово. Телефон подключается к устройству с именем, которое показывает"
echo "bluetoothctl show (по умолчанию Volumio)."
