#!/bin/bash
# Prints the state of everything the receiver depends on. This is the check
# that established the capability was never actually blocked - run it before
# assuming something is missing.
#
# Needs no root.

echo "=== пакеты ==="
dpkg -l 2>/dev/null | grep -iE "bluez|bluealsa" | awk '{print "  "$2"  "$3}'

echo
echo "=== как запущен bluealsa (ищем -p a2dp-sink) ==="
ps -eo args 2>/dev/null | grep "[b]luealsa " | sed 's/^/  /' || echo "  не запущен"

echo
echo "=== точки A2DP, зарегистрированные в BlueZ ==="
# Endpoints are registered by bluealsa, so they show under its object tree -
# asking org.bluez alone comes back empty.
busctl --system tree org.bluealsa 2>/dev/null | grep -i a2dp | sed 's/^/  /' || echo "  нет"

echo
echo "=== объявляет ли адаптер приём звука ==="
if busctl --system get-property org.bluez /org/bluez/hci0 org.bluez.Adapter1 UUIDs 2>/dev/null | grep -q 0000110b; then
    echo "  да: UUID 0000110b (A2DP AudioSink)"
else
    echo "  НЕТ - адаптер не объявляет себя приёмником"
fi

echo
echo "=== адаптер ==="
printf 'show\nquit\n' | timeout 10 bluetoothctl 2>/dev/null | grep -iE "Name:|Alias:|Powered:|Discoverable:|Pairable:" | sed 's/^/  /'

echo
echo "=== настройки BlueZ ==="
grep -E "^(Class|DiscoverableTimeout|PairableTimeout|AlwaysPairable|Enable)" /etc/bluetooth/main.conf 2>/dev/null | sed 's/^/  /'

echo
echo "=== подключённые источники A2DP ==="
timeout 10 bluealsa-aplay --list-devices 2>/dev/null | sed 's/^/  /'

echo
echo "=== выход ==="
aplay -l 2>/dev/null | grep '^card' | sed 's/^/  /'

echo
echo "=== кто держит устройство вывода ==="
for pcm in /dev/snd/pcmC*D0p; do
    holder=$(fuser -v "$pcm" 2>&1 | tail -n +2)
    [ -n "$holder" ] && echo "  $pcm: $holder"
done
echo "  (пусто - выход свободен)"

echo
echo "=== служба приёмника ==="
echo "  автозапуск: $(systemctl is-enabled bt-receiver.service 2>/dev/null || echo 'не установлена')"
echo "  состояние:  $(systemctl is-active bt-receiver.service 2>/dev/null || echo 'не запущена')"
echo "  процесс:    $(pgrep -a bluealsa-aplay 2>/dev/null || echo 'нет')"
