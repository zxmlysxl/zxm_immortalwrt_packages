local uci = require("luci.model.uci").cursor()
local sys = require("luci.sys")
local http = require("luci.http")

m = Map("znetcontrol", translate("上网管控规则"), 
    translate("为设备设置上网时间管控规则，支持按MAC地址、时间段和日期进行精确控制"))

s = m:section(TypedSection, "rule", translate("规则列表"))
s.template = "cbi/tblsection"
s.anonymous = true
s.addremove = true
s.sortable = true

-- 规则名称
name = s:option(Value, "name", translate("规则名称"))
name.placeholder = "例如：孩子晚间禁止上网"
name.rmempty = false

-- MAC地址
mac = s:option(Value, "mac", translate("MAC地址"))
mac.placeholder = "例如：AA:BB:CC:DD:EE:FF"
mac.datatype = "macaddr"
mac.rmempty = false

-- 启用状态
enabled = s:option(Flag, "enabled", translate("启用规则"))
enabled.default = "1"
enabled.rmempty = false

-- 生效星期
days = s:option(ListValue, "days", translate("生效星期"))
days:value("", translate("每天"))
days:value("1,2,3,4,5", translate("工作日（周一至周五）"))
days:value("6,7", translate("周末（周六至周日）"))
days:value("1", translate("星期一"))
days:value("2", translate("星期二"))
days:value("3", translate("星期三"))
days:value("4", translate("星期四"))
days:value("5", translate("星期五"))
days:value("6", translate("星期六"))
days:value("7", translate("星期日"))
days.default = ""

-- 开始时间
start_time = s:option(Value, "start_time", translate("开始时间"))
start_time.placeholder = "HH:MM"
start_time.datatype = "timehhmm"

-- 结束时间
end_time = s:option(Value, "end_time", translate("结束时间"))
end_time.placeholder = "HH:MM"
end_time.datatype = "timehhmm"

-- 日期范围
date_range = s:option(Value, "date_range", translate("日期范围"))
date_range.placeholder = "YYYY-MM-DD,YYYY-MM-DD"
date_range.description = translate("留空表示永久生效，格式：开始日期,结束日期")

-- 选择设备按钮
select_btn = s:option(Button, "_select", translate("从在线设备选择"))
select_btn.inputtitle = translate("选择设备")
select_btn.inputstyle = "button"
function select_btn.write()
    http.redirect(http.build_url("admin/control/znetcontrol/devices"))
end

-- 测试规则按钮
test_btn = s:option(Button, "_test", translate("测试规则"))
test_btn.inputtitle = translate("测试")
test_btn.inputstyle = "button"
function test_btn.write(self, section)
    local mac_addr = uci:get("znetcontrol", section, "mac")
    if mac_addr then
        http.redirect(http.build_url("admin/control/znetcontrol/check_device") .. "?mac=" .. mac_addr)
    else
        m.message = translate("请先填写MAC地址")
    end
end

-- 确保新创建的规则有正确的enabled值
function s.create(self, section)
    local new_section = TypedSection.create(self, section)
    uci:set("znetcontrol", new_section, "enabled", "1")
    uci:commit("znetcontrol")
    return new_section
end

-- 保存配置后的处理
function s.parse(self, ...)
    TypedSection.parse(self, ...)
    
    -- 检查是否有规则被修改
    local changed = false
    uci:foreach("znetcontrol", "rule", function(s)
        if uci:get("znetcontrol", s[".name"], "_changed") then
            changed = true
        end
    end)
    
    -- 如果有规则被修改，重新加载服务
    if changed then
        sys.call("/usr/bin/znetcontrol.sh reload >/dev/null 2>&1")
    end
end

-- 整个页面提交后的处理
function m.on_after_commit(self)
    -- 强制重新加载所有规则
    sys.call("/usr/bin/znetcontrol.sh reload >/dev/null 2>&1")
    http.redirect(http.build_url("admin/control/znetcontrol/rules"))
end

return m
