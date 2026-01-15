include $(TOPDIR)/rules.mk

LUCI_TITLE:=佐罗上网管控
LUCI_DESCRIPTION:=基于MAC地址的网络访问时间管控系统
LUCI_DEPENDS:=+luci-base +luci-compat
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-znetcontrol
PKG_VERSION:=1.0.4
PKG_RELEASE:=20260115
PKG_MAINTAINER:=zuoxm <zxmlysxl@gmail.com>

include $(TOPDIR)/feeds/luci/luci.mk

# 必须定义安装规则！
define Package/luci-app-znetcontrol/install
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
	$(INSTALL_BIN) ./files/znetcontrol.sh $(1)/usr/bin/znetcontrol.sh
	
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/znetcontrol $(1)/etc/config/znetcontrol
	
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/znetcontrol $(1)/etc/init.d/znetcontrol
	
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/luci-znetcontrol $(1)/etc/uci-defaults/luci-znetcontrol
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
