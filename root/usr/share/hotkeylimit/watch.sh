#!/bin/sh
# watchdog: (1) remove all limits when the controller stops sending heartbeats
#           (2) copy changed settings to flash (at most once per 2s, only when something changed)
. /usr/share/hotkeylimit/lib.sh
T=${1:-20}
while sleep 2; do
	if [ -f "$DIRTY" ]; then
		rm -f "$DIRTY"
		cp "$CFG" "$PCFG" 2>/dev/null
		cp "$BIND" "$PBIND" 2>/dev/null
	fi
	[ -s "$ONF" ] || continue
	read -r b <"$BEAT" 2>/dev/null || b=0
	n=$(now)
	[ $((n - ${b:-0})) -gt "$T" ] && clear_all
done
