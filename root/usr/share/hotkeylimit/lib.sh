# shared helpers. value: -1 = block, 0 = no limit, N>0 = limit to N KB/s
# $CFG  lines: "ip up down"         (shared device limits)
# $BIND lines: "client key ip"      (hotkey bindings, per client PC)
# $ONF  lines: "ip owner"  (limited devices and the controller that turned them on; owner = client.src)
TB="inet hklimit"
CH=hkchain
CFG=/tmp/hklimit.cfg
BIND=/tmp/hklimit.bind
ONF=/tmp/hklimit.on
BEATD=/tmp/hklimit.beat.d   # one heartbeat file per owner
NFT=/tmp/hklimit.nft
DIRTY=/tmp/hklimit.dirty
PCFG=/etc/hotkeylimit.cfg
PBIND=/etc/hotkeylimit.bind
ERR=""
CID=""

now() { local u; read -r u _ </proc/uptime; echo "${u%.*}"; }

# client identity = MAC of the requesting PC (falls back to its IP)
client_id() {
	local m
	m=$(awk -v ip="$REMOTE_ADDR" '$1==ip{print $4; exit}' /proc/net/arp 2>/dev/null)
	case "$m" in "" | 00:00:00:00:00:00) m="$REMOTE_ADDR" ;; esac
	printf '%s' "$m" | tr -cd '0-9A-Fa-f:.'
}
cid() { [ -n "$CID" ] || CID=$(client_id); }
key_for() { awk -v c="$CID" -v ip="$1" '$1==c && $3==ip {print $2; exit}' "$BIND" 2>/dev/null; }
mark_dirty() { : >"$DIRTY"; }

is_on() { awk -v ip="$1" '$1==ip{f=1} END{exit !f}' "$ONF" 2>/dev/null; }
set_on() { { awk -v ip="$1" '$1!=ip' "$ONF" 2>/dev/null; echo "$1 $2"; } >"$ONF.t"; mv "$ONF.t" "$ONF"; }
set_off() { [ -f "$ONF" ] || return 0; awk -v ip="$1" '$1!=ip' "$ONF" >"$ONF.t"; mv "$ONF.t" "$ONF"; }
owns_any() { awk -v o="$1" '$2==o{f=1} END{exit !f}' "$ONF" 2>/dev/null; }
beat_file() { printf '%s/%s' "$BEATD" "$(printf '%s' "$1" | tr ':' '_')"; }
touch_beat() { mkdir -p "$BEATD"; now >"$(beat_file "$1")"; }
has_cfg() { awk -v ip="$1" '$1==ip{f=1} END{exit !f}' "$CFG" 2>/dev/null; }

rule_line() { # ip dir value
	case "$3" in
	0) ;;
	-1) echo "		ip $2 $1 counter drop" ;;
	*) echo "		ip $2 $1 limit rate over $3 kbytes/second burst $3 kbytes counter drop" ;;
	esac
}

clear_all() { nft delete table $TB 2>/dev/null; rm -f "$ONF"; rm -rf "$BEATD"; }

# rebuild the whole ruleset atomically from $CFG + $ONF; returns 1 and sets ERR on failure
apply() {
	local ip up down rest out
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
		while read -r ip up down rest; do
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
