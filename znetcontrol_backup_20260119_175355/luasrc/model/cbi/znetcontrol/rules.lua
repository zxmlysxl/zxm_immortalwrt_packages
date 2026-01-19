local uci = require("luci.model.uci").cursor()
local sys = require("luci.sys")

m = Map("znetcontrol", translate("上网管控规则"), 
    translate("为设备设置上网时间管控规则，支持按IP地址或MAC地址、时间段和日期进行精确控制") .. 
    "<br><span style='color: #ff6b6b;'>注意：新规则需要填写有效的IP地址或MAC地址后才能生效</span>")

m.on_after_save = function(self)
    -- 确保配置提交
    uci:commit("znetcontrol")
    
    -- 重新加载规则
    sys.call("/usr/bin/znetcontrol.sh reload >/dev/null 2>&1")
    
    return true
end

m.on_after_commit = function(self)
    luci.http.redirect(luci.dispatcher.build_url("admin/control/znetcontrol/rules"))
end

s = m:section(TypedSection, "rule", translate("规则列表"))
s.template = "cbi/tblsection"
s.anonymous = true
s.addremove = true
s.sortable = true

-- 规则名称
name = s:option(Value, "name", translate("规则名称"))
name.placeholder = "例如：孩子晚间禁止上网"
name.rmempty = false
name.default = "新规则"

-- 目标地址（IP或MAC）
target = s:option(Value, "target", translate("IP/MAC地址"))
target.placeholder = "IP地址如: 192.168.1.100 或 MAC地址如: AA:BB:CC:DD:EE:FF"
target.rmempty = false
target.description = translate("请输入有效的IP地址或MAC地址，不能为空且不能为全零MAC地址")

-- 目标地址验证
function target.validate(self, value, section)
    if not value or value == "" then
        return nil, translate("目标地址不能为空")
    end
    
    -- 转换为大写并移除空格
    value = value:upper():gsub("%s+", ""):gsub("-", ":")
    
    -- 检查是否为IP地址
    if value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$") then
        local a, b, c, d = value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
        a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
        if a and b and c and d and a >= 0 and a <= 255 and b >= 0 and b <= 255 
           and c >= 0 and c <= 255 and d >= 0 and d <= 255 then
            return value
        else
            return nil, translate("IP地址格式不正确")
        end
    -- 检查是否为MAC地址
    elseif value:match("^[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]$") then
        -- 检查是否是全零的MAC地址
        if value == "00:00:00:00:00:00" then
            return nil, translate("MAC地址不能为全零")
        end
        return value
    else
        return nil, translate("目标地址格式不正确，请输入有效的IP地址或MAC地址")
    end
end

-- 启用状态
enabled = s:option(Flag, "enabled", translate("启用规则"))
enabled.default = true
enabled.rmempty = false

function enabled.cfgvalue(self, section)
    local val = uci:get("znetcontrol", section, "enabled")
    if val == "1" or val == "true" or val == nil then
        return true
    else
        return false
    end
end

function enabled.write(self, section, value)
    local save_val = "0"
    if value == true or value == "1" or value == "true" then
        save_val = "1"
    end
    uci:set("znetcontrol", section, "enabled", save_val)
end

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
days.rmempty = true

-- 开始时间
start_time = s:option(Value, "start_time", translate("开始时间"))
start_time.placeholder = "HH:MM (24小时制)"
start_time.datatype = "string"
start_time.rmempty = true

function start_time.validate(self, value, section)
    if value == nil or value == "" then
        return value
    end
    
    value = value:gsub("%s+", "")
    
    if not value:match("^[0-9][0-9]?:[0-9][0-9]$") then
        return nil, translate("时间格式不正确，正确格式如：00:00 或 23:00")
    end
    
    local hour, minute = value:match("([0-9]+):([0-9]+)")
    hour = tonumber(hour)
    minute = tonumber(minute)
    
    if hour < 0 or hour > 23 then
        return nil, translate("小时必须在0-23之间")
    end
    
    if minute < 0 or minute > 59 then
        return nil, translate("分钟必须在0-59之间")
    end
    
    local formatted_hour = string.format("%02d", hour)
    local formatted_minute = string.format("%02d", minute)
    
    return formatted_hour .. ":" .. formatted_minute
end

-- 结束时间
end_time = s:option(Value, "end_time", translate("结束时间"))
end_time.placeholder = "HH:MM (24小时制)"
end_time.datatype = "string"
end_time.rmempty = true

function end_time.validate(self, value, section)
    if value == nil or value == "" then
        return value
    end
    
    value = value:gsub("%s+", "")
    
    if not value:match("^[0-9][0-9]?:[0-9][0-9]$") then
        return nil, translate("时间格式不正确，正确格式如：00:00 或 23:00")
    end
    
    local hour, minute = value:match("([0-9]+):([0-9]+)")
    hour = tonumber(hour)
    minute = tonumber(minute)
    
    if hour < 0 or hour > 23 then
        return nil, translate("小时必须在0-23之间")
    end
    
    if minute < 0 or minute > 59 then
        return nil, translate("分钟必须在0-59之间")
    end
    
    local formatted_hour = string.format("%02d", hour)
    local formatted_minute = string.format("%02d", minute)
    
    return formatted_hour .. ":" .. formatted_minute
end

-- 处理新建规则
function s.create(self, section)
    local section_id = TypedSection.create(self, section)
    
    -- 设置默认值，但不设置目标地址（让用户自己填写）
    uci:set("znetcontrol", section_id, "enabled", "1")
    uci:set("znetcontrol", section_id, "name", "新规则")
    -- 不要设置默认的目标地址
    
    uci:commit("znetcontrol")
    
    return section_id
end

-- 处理删除规则
function s.remove(self, section)
    -- 先获取当前规则信息
    local target_value = uci:get("znetcontrol", section, "target")
    
    TypedSection.remove(self, section)
    uci:commit("znetcontrol")
    
    -- 如果被删除的规则有目标地址，重新加载规则
    if target_value and target_value ~= "" then
        sys.call("/usr/bin/znetcontrol.sh reload >/dev/null 2>&1")
    end
    
    return true
end

-- 自定义保存逻辑
function s.parse(self, ...)
    local result = TypedSection.parse(self, ...)
    
    if result then
        -- 保存成功后提交
        uci:commit("znetcontrol")
        
        -- 重新加载规则（只在有实际更改时）
        sys.call("/usr/bin/znetcontrol.sh reload >/dev/null 2>&1")
    end
    
    return result
end

-- 全局设置部分
s2 = m:section(TypedSection, "global", translate("全局设置"))
s2.anonymous = true
s2.addremove = false

-- 服务启用
enabled = s2:option(Flag, "enabled", translate("启用服务"))
enabled.default = true
enabled.rmempty = false

-- 日志自动刷新间隔
refresh_interval = s2:option(ListValue, "log_auto_refresh", translate("日志自动刷新间隔"))
refresh_interval:value("5", translate("5秒"))
refresh_interval:value("10", translate("10秒"))
refresh_interval:value("30", translate("30秒"))
refresh_interval:value("60", translate("60秒"))
refresh_interval:value("120", translate("2分钟"))
refresh_interval:value("300", translate("5分钟"))
refresh_interval:value("0", translate("不自动刷新"))
refresh_interval.default = "30"
refresh_interval.rmempty = false

-- 日志最大显示行数
log_max_lines = s2:option(ListValue, "log_max_lines", translate("日志最大显示行数"))
log_max_lines:value("100", translate("100行"))
log_max_lines:value("500", translate("500行"))
log_max_lines:value("1000", translate("1000行"))
log_max_lines:value("2000", translate("2000行"))
log_max_lines:value("5000", translate("5000行"))
log_max_lines.default = "1000"
log_max_lines.rmempty = false

-- 日志备份设置
log_backup = s2:option(ListValue, "log_backup_enabled", translate("清空日志时备份"))
log_backup:value("0", translate("不备份（直接清空）"))
log_backup:value("1", translate("备份（保留7天）"))
log_backup.default = "0"
log_backup.rmempty = false
log_backup.description = translate("启用备份会保留最近7天的日志文件，占用更多存储空间")

return m
