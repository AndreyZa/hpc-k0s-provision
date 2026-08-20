#!/bin/sh
# memwatch: раз в минуту пишет в journal доступную память, занятый своп и
# топ-3 процессов по RSS. Появился после фриза 19.08.2026: memory-hog
# (vak-parser) съел память хоста без свопа — OOM-киллер сработать не успел,
# journald замер вместе со всеми, и журнал не оставил ни следа виновника.
# Теперь виновника называет последняя строка перед фризом:
#   journalctl -t memwatch -b -1 | tail
avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
swapused=$(awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{print int((t-f)/1024)}' /proc/meminfo)
top3=$(ps -eo rss=,args= --sort=-rss | head -3 | awk '{cmd=$2; sub(".*/","",cmd); printf "%s(%dM) ", cmd, $1/1024}')
logger -t memwatch "avail=${avail}M swap_used=${swapused}M top: ${top3}"
