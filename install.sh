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
# Run it as the ordinary volumio user:  bash install.sh
#
# Full sudo on Volumio asks for a password, but the volumio user is granted a
# handful of commands without one - among them tee, chmod and systemctl. That
# is enough to install a service, so this uses those rather than demanding
# root and failing.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"

for f in bin/bt-receiver default/bt-receiver systemd/bt-receiver.service; do
    if [ ! -f "$SRC/$f" ]; then
        echo "Нет файла $SRC/$f - репозиторий неполный" >&2
        exit 1
    fi
done

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

write_file() {
    # tee rather than cp: cp is not in the passwordless list, tee is.
    $AS_ROOT /usr/bin/tee "$2" < "$1" > /dev/null
    echo "  $2"
}

write_file "$SRC/bin/bt-receiver" /usr/local/bin/bt-receiver
$AS_ROOT /bin/chmod 0755 /usr/local/bin/bt-receiver

# Settings the user may have edited are left alone.
if [ -f /etc/default/bt-receiver ]; then
    echo "  /etc/default/bt-receiver — уже есть, не трогаю"
else
    write_file "$SRC/default/bt-receiver" /etc/default/bt-receiver
fi

write_file "$SRC/systemd/bt-receiver.service" /etc/systemd/system/bt-receiver.service

# A copy started by hand would hold the output device and keep the service
# from ever opening it.
pkill -f bluealsa-aplay 2>/dev/null || true
sleep 1

$AS_ROOT /bin/systemctl daemon-reload
$AS_ROOT /bin/systemctl enable --now bt-receiver.service

echo
$AS_ROOT /bin/systemctl --no-pager --lines=5 status bt-receiver.service || true
echo
echo "Готово. Телефон подключается к устройству с именем, которое показывает"
echo "bluetoothctl show (по умолчанию Volumio)."
