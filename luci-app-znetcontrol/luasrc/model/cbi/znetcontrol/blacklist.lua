local m, s, e
local uci = require("luci.model.uci").cursor()
local sys = require("luci.sys")
local http = require("luci.http")

m = Map("znetcontrol", translate("MAC 黑名单"),
    translate("把设备加入黑名单后，该设备无法上网（全天 24 小时生效，不看时间、不看星期）。") ..
    "<br><span style='color: var(--znc-warn-text);'>改动保存后不会立刻生效，必须点击页面底部「保存并应用」才会下发到防火墙。</span>" ..
    "<br><span style='color: var(--znc-success-text);'>与「上网管控规则」完全独立：时间规则按时间段放行/阻断，黑名单只看开关。</span>" ..
    "<br><span style='color: var(--znc-warn-text);'>只能拦截经过本路由器的流量。若设备走了其它出口（如别的热点/自有链路），本功能无法拦截。</span>" ..
    "<style>:root{--znc-danger-text:#dc3545;--znc-primary-text:#007bff;--znc-success-text:#28a745;--znc-warn-text:#6f42c1;}html[data-zncolor=dark]{--znc-danger-text:#ff8a95;--znc-primary-text:#4dabf7;--znc-success-text:#4fd67a;--znc-warn-text:#ffd75e;}</style>")

-- 确保 settings 段存在
local function ensure_settings()
    if not uci:get("znetcontrol", "settings") then
        uci:section("znetcontrol", "global", "settings", { enabled = "1", log_level = "info" })
        uci:commit("znetcontrol")
    end
end
ensure_settings()

-- 【2.3.22 最终】下发在 on_after_commit（commit 阶段，nft 按下发新 UCI 写好）。
-- 绝不调 uci:commit（会清掉暂存，导致标准 apply 报“没有待应用的更改”、倒计时丢失）。
-- blacklist-apply 脚本内部用 `uci -q get` 读已提交 UCI，commit 完成后值已是最新，直接跑即可。
function m.on_after_commit(self)
	sys.call("/usr/bin/znetcontrol blacklist-apply >/dev/null 2>&1")
	sys.call('logger -t znetcontrol "黑名单保存并应用 → blacklist-apply 下发（commit 阶段，无 uci:commit 以免清暂存）"')
end

s = m:section(TypedSection, "blacklist", translate("黑名单列表"),
    translate("填写 MAC 地址或 IP 地址之一即可。推荐用 MAC（设备换 IP 后依然有效）。"))
s.anonymous = true
s.addremove = true
s.template = "cbi/tblsection"
s.sortable = true

e = s:option(Flag, "enable", translate("启用"))
e.default = 1
e.rmempty = false

e = s:option(Value, "mac", translate("MAC 地址"))
e.placeholder = "AA:BB:CC:DD:EE:FF"
e.datatype = "list(string)"
e.rmempty = true
e.description = translate("支持 AA:BB:CC:DD:EE:FF、aa-bb-cc-dd-ee-ff 两种写法；留空表示本条不按 MAC 拦截")

function e.validate(self, value, section)
    if not value or value == "" then
        return value
    end
    local v = value:upper():gsub("%s+", ""):gsub("-", ":")
    if v == "00:00:00:00:00:00" then
        return nil, translate("MAC 不能为全零")
    end
    if not v:match("^[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]$") then
        return nil, translate("MAC 格式不正确，正确格式如：AA:BB:CC:DD:EE:FF")
    end
    return v
end

e = s:option(Value, "ip", translate("IPv4 地址"))
e.placeholder = "192.168.32.50"
e.datatype = "list(string)"
e.rmempty = true
e.description = translate("可选。填了会同时按 IP 拦截；设备换 IP 后需手动改")

function e.validate(self, value, section)
    if not value or value == "" then
        return value
    end
    local v = value:gsub("%s+", "")
    local a, b, c, d = v:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not (a and b and c and d) then
        return nil, translate("IPv4 格式不正确")
    end
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if a > 255 or b > 255 or c > 255 or d > 255 then
        return nil, translate("IPv4 每段必须在 0-255 之间")
    end
    return v
end

e = s:option(Value, "ip6", translate("IPv6 地址"))
e.placeholder = "2409:8a38:... （可选）"
e.rmempty = true
e.description = translate("可选。纯 IPv6 设备需要填这一项才能拦住")

e = s:option(Flag, "boost", translate("强力"))
e.default = 0
e.rmempty = true
e.description = translate("勾选后连访问路由器本身也断（默认只断外网）。注意：勾选后该设备也无法打开 192.168.32.1 管理页")

e = s:option(Value, "comment", translate("备注"))
e.placeholder = translate("可选，例如：电视-客厅")
e.rmempty = true

-- 新建时给默认值
function s.create(self, section)
    local id = TypedSection.create(self, section)
    uci:set("znetcontrol", id, "enable", "1")
    uci:set("znetcontrol", id, "boost", "0")
    return id
end

return m
