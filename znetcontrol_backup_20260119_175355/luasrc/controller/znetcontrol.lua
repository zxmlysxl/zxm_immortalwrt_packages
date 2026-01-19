module("luci.controller.znetcontrol", package.seeall)

-- 添加版本检测函数
function get_app_version()
    local nixio = require("nixio")
    local version = "1.1.1"  -- 默认版本
    
    -- 方法1：从uci配置中读取保存的版本
    local uci = require("luci.model.uci").cursor()
    local saved_version = uci:get("znetcontrol", "settings", "version")
    if saved_version then
        version = saved_version
    end
    
    -- 方法2：从版本文件中读取
    local version_file = "/etc/znetcontrol.version"
    if nixio.fs.access(version_file) then
        local fd = io.open(version_file, "r")
        if fd then
            for line in fd:lines() do
                local ver_match = line:match("^package_version=(.+)")
                if ver_match then
                    version = ver_match
                    break
                end
            end
            fd:close()
        end
    end
    
    -- 方法3：从opkg信息中读取
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

-- 新增：概览页面控制器
function action_overview()
    local http = require("luci.http")
    local sys = require("luci.sys")
    local uci = require("luci.model.uci").cursor()
    
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
            uptime = "",
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

-- 修改 action_get_status 函数以支持直接返回数据
function action_get_status(return_data)
    local sys = require("luci.sys")
    local uci = require("luci.model.uci").cursor()
    local http = require("luci.http")
    local nixio = require("nixio")
    
    local status = {
        running = false,
        total_rules = 0,
        enabled_rules = 0,
        active_rules = 0,
        uptime = "",
        pid = nil,
        version = get_app_version()  -- 使用动态获取的版本号
    }
    
    -- 检查服务运行状态
    local pid_file = "/var/run/znetcontrol.pid"
    if nixio.fs.access(pid_file) then
        local fd = io.open(pid_file, "r")
        if fd then
            local pid = fd:read("*l")
            fd:close()
            if pid and pid ~= "" then
                local proc_file = "/proc/" .. pid
                if nixio.fs.access(proc_file) then
                    status.running = true
                    status.pid = pid
                    
                    local uptime_cmd = "ps -o etime= -p " .. pid .. " 2>/dev/null"
                    local uptime_output = sys.exec(uptime_cmd)
                    if uptime_output and uptime_output ~= "" then
                        status.uptime = uptime_output:gsub("^%s*(.-)%s*$", "%1")
                    else
                        status.uptime = "运行中"
                    end
                end
            end
        end
    end
    
    -- 检查nftables规则作为后备
    if not status.running then
        local nft_output = sys.exec("nft list table inet znetcontrol 2>/dev/null")
        if nft_output and nft_output ~= "" and nft_output:find("table inet znetcontrol") then
            status.running = true
            status.uptime = "规则已加载"
        end
    end
    
    -- 统计规则（从配置文件）
    local total_count = 0
    local enabled_count = 0
    
    uci:foreach("znetcontrol", "rule", function(s)
        if s[".type"] == "rule" then
            total_count = total_count + 1
            
            local enabled = false
            if s.enabled then
                if s.enabled == "1" or s.enabled == "true" or s.enabled == "on" then
                    enabled = true
                end
            else
                -- 如果没有设置enabled，默认为启用
                enabled = true
            end
            
            if enabled then
                enabled_count = enabled_count + 1
            end
        end
    end)
    
    status.total_rules = total_count
    status.enabled_rules = enabled_count
    
    -- 获取当前生效的规则数（从nftables中）
    local active_count = 0
    local nft_output = sys.exec("nft list table inet znetcontrol 2>/dev/null")
    if nft_output and nft_output ~= "" then
        -- 统计MAC地址
        for mac in nft_output:gmatch("([0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f])") do
            active_count = active_count + 1
        end
        
        -- 统计IP地址
        for ip in nft_output:gmatch("(%d+%.%d+%.%d+%.%d+)") do
            -- 确保是有效的IP地址（不是端口号等）
            if not ip:match(":") then  -- 排除IPv6或带端口的情况
                active_count = active_count + 1
            end
        end
    end
    
    status.active_rules = active_count
    
    -- 如果只需要返回数据，直接返回
    if return_data then
        return status
    end
    
    -- 否则返回JSON格式
    http.prepare_content("application/json")
    http.header("Cache-Control", "no-cache, no-store, must-revalidate")
    http.header("Pragma", "no-cache")
    http.header("Expires", "0")
    
    http.write_json(status)
end

-- 新增：获取防火墙状态
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
            uci:foreach("znetcontrol", "rule", function(s)
                if s.target then
                    -- 比较MAC地址（不区分大小写）
                    local target_mac = s.target:upper():gsub("[-:]", ":"):gsub("%s+", "")
                    if target_mac == mac:upper() then
                        rule_name = s.name or "未命名规则"
                        return false  -- 找到后停止遍历
                    end
                elseif s.mac then  -- 兼容旧版本
                    local target_mac = s.mac:upper():gsub("[-:]", ":"):gsub("%s+", "")
                    if target_mac == mac:upper() then
                        rule_name = s.name or "未命名规则"
                        return false  -- 找到后停止遍历
                    end
                end
            end)
            
            table.insert(devices, {
                type = "mac",
                address = mac:upper(),
                name = rule_name
            })
        end
        
        -- 提取IP地址
        for ip in nft_output:gmatch("(%d+%.%d+%.%d+%.%d+)") do
            -- 确保是有效的IP地址（不是端口号等）
            if not ip:match(":") then  -- 排除IPv6或带端口的情况
                status.ip_count = status.ip_count + 1
                status.blocked_count = status.blocked_count + 1
                
                -- 尝试从配置文件中查找这个IP对应的规则名称
                local rule_name = "未知规则"
                uci:foreach("znetcontrol", "rule", function(s)
                    if s.target and s.target == ip then
                        rule_name = s.name or "未命名规则"
                        return false  -- 找到后停止遍历
                    end
                end)
                
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

function action_logs()
    local sys = require("luci.sys")
    local nixio = require("nixio")
    local http = require("luci.http")
    local uci = require("luci.model.uci").cursor()
    
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
    local uci = require("luci.model.uci").cursor()
    
    local logfile = "/var/log/znetcontrol.log"
    local success = false
    local message = ""
    
    -- 读取配置
    local backup_enabled = uci:get("znetcontrol", "settings", "log_backup_enabled") or "0"
    
    -- 设置HTTP头
    http.prepare_content("application/json")
    http.header("Cache-Control", "no-cache, no-store, must-revalidate")
    http.header("Pragma", "no-cache")
    http.header("Expires", "0")
    
    if nixio.fs.access(logfile) then
        -- 如果启用备份
        if backup_enabled == "1" then
            local timestamp = os.date("%Y%m%d_%H%M%S")
            local backup_file = "/var/log/znetcontrol.log." .. timestamp
            
            -- 备份当前日志
            local backup_result = os.execute(string.format('cp "%s" "%s" 2>/dev/null', logfile, backup_file))
            
            -- 清理7天前的备份
            local cleanup_cmd = "find /var/log -name 'znetcontrol.log.*' -mtime +7 -delete 2>/dev/null"
            os.execute(cleanup_cmd)
            
            message = "日志已备份并清空，备份至: " .. backup_file
        else
            -- 不备份，直接清空
            message = "日志已清空"
        end
        
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
                os.date("%Y-%m-%d %H:%M:%S"),
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
    
    -- 输出JSON
    http.write_json({
        success = success,
        message = message
    })
end

function action_reload_rules()
    local sys = require("luci.sys")
    local http = require("luci.http")
    
    local result = sys.call("/usr/bin/znetcontrol.sh reload >/dev/null 2>&1")
    
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
function action_get_config()
    local uci = require("luci.model.uci").cursor()
    local http = require("luci.http")
    
    local config = {
        log_auto_refresh = uci:get("znetcontrol", "settings", "log_auto_refresh") or "30",
        log_max_lines = uci:get("znetcontrol", "settings", "log_max_lines") or "1000",
        log_backup_enabled = uci:get("znetcontrol", "settings", "log_backup_enabled") or "0"
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
    local http = require("luci.http")
    
    -- 读取POST数据
    local data = luci.http.content()
    local config = luci.jsonc.parse(data)
    
    if config then
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
