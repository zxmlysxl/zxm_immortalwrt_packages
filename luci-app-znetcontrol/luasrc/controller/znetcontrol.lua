module("luci.controller.znetcontrol", package.seeall)

-- 版本检测函数（不使用版本文件）
function get_app_version()
    local nixio = require("nixio")
    local version = "2.0.0"  -- 默认版本号
    
    -- 尝试从opkg包信息读取
    local control_file = "/usr/lib/opkg/info/luci-app-znetcontrol.control"
    if nixio.fs.access(control_file) then
        local fd = io.open(control_file, "r")
        if fd then
            for line in fd:lines() do
                local ctrl_match = line:match("^Version:%s*(.+)")
                if ctrl_match then
                    version = ctrl_match
                    break
                end
            end
            fd:close()
        end
    else
        -- 如果opkg文件不存在，尝试从另一个位置查找
        control_file = "/usr/lib/opkg/info/luci-app-znetcontrol.control"
        if nixio.fs.access(control_file) then
            local fd = io.open(control_file, "r")
            if fd then
                for line in fd:lines() do
                    local ctrl_match = line:match("^Version:%s*(.+)")
                    if ctrl_match then
                        version = ctrl_match
                        break
                    end
                end
                fd:close()
            end
        end
    end
       
    return version
end

function index()
    -- 检查配置文件是否存在
    if not nixio.fs.access("/etc/config/znetcontrol") then
        return
    end
    
    -- 放到管控菜单下 (admin/control)
    entry({"admin", "control", "znetcontrol"}, firstchild(), _("佐罗上网管控"), 60).index = true
    
    -- 主菜单项
    entry({"admin", "control", "znetcontrol", "overview"}, call("action_overview"), _("概览"), 10)
    entry({"admin", "control", "znetcontrol", "rules"}, cbi("znetcontrol/rules"), _("管控规则"), 20)
    entry({"admin", "control", "znetcontrol", "logs"}, template("znetcontrol/logs"), _("系统日志"), 30)
    entry({"admin", "control", "znetcontrol", "devices"}, template("znetcontrol/devices"), _("在线设备"), 40)
    
    -- API 接口
    entry({"admin", "control", "znetcontrol", "api", "get_status"}, call("action_get_status")).leaf = true
    entry({"admin", "control", "znetcontrol", "api", "get_devices"}, call("action_get_devices")).leaf = true
    entry({"admin", "control", "znetcontrol", "api", "restart"}, call("action_restart")).leaf = true
    entry({"admin", "control", "znetcontrol", "api", "start"}, call("action_start")).leaf = true
    entry({"admin", "control", "znetcontrol", "api", "stop"}, call("action_stop")).leaf = true
    entry({"admin", "control", "znetcontrol", "api", "get_logs"}, call("action_logs")).leaf = true
    entry({"admin", "control", "znetcontrol", "api", "clear_logs"}, call("action_clear_logs")).leaf = true
    entry({"admin", "control", "znetcontrol", "api", "firewall_status"}, call("action_firewall_status")).leaf = true
    entry({"admin", "control", "znetcontrol", "api", "reload_rules"}, call("action_reload_rules")).leaf = true
    entry({"admin", "control", "znetcontrol", "api", "get_config"}, call("action_get_config")).leaf = true
    entry({"admin", "control", "znetcontrol", "api", "save_config"}, call("action_save_config")).leaf = true
end

function action_overview()
    local http = require("luci.http")
    local sys = require("luci.sys")
    
    -- 获取基本状态
    local status_data = {}
    local success, result = pcall(function()
        return action_get_status(true) -- 传递 true 表示直接返回数据
    end)
    
    if success then
        status_data = result
    else
        -- 如果获取失败，使用默认值
        status_data = {
            running = false,
            total_rules = 0,
            enabled_rules = 0,
            active_rules = 0,
            pid = nil,
            version = get_app_version()
        }
    end
    
    -- 渲染模板并传递数据
    http.prepare_content("text/html")
    luci.template.render("znetcontrol/overview", {
        status = status_data
    })
end

function action_get_status(return_data)
    local sys = require("luci.sys")
    local uci = require("luci.model.uci").cursor()
    local http = require("luci.http")
    local nixio = require("nixio")
    
    -- ========== 进程检测 ==========
    local is_running = false
    local main_pid = ""
    local monitor_pid = ""
    
    -- 检查主服务进程
    local main_process = sys.exec("pgrep -f 'znetcontrolctrl' 2>/dev/null | head -1")
    if main_process and main_process ~= "" then
        main_pid = main_process:gsub("%s+", "")
        if tonumber(main_pid) ~= nil then
            local proc_dir = "/proc/" .. main_pid
            if nixio.fs.access(proc_dir) then
                is_running = true
            end
        end
    end
    
    -- 检查监控进程
    local monitor_process = sys.exec("ps w | grep 'znetcontrolctrl' | grep -v grep | head -1")
    if monitor_process and monitor_process ~= "" then
        local parts = {}
        for part in monitor_process:gmatch("%S+") do
            table.insert(parts, part)
        end
        if #parts >= 1 then
            monitor_pid = parts[1]
        end
    end
    
    -- 获取运行时间
    local uptime = ""
    if is_running and main_pid ~= "" then
        uptime = get_process_uptime(main_pid)
    end

    local status = {
        running = is_running,
        total_rules = 0,
        enabled_rules = 0,
        active_rules = 0,
        pid = main_pid ~= "" and main_pid or nil,
        monitor_pid = monitor_pid ~= "" and monitor_pid or nil,
        uptime = uptime,
        version = get_app_version()
    }

    -- ========== 规则统计逻辑 ==========
    -- 使用新的device段统计规则
    local total_count = 0
    local enabled_count = 0
    uci:foreach("znetcontrol", "device", function(s)
        if s[".type"] == "device" then
            total_count = total_count + 1
            local enabled = (s.enable ~= "0" and s.enable ~= "false" and s.enable ~= "off")
            if enabled then
                enabled_count = enabled_count + 1
            end
        end
    end)
    
    -- 如果没有device段，检查旧的rule段（兼容性）
    if total_count == 0 then
        uci:foreach("znetcontrol", "rule", function(s)
            if s[".type"] == "rule" then
                total_count = total_count + 1
                local enabled = (s.enabled ~= "0" and s.enabled ~= "false" and s.enabled ~= "off")
                if enabled then
                    enabled_count = enabled_count + 1
                end
            end
        end)
    end
    
    status.total_rules = total_count
    status.enabled_rules = enabled_count

    -- 获取nftables中的规则数
    local active_count = 0
    local nft_output = sys.exec("nft list table inet znetcontrol 2>/dev/null")
    if nft_output and nft_output ~= "" then
        -- 统计MAC地址
        for mac in nft_output:gmatch("([0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f])") do
            active_count = active_count + 1
        end
        
        -- 统计IP地址（排除集合名称中的数字）
        for ip in nft_output:gmatch("(%d+%.%d+%.%d+%.%d+)") do
            if not ip:match(":") then
                active_count = active_count + 1
            end
        end
    end
    status.active_rules = active_count

    -- ========== 自动服务管理 ==========
    -- 如果有启用规则但服务没运行，尝试启动
    if enabled_count > 0 and not is_running then
        sys.call("/etc/init.d/znetcontrol start >/dev/null 2>&1 &")
        -- 更新状态
        is_running = true
        status.running = true
    -- 没有启用规则但服务在运行，建议停止
    elseif enabled_count == 0 and is_running then
        -- 只是记录，不自动停止，让用户手动处理
        sys.call('logger -t znetcontrol "注意：没有启用规则但服务在运行中"')
    end

    -- ========== 正确处理 return_data 参数 ==========
    if return_data then
        return status  -- 直接返回数据表
    end
    
    -- ========== 返回JSON响应 ==========
    http.prepare_content("application/json")
    http.header("Cache-Control", "no-cache, no-store, must-revalidate")
    http.header("Pragma", "no-cache")
    http.header("Expires", "0")
    http.header("X-Content-Type-Options", "nosniff")
    
    local json_str = string.format('{"running":%s,"total_rules":%d,"enabled_rules":%d,"active_rules":%d,"pid":"%s","monitor_pid":"%s","uptime":"%s","version":"%s"}',
        tostring(is_running),
        status.total_rules,
        status.enabled_rules,
        status.active_rules,
        main_pid or "",
        monitor_pid or "",
        uptime or "",
        status.version or "unknown"
    )
    
    http.write(json_str)
end

-- ========== 新增：获取进程运行时间的函数 ==========
function get_process_uptime(pid)
    local sys = require("luci.sys")
    local nixio = require("nixio")
    
    if not pid or pid == "" then
        return ""
    end
    
    -- 简化：直接使用ps命令获取运行时间
    local ps_uptime = sys.exec("ps -o etime= -p " .. pid .. " 2>/dev/null")
    if ps_uptime and ps_uptime ~= "" then
        -- 清理空白字符
        local trimmed = ps_uptime:gsub("%s+", "")
        if trimmed ~= "" then
            return trimmed
        end
    end
    
    -- 备选方案：检查进程目录存在多久
    local proc_dir = "/proc/" .. pid
    if nixio.fs.access(proc_dir) then
        local stat_info = nixio.fs.stat(proc_dir)
        if stat_info then
            local now = os.time()
            local start_time = stat_info.mtime
            local uptime_seconds = now - start_time
            
            -- 简单格式化
            if uptime_seconds >= 86400 then
                local days = math.floor(uptime_seconds / 86400)
                return days .. "天"
            elseif uptime_seconds >= 3600 then
                local hours = math.floor(uptime_seconds / 3600)
                return hours .. "小时"
            elseif uptime_seconds >= 60 then
                local minutes = math.floor(uptime_seconds / 60)
                return minutes .. "分"
            else
                return uptime_seconds .. "秒"
            end
        end
    end
    
    return ""
end

-- ========== 服务控制函数 ==========
function action_stop()
    local sys = require("luci.sys")
    local http = require("luci.http")
    
    local result = sys.call("/etc/init.d/znetcontrol stop >/dev/null 2>&1")
    
    http.prepare_content("application/json")
    http.header("Cache-Control", "no-cache, no-store, must-revalidate")
    http.header("Pragma", "no-cache")
    http.header("Expires", "0")
    
    http.write_json({
        success = result == 0,
        message = result == 0 and "服务停止成功" or "服务停止失败"
    })
end

function action_restart()
    local sys = require("luci.sys")
    local http = require("luci.http")
    
    local result = sys.call("/etc/init.d/znetcontrol restart >/dev/null 2>&1")
    
    http.prepare_content("application/json")
    http.header("Cache-Control", "no-cache, no-store, must-revalidate")
    http.header("Pragma", "no-cache")
    http.header("Expires", "0")
    
    http.write_json({
        success = result == 0,
        message = result == 0 and "服务重启成功" or "服务重启失败"
    })
end

function action_firewall_status()
    local sys = require("luci.sys")
    local http = require("luci.http")
    local uci = require("luci.model.uci").cursor()
    
    local status = {
        table_exists = false,
        blocked_count = 0,
        mac_count = 0,
        ip_count = 0,
        devices = {}
    }
    
    -- 检查nftables表
    local nft_output = sys.exec("nft list table inet znetcontrol 2>/dev/null")
    
    if nft_output and nft_output ~= "" then
        status.table_exists = true
        
        -- 提取所有设备（MAC和IP）
        local devices = {}
        
        -- 提取MAC地址
        for mac in nft_output:gmatch("([0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f])") do
            status.mac_count = status.mac_count + 1
            status.blocked_count = status.blocked_count + 1
            
            -- 尝试从配置文件中查找这个MAC对应的规则名称
            local rule_name = "未知规则"
            -- 先查device段
            uci:foreach("znetcontrol", "device", function(s)
                if s.target then
                    local target_mac = s.target:upper():gsub("[-:]", ":"):gsub("%s+", "")
                    if target_mac == mac:upper() then
                        rule_name = s.name or "未命名规则"
                        return false  -- 找到后停止遍历
                    end
                end
            end)
            
            -- 如果没有找到，查旧的rule段（兼容性）
            if rule_name == "未知规则" then
                uci:foreach("znetcontrol", "rule", function(s)
                    if s.target then
                        local target_mac = s.target:upper():gsub("[-:]", ":"):gsub("%s+", "")
                        if target_mac == mac:upper() then
                            rule_name = s.name or "未命名规则"
                            return false
                        end
                    elseif s.mac then  -- 兼容旧版本
                        local target_mac = s.mac:upper():gsub("[-:]", ":"):gsub("%s+", "")
                        if target_mac == mac:upper() then
                            rule_name = s.name or "未命名规则"
                            return false
                        end
                    end
                end)
            end
            
            table.insert(devices, {
                type = "mac",
                address = mac:upper(),
                name = rule_name
            })
        end
        
        -- 提取IP地址
        for ip in nft_output:gmatch("(%d+%.%d+%.%d+%.%d+)") do
            -- 确保是有效的IP地址（不是端口号等）
            if not ip:match(":") then
                status.ip_count = status.ip_count + 1
                status.blocked_count = status.blocked_count + 1
                
                -- 尝试从配置文件中查找这个IP对应的规则名称
                local rule_name = "未知规则"
                -- 先查device段
                uci:foreach("znetcontrol", "device", function(s)
                    if s.target and s.target == ip then
                        rule_name = s.name or "未命名规则"
                        return false
                    end
                end)
                
                -- 如果没有找到，查旧的rule段（兼容性）
                if rule_name == "未知规则" then
                    uci:foreach("znetcontrol", "rule", function(s)
                        if s.target and s.target == ip then
                            rule_name = s.name or "未命名规则"
                            return false
                        end
                    end)
                end
                
                table.insert(devices, {
                    type = "ip",
                    address = ip,
                    name = rule_name
                })
            end
        end
        
        status.devices = devices
    end
    
    http.prepare_content("application/json")
    http.header("Cache-Control", "no-cache, no-store, must-revalidate")
    http.header("Pragma", "no-cache")
    http.header("Expires", "0")
    
    http.write_json(status)
end

function action_get_devices()
    local sys = require("luci.sys")
    local http = require("luci.http")
    
    local devices = {}
    local arptable = sys.net.arptable() or {}
    
    for _, entry in ipairs(arptable) do
        if entry["HW address"] and entry["HW address"] ~= "00:00:00:00:00:00" then
            local ip = entry["IP address"] or ""
            local mac = entry["HW address"]:upper()
            local hostname = sys.net.hostname(ip) or ""
            
            -- 尝试从DHCP租约获取主机名
            if hostname == "" then
                local lease = sys.exec("cat /tmp/dhcp.leases 2>/dev/null | grep -i '" .. mac:lower() .. "' | head -1 | awk '{print $4}'")
                if lease and lease ~= "" then
                    hostname = lease:gsub("^%s*(.-)%s*$", "%1")
                end
            end
            
            table.insert(devices, {
                ip = ip,
                mac = mac,
                hostname = hostname ~= "" and hostname or "未知"
            })
        end
    end
    
    -- 按IP地址排序
    table.sort(devices, function(a, b)
        local ip_to_num = function(ip)
            local num = 0
            for octet in ip:gmatch("(%d+)") do
                num = num * 256 + tonumber(octet)
            end
            return num
        end
        
        local num_a = a.ip and ip_to_num(a.ip) or 0
        local num_b = b.ip and ip_to_num(b.ip) or 0
        return num_a < num_b
    end)
    
    http.prepare_content("application/json")
    http.header("Cache-Control", "no-cache, no-store, must-revalidate")
    http.header("Pragma", "no-cache")
    http.header("Expires", "0")
    
    http.write_json(devices)
end

function action_start()
    local sys = require("luci.sys")
    local http = require("luci.http")
    
    local result = sys.call("/etc/init.d/znetcontrol start >/dev/null 2>&1")
    
    http.prepare_content("application/json")
    http.header("Cache-Control", "no-cache, no-store, must-revalidate")
    http.header("Pragma", "no-cache")
    http.header("Expires", "0")
    
    http.write_json({
        success = result == 0,
        message = result == 0 and "服务启动成功" or "服务启动失败"
    })
end

function action_logs()
    local sys = require("luci.sys")
    local nixio = require("nixio")
    local http = require("luci.http")
    
    local logs = {}
    local logfile = "/var/log/znetcontrol.log"
    
    -- 确保日志文件存在
    if not nixio.fs.access(logfile) then
        sys.call("mkdir -p /var/log 2>/dev/null")
        sys.call("touch " .. logfile)
        -- 添加初始日志
        local init_log = generate_startup_log()
        for _, line in ipairs(init_log) do
            table.insert(logs, line)
        end
    else
        -- 读取日志文件
        local fd = io.open(logfile, "r")
        if fd then
            for line in fd:lines() do
                table.insert(logs, line)
            end
            fd:close()
        end
    end
    
    -- 限制日志行数（保留最近的5000行）
    if #logs > 5000 then
        local start_index = #logs - 4999
        local recent_logs = {}
        for i = start_index, #logs do
            table.insert(recent_logs, logs[i])
        end
        logs = recent_logs
    end
    
    http.prepare_content("application/json")
    http.header("Cache-Control", "no-cache, no-store, must-revalidate")
    http.header("Pragma", "no-cache")
    http.header("Expires", "0")
    
    http.write_json(logs)
end

-- 生成启动日志
function generate_startup_log()
    local logs = {}
    local current_time = os.date("%Y-%m-%d %H:%M:%S")
    local weekdays = {"星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"}
    local weekday = weekdays[tonumber(os.date("%w")) + 1]
    local version = get_app_version()
    
    table.insert(logs, "╔════════════════════════════════════════════════════════════╗")
    table.insert(logs, string.format("║                  佐罗上网管控系统 v%s 启动                    ║", version))
    table.insert(logs, "╠════════════════════════════════════════════════════════════╣")
    table.insert(logs, "║ 版本: " .. version .. " | 作者: zuoxm                                ║")
    table.insert(logs, "║ 功能: MAC/IP地址时间控制 | 支持输入/转发链                ║")
    table.insert(logs, "╠════════════════════════════════════════════════════════════╣")
    table.insert(logs, "║ 启动时间: " .. current_time .. string.rep(" ", 45 - #current_time) .. "║")
    table.insert(logs, "║ 星期: " .. weekday .. string.rep(" ", 50 - #weekday * 2) .. "║")
    table.insert(logs, "╚════════════════════════════════════════════════════════════╝")
    table.insert(logs, "")
    
    return logs
end

-- 清空日志
function action_clear_logs()
    local sys = require("luci.sys")
    local nixio = require("nixio")
    local http = require("luci.http")
    
    local logfile = "/var/log/znetcontrol.log"
    local success = false
    local message = ""
    
    http.prepare_content("application/json")
    http.header("Cache-Control", "no-cache, no-store, must-revalidate")
    http.header("Pragma", "no-cache")
    http.header("Expires", "0")
    
    if nixio.fs.access(logfile) then
        -- 备份当前日志
        local timestamp = os.date("%Y%m%d_%H%M%S")
        local backup_file = "/var/log/znetcontrol.log." .. timestamp
        
        -- 备份当前日志
        local backup_result = os.execute(string.format('cp "%s" "%s" 2>/dev/null', logfile, backup_file))
        
        -- 清空日志文件
        local fd = io.open(logfile, "w")
        if fd then
            fd:close()
            success = true
            
            -- 添加初始日志
            local version = get_app_version()
            local init_log = string.format(
                "%s - 日志已清空，开始新的日志记录\n%s - 系统启动\n%s - ====== 启动佐罗上网管控 v%s ======",
                os.date("%Y-%m-%d %H:%M:%S"),
                os.date("%Y-%m-%d %H:%M:%S"),
                os.date("%Y-%m-%d %H:%M:%S"),
                version
            )
            
            local fd2 = io.open(logfile, "a")
            if fd2 then
                fd2:write(init_log .. "\n")
                fd2:close()
            end
            
            message = "日志已备份并清空，备份至: " .. backup_file
        else
            success = false
            message = "清空日志失败"
        end
    else
        -- 创建新的日志文件
        local fd = io.open(logfile, "w")
        if fd then
            local version = get_app_version()
            local init_log = string.format(
                "%s - 日志文件已创建\n%s - 系统启动 (v%s)",
                os.date("%Y-%m-d %H:%M:%S"),
                os.date("%Y-%m-%d %H:%M:%S"),
                version
            )
            fd:write(init_log .. "\n")
            fd:close()
            success = true
            message = "日志文件已创建"
        else
            success = false
            message = "创建日志文件失败"
        end
    end
    
    http.write_json({
        success = success,
        message = message
    })
end

function action_reload_rules()
    local sys = require("luci.sys")
    local http = require("luci.http")
    
    local result = sys.call("/usr/bin/znetcontrol reload >/dev/null 2>&1")
    
    http.prepare_content("application/json")
    http.header("Cache-Control", "no-cache, no-store, must-revalidate")
    http.header("Pragma", "no-cache")
    http.header("Expires", "0")
    
    http.write_json({
        success = result == 0,
        message = result == 0 and "规则重新加载成功" or "规则重新加载失败"
    })
end

-- 获取配置
-- 获取配置
function action_get_config()
    local uci = require("luci.model.uci").cursor()
    local http = require("luci.http")
    
    local config = {
        log_level = uci:get("znetcontrol", "settings", "log_level") or "info",
        control_mode = uci:get("znetcontrol", "settings", "control_mode") or "blacklist"
    }
    
    http.prepare_content("application/json")
    http.header("Cache-Control", "no-cache, no-store, must-revalidate")
    http.header("Pragma", "no-cache")
    http.header("Expires", "0")
    
    http.write_json(config)
end

-- 保存配置
function action_save_config()
    local uci = require("luci.model.uci").cursor()
    local sys = require("luci.sys")
    local http = require("luci.http")
    
    -- 读取POST数据
    local data = luci.http.content()
    local config = luci.jsonc.parse(data)
    
    if config then
        -- 创建或更新settings段
        local section_id = uci:get("znetcontrol", "settings")
        if not section_id then
            uci:section("znetcontrol", "global", "settings", {
                enabled = "1",
                log_level = "info",
                control_mode = "blacklist"
            })
        end
        
        -- 保存配置
        if config.log_level then
            uci:set("znetcontrol", "settings", "log_level", config.log_level)
        end
        
        if config.control_mode then
            uci:set("znetcontrol", "settings", "control_mode", config.control_mode)
        end
        
        uci:commit("znetcontrol")
    end
    
    http.prepare_content("application/json")
    http.header("Cache-Control", "no-cache, no-store, must-revalidate")
    http.header("Pragma", "no-cache")
    http.header("Expires", "0")
    
    http.write_json({
        success = true,
        message = "配置已保存"
    })
end

-- 保存配置
function action_save_config()
    local uci = require("luci.model.uci").cursor()
    local http = require("luci.http")
    
    -- 读取POST数据
    local data = luci.http.content()
    local config = luci.jsonc.parse(data)
    
    if config then
        -- 创建或更新settings段
        local section_id = uci:get("znetcontrol", "settings")
        if not section_id then
            uci:section("znetcontrol", "global", "settings", {
                enabled = "1",
                log_level = "info"
            })
        end
        
        -- 保存配置
        if config.log_auto_refresh then
            uci:set("znetcontrol", "settings", "log_auto_refresh", config.log_auto_refresh)
        end
        
        if config.log_max_lines then
            uci:set("znetcontrol", "settings", "log_max_lines", config.log_max_lines)
        end
        
        if config.log_backup_enabled then
            uci:set("znetcontrol", "settings", "log_backup_enabled", config.log_backup_enabled)
        end
        
        if config.control_mode then
            uci:set("znetcontrol", "settings", "control_mode", config.control_mode)
        end
        
        if config.chain then
            uci:set("znetcontrol", "settings", "chain", config.chain)
        end
        
        uci:commit("znetcontrol")
        
        -- 重新启动服务使配置生效
        sys.call("/etc/init.d/znetcontrol restart >/dev/null 2>&1 &")
    end
    
    http.prepare_content("application/json")
    http.header("Cache-Control", "no-cache, no-store, must-revalidate")
    http.header("Pragma", "no-cache")
    http.header("Expires", "0")
    
    http.write_json({
        success = true,
        message = "配置已保存"
    })
end

-- 格式化运行时间函数（供视图使用）
function format_uptime(seconds)
    seconds = math.floor(tonumber(seconds) or 0)
    
    if seconds <= 0 then
        return "0秒"
    end
    
    local days = math.floor(seconds / 86400)
    seconds = seconds % 86400
    
    local hours = math.floor(seconds / 3600)
    seconds = seconds % 3600
    
    local minutes = math.floor(seconds / 60)
    seconds = seconds % 60
    
    local parts = {}
    
    if days > 0 then
        table.insert(parts, days .. "天")
    end
    if hours > 0 then
        table.insert(parts, hours .. "小时")
    end
    if minutes > 0 then
        table.insert(parts, minutes .. "分")
    end
    if seconds > 0 or #parts == 0 then
        table.insert(parts, seconds .. "秒")
    end
    
    return table.concat(parts, " ")
end

