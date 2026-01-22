local uci = require("luci.model.uci").cursor()
local sys = require("luci.sys")
local http = require("luci.http")

m = Map("znetcontrol", translate("上网管控规则"), 
    translate("为设备设置上网时间管控规则，支持按IP地址或MAC地址、时间段和日期进行精确控制") .. 
    "<br><span style='color: #ff6b6b;'>注意：新规则需要填写有效的IP地址或MAC地址后才能生效</span>")

-- ========== 新增：检查启用规则数量并管理服务 ==========
local function manage_service_by_rules()
    -- 统计启用规则数量
    local enabled_count = 0
    uci:foreach("znetcontrol", "rule", function(s)
        if s[".type"] == "rule" then
            local enabled = (s.enabled ~= "0" and s.enabled ~= "false" and s.enabled ~= "off")
            if enabled then
                enabled_count = enabled_count + 1
            end
        end
    end)
    
    -- 根据规则数量控制服务
    if enabled_count >= 1 then
        -- 有启用规则时启动服务
        sys.call("/etc/init.d/znetcontrol start >/dev/null 2>&1")
        return enabled_count, true
    else
        -- 没有启用规则时停止服务
        sys.call("/etc/init.d/znetcontrol stop >/dev/null 2>&1")
        return enabled_count, false
    end
end

-- ========== 修复：立即应用配置 ==========
-- 覆盖LuCI的默认apply行为
function m.on_after_apply(self)
    -- 提交配置到文件
    uci:commit("znetcontrol")
    
    -- 根据规则数量控制服务
    local enabled_count, service_running = manage_service_by_rules()
    
    -- 如果有启用规则，重新加载规则
    if service_running then
        local result = sys.call("/usr/bin/znetcontrol.sh reload >/dev/null 2>&1")
        sys.call('logger -t znetcontrol "规则已保存，发现 ' .. enabled_count .. ' 条启用规则，服务已启动"')
    else
        sys.call('logger -t znetcontrol "规则已保存，没有启用规则，服务已停止"')
    end
    
    -- 不执行默认的重定向，让LuCI显示成功消息
    return false
end

-- ========== 处理规则删除时的服务状态检查 ==========
local old_remove = s.remove
function s.remove(self, section)
    -- 先删除规则
    old_remove(self, section)
    
    -- 提交配置
    uci:commit("znetcontrol")
    
    -- 检查规则数量并管理服务
    manage_service_by_rules()
    
    return true
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

-- 生效星期
days = s:option(Value, "days", translate("生效星期"))
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
days.placeholder = translate("自定义（如：1-3 或 1,2,3）")
days.rmempty = true

-- 自定义星期验证
function days.validate(self, value, section)
    if value == nil or value == "" then
        return value
    end
    
    -- 移除空格
    value = value:gsub("%s+", "")
    
    -- 检查是否是预设值
    local preset_values = {
        "", "1,2,3,4,5", "6,7", "1", "2", "3", "4", "5", "6", "7"
    }
    for _, v in ipairs(preset_values) do
        if value == v then
            return value
        end
    end
    
    -- 验证自定义格式
    -- 格式1：范围 1-3
    if value:match("^%d+-%d+$") then
        local start_day, end_day = value:match("^(%d+)-(%d+)$")
        start_day = tonumber(start_day)
        end_day = tonumber(end_day)
        
        if start_day and end_day and start_day >= 1 and start_day <= 7 and end_day >= 1 and end_day <= 7 and start_day <= end_day then
            return value
        else
            return nil, translate("自定义星期范围无效（请输入1-7之间的数字，如：1-3）")
        end
    end
    
    -- 格式2：逗号分隔 1,2,3
    if value:match("^%d+(,%d+)*$") then
        local valid = true
        for day in value:gmatch("%d+") do
            day = tonumber(day)
            if not day or day < 1 or day > 7 then
                valid = false
                break
            end
        end
        if valid then
            return value
        else
            return nil, translate("自定义星期列表无效（请输入1-7之间的数字，如：1,2,3）")
        end
    end
    
    -- 无效格式
    return nil, translate("自定义星期格式无效（支持：1-3 或 1,2,3 两种写法）")
end

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

-- ========== 处理新建规则 ==========
function s.create(self, section)
    local section_id = TypedSection.create(self, section)
    
    -- 设置默认值
    uci:set("znetcontrol", section_id, "enabled", "1")
    uci:set("znetcontrol", section_id, "name", "新规则")
    
    return section_id
end

-- ========== 处理删除规则 ==========
function s.remove(self, section)
    TypedSection.remove(self, section)
    return true
end

return m
