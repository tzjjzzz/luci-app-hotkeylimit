# luci-app-hotkeylimit

Lightweight OpenWrt plugin: a tiny standalone web page (own port, no login) that toggles a per-device upload/download limit with a hotkey.
Values: -1 = block, 0 = no limit, N = limit to N KB/s. Default: upload -1, download 0.
Limits are removed automatically if the controller (page or Windows script) stops sending heartbeats (`timeout`, default 20s).

Config: `/etc/config/hotkeylimit` (`port`, `timeout`, `enabled`), then `/etc/init.d/hotkeylimit restart`.
Windows global hotkey script (no install): link at the bottom of the page.
