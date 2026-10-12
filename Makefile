include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-hotkeylimit
PKG_VERSION:=1.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Hotkey per-device speed limit (lightweight web page)
  DEPENDS:=+rpcd +uhttpd-mod-ubus +nftables-json
  PKGARCH:=all
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/www/hotkey-limit $(1)/usr/libexec/rpcd $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) $(CURDIR)/root/www/hotkey-limit/index.html $(1)/www/hotkey-limit/
	$(INSTALL_BIN) $(CURDIR)/root/usr/libexec/rpcd/hotkeylimit $(1)/usr/libexec/rpcd/
	$(INSTALL_DATA) $(CURDIR)/root/usr/share/rpcd/acl.d/hotkeylimit.json $(1)/usr/share/rpcd/acl.d/
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || /etc/init.d/rpcd restart
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
