#!/bin/sh
# watchdog: remove all limits when the controller stops sending heartbeats
. /usr/share/hotkeylimit/lib.sh
T=${1:-20}
while sleep 2; do
	[ -f "$ONF" ] || continue
	read -r b <"$BEAT" 2>/dev/null || b=0
	n=$(now)
	[ $((n - ${b:-0})) -gt "$T" ] && clear_all
done
