# luci-app-hotkeylimit

Lightweight OpenWrt plugin: a tiny standalone web page (own port, no login) that toggles a per-device upload/download limit with a hotkey.
Values: -1 = block, 0 = no limit, N = limit to N KB/s. Default: upload -1, download 0.
Port: `uci set hotkeylimit.main.port=8899; uci commit hotkeylimit; /etc/init.d/hotkeylimit restart`
