# shared helpers. value: -1 = block, 0 = no limit, N>0 = limit to N KB/s
TB="inet hklimit"
CH=hkchain
CFG=/tmp/hklimit.cfg
ONF=/tmp/hklimit.on
BEAT=/tmp/hklimit.beat
ERR=""

now() { local u; read -r u _ </proc/uptime; echo "${u%.*}"; }

run() { local out; out=$("$@" 2>&1) || ERR="${ERR}${out} "; }

add_rule() { # ip dir value
	case "$3" in
	0) return 0 ;;
	-1) run nft add rule $TB $CH ip "$2" "$1" counter drop ;;
	*) run nft add rule $TB $CH ip "$2" "$1" limit rate over "$3" kbytes/second burst "$3" kbytes counter drop ;;
	esac
}

clear_all() { nft delete table $TB 2>/dev/null; rm -f "$ONF"; }

# (re)install rules from $CFG; returns 1 and sets ERR on failure
apply() {
	local ip up down
	ERR=""
	nft delete table $TB 2>/dev/null
	read -r ip up down <"$CFG" || { ERR="no config"; return 1; }
	run nft add table $TB
	run nft add chain $TB $CH '{ type filter hook forward priority -5; policy accept; }'
	add_rule "$ip" saddr "$up"
	add_rule "$ip" daddr "$down"
	[ -z "$ERR" ] && return 0
	nft delete table $TB 2>/dev/null
	return 1
}
