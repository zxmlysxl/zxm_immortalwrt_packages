include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-znetcontrol
PKG_VERSION:=1.1.1
PKG_RELEASE:=20260119
PKG_MAINTAINER:=zuoxm <zxmlysxl@gmail.com>

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-znetcontrol
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=ZNetControl - Internet Time Control
  DEPENDS:=+luci-base +luci-compat +nftables
  PKGARCH:=all
endef

define Package/luci-app-znetcontrol/description
  基于MAC地址的网络访问时间管控系统
  支持按时间段、星期和日期范围控制设备上网。
endef

define Package/luci-app-znetcontrol/conffiles
/etc/config/znetcontrol
endef

define Package/luci-app-znetcontrol/postinst
#!/bin/sh
rm -f /tmp/luci-modulecache/*
exit 0
endef

define Build/Compile
endef

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
	
    	# 创建版本标记文件
    	$(INSTALL_DIR) $(1)/etc
    	echo "package_version=$(PKG_VERSION)" > $(1)/etc/znetcontrol.version
    	echo "build_date=$(PKG_RELEASE)" >> $(1)/etc/znetcontrol.version
    	echo "maintainer=$(PKG_MAINTAINER)" >> $(1)/etc/znetcontrol.version
    
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/znetcontrol $(1)/etc/init.d/znetcontrol
	
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/luci-znetcontrol $(1)/etc/uci-defaults/luci-znetcontrol
endef

$(eval $(call BuildPackage,luci-app-znetcontrol))
