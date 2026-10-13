# shared helpers. value: -1 = block, 0 = no limit, N>0 = limit to N KB/s
# $CFG lines: "ip up down key"   $ONF lines: ips that are currently limited
TB="inet hklimit"
CH=hkchain
CFG=/tmp/hklimit.cfg
ONF=/tmp/hklimit.on
BEAT=/tmp/hklimit.beat
NFT=/tmp/hklimit.nft
ERR=""

now() { local u; read -r u _ </proc/uptime; echo "${u%.*}"; }

is_on() { grep -qxF "$1" "$ONF" 2>/dev/null; }
set_on() { is_on "$1" || echo "$1" >>"$ONF"; }
set_off() { [ -f "$ONF" ] || return 0; grep -vxF "$1" "$ONF" >"$ONF.t"; mv "$ONF.t" "$ONF"; }
has_cfg() { awk -v ip="$1" '$1==ip{f=1} END{exit !f}' "$CFG" 2>/dev/null; }

rule_line() { # ip dir value
	case "$3" in
	0) ;;
	-1) echo "		ip $2 $1 counter drop" ;;
	*) echo "		ip $2 $1 limit rate over $3 kbytes/second burst $3 kbytes counter drop" ;;
	esac
}

clear_all() { nft delete table $TB 2>/dev/null; rm -f "$ONF"; }

# rebuild the whole ruleset atomically from $CFG + $ONF; returns 1 and sets ERR on failure
apply() {
	local ip up down key out
	ERR=""
	if [ ! -s "$ONF" ] || [ ! -f "$CFG" ]; then
		nft delete table $TB 2>/dev/null
		return 0
	fi
	{
		echo "add table $TB"
		echo "delete table $TB"
		echo "table $TB {"
		echo "	chain $CH {"
		echo "		type filter hook forward priority -5; policy accept;"
		while read -r ip up down key; do
			[ -n "$ip" ] && is_on "$ip" || continue
			rule_line "$ip" saddr "$up"
			rule_line "$ip" daddr "$down"
		done <"$CFG"
		echo "	}"
		echo "}"
	} >"$NFT"
	out=$(nft -f "$NFT" 2>&1) || { ERR="$out"; return 1; }
	return 0
}
