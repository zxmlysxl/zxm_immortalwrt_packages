include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-znetcontrol
PKG_VERSION:=2.0.8
PKG_RELEASE:=20260208
PKG_MAINTAINER:=zuoxm <zxmlysxl@gmail.com>

LUCI_TITLE:=佐罗上网管控
LUCI_DESCRIPTION:=基于IP/MAC地址的网络访问时间管控系统
LUCI_DEPENDS:=+luci-base +luci-compat +nftables +conntrack +bash +bc
LUCI_PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

# ========== 清除可能存在的重复定义 ==========
undefine Package/$(PKG_NAME)
undefine Package/$(PKG_NAME)/install
undefine Package/$(PKG_NAME)/conffiles
undefine Package/$(PKG_NAME)/postinst

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=$(LUCI_TITLE)
  DESCRIPTION:=$(LUCI_DESCRIPTION)
  DEPENDS:=$(LUCI_DEPENDS)
  PKGARCH:=all
  MAINTAINER:=$(PKG_MAINTAINER)
endef

define Package/$(PKG_NAME)/description
$(LUCI_DESCRIPTION)
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/znetcontrol
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
rm -f /tmp/luci-*
exit 0
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/znetcontrol.lua $(1)/usr/lib/lua/luci/controller/
	
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi/znetcontrol
	$(INSTALL_DATA) ./luasrc/model/cbi/znetcontrol/rules.lua $(1)/usr/lib/lua/luci/model/cbi/znetcontrol/
	
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/znetcontrol
	$(INSTALL_DATA) ./luasrc/view/znetcontrol/*.htm $(1)/usr/lib/lua/luci/view/znetcontrol/
	
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-znetcontrol.json $(1)/usr/share/luci/menu.d/
	
	$(INSTALL_DIR) $(1)/usr/share/luci/applications.d
	$(INSTALL_DATA) ./root/usr/share/luci/applications.d/luci-app-znetcontrol.json $(1)/usr/share/luci/applications.d/
	
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-znetcontrol.json $(1)/usr/share/rpcd/acl.d/
	
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./root/usr/bin/znetcontrol $(1)/usr/bin/znetcontrol
	$(INSTALL_BIN) ./root/usr/bin/znetcontrolctrl $(1)/usr/bin/znetcontrolctrl
	
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/znetcontrol $(1)/etc/config/znetcontrol
	
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/znetcontrol $(1)/etc/init.d/znetcontrol
	
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/luci-znetcontrol $(1)/etc/uci-defaults/luci-znetcontrol
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
