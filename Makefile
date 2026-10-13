include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-hotkeylimit
PKG_VERSION:=1.0
PKG_RELEASE:=10

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
	SECTION:=luci
	CATEGORY:=LuCI
	SUBMENU:=3. Applications
	TITLE:=Hotkey per-device speed limit (standalone lightweight web page)
	DEPENDS:=+uhttpd +nftables-json
	PKGARCH:=all
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/hotkeylimit
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/share/hotkeylimit/www/cgi-bin $(1)/etc/init.d $(1)/etc/config
	$(INSTALL_DATA) $(CURDIR)/root/usr/share/hotkeylimit/www/index.html $(1)/usr/share/hotkeylimit/www/
	$(INSTALL_BIN) $(CURDIR)/root/usr/share/hotkeylimit/www/cgi-bin/api $(1)/usr/share/hotkeylimit/www/cgi-bin/
	$(INSTALL_DATA) $(CURDIR)/root/usr/share/hotkeylimit/lib.sh $(1)/usr/share/hotkeylimit/
	$(INSTALL_DATA) $(CURDIR)/root/usr/share/hotkeylimit/hotkey.ps1.tpl $(1)/usr/share/hotkeylimit/
	$(INSTALL_BIN) $(CURDIR)/root/usr/share/hotkeylimit/watch.sh $(1)/usr/share/hotkeylimit/
	$(INSTALL_BIN) $(CURDIR)/root/etc/init.d/hotkeylimit $(1)/etc/init.d/
	$(INSTALL_CONF) $(CURDIR)/root/etc/config/hotkeylimit $(1)/etc/config/
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || { /etc/init.d/hotkeylimit enable; /etc/init.d/hotkeylimit restart; }
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || { /etc/init.d/hotkeylimit stop; /etc/init.d/hotkeylimit disable; }
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
