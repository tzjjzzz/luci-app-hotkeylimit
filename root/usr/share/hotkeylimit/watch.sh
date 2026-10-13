#!/bin/sh
# watchdog: (1) a limit is removed when the controller that turned it on (client + page/script) stops sending heartbeats
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
	n=$(now)
	changed=0
	for o in $(awk '{print $2}' "$ONF" | sort -u); do
		f=$(beat_file "$o")
		read -r b <"$f" 2>/dev/null || b=0
		if [ $((n - ${b:-0})) -gt "$T" ]; then
			awk -v o="$o" '$2!=o' "$ONF" >"$ONF.t"
			mv "$ONF.t" "$ONF"
			rm -f "$f"
			changed=1
		fi
	done
	[ "$changed" = 1 ] && apply
done
