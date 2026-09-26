#!/bin/bash
# Bluetooth A2DP receiver for Volumio - installer.
#
# Nothing here unlocks, patches or circumvents anything. The stock Volumio
# image already ships BlueZ and bluez-alsa, already runs bluealsa with
# -p a2dp-sink, and already advertises the A2DP AudioSink UUID. The only
# missing piece is a process that takes the incoming stream and plays it on
# the output device. That is what this installs, plus a unit so it survives a
# reboot.
#
# Run as root:  sudo bash install.sh

set -euo pipefail

UNIT=/etc/systemd/system/bt-receiver.service
ALSA_CONF=/data/configuration/audio_interface/alsa_controller/config.json

if [ "$(id -u)" -ne 0 ]; then
    echo "Нужен root: sudo bash $0" >&2
    exit 1
fi

# Take the output device and mixer from Volumio's own settings rather than
# hardcoding them, so this works on any DAC.
read_conf() {
    sed -n 's/.*"'"$1"'":{"type":"string","value":"\([^"]*\)".*/\1/p' "$ALSA_CONF" 2>/dev/null | head -1
}

CARD="$(read_conf outputdevicecardname)"
MIXER="$(read_conf mixer)"

if [ -z "$CARD" ]; then
    echo "Не удалось прочитать имя звуковой карты из $ALSA_CONF" >&2
    echo "Доступные карты:" >&2
    aplay -l | grep '^card' >&2
    exit 1
fi

echo "Карта:  $CARD"
echo "Микшер: ${MIXER:-(без аппаратного микшера)}"

# bluealsa-aplay defaults to the ALSA mixer named "default", which on Volumio
# routes into PulseAudio and times out - the worker then dies right after
# opening the output. Pointing it at the card's own mixer avoids that.
MIXER_ARGS=""
if [ -n "$MIXER" ]; then
    MIXER_ARGS="--mixer-device=hw:CARD=$CARD --mixer-name=$MIXER"
fi

cat > "$UNIT" <<EOF
[Unit]
Description=Bluetooth A2DP receiver (phone -> DAC)
Documentation=https://github.com/arkq/bluez-alsa
Requires=bluealsa.service
After=bluealsa.service sound.target

[Service]
Type=simple
User=volumio
Group=audio
ExecStart=/usr/bin/bluealsa-aplay --pcm=plughw:CARD=$CARD,DEV=0 $MIXER_ARGS
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now bt-receiver.service

echo
systemctl --no-pager --lines=5 status bt-receiver.service || true
echo
echo "Готово. Телефон подключается к устройству с именем, которое показывает"
echo "bluetoothctl show (по умолчанию Volumio)."
