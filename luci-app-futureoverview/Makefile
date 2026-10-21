#
# Copyright (C) 2025 Zorro
#

include $(TOPDIR)/rules.mk

NAME:=futureoverview
PKG_NAME:=luci-app-$(NAME)
LUCI_TITLE:=LuCI support for Future Overview (system dashboard)
LUCI_PKGARCH:=all

PKG_VERSION:=1.0.0
PKG_RELEASE:=20261021

define Package/$(PKG_NAME)/description
A custom LuCI dashboard view that replaces the native system status
overview page with a rich, real-time system monitoring view.
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
# 接管原生概览菜单 -> future/overview
F=/usr/share/luci/menu.d/luci-mod-status.json
if [ -f "$F" ]; then
  python3 - "$F" 2>/dev/null <<INNEREOF || true
import json, sys
f = sys.argv[1]
try:
    d = json.load(open(f))
    d["admin/status/overview"] = {
        "title": "概览",
        "order": 1,
        "action": {"type": "view", "path": "future/overview"},
        "depends": {"acl": ["luci-app-futureoverview"]}
    }
    json.dump(d, open(f, "w"), indent=2, ensure_ascii=False)
except Exception:
    pass
INNEREOF
fi
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk
