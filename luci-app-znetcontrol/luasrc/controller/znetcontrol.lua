module("luci.controller.znetcontrol", package.seeall)

function index()
    -- 检查配置文件是否存在
    if not nixio.fs.access("/etc/config/znetcontrol") then
        return
    end
    
    -- 放到管控菜单下 (admin/control)
    entry({"admin", "control", "znetcontrol"}, firstchild(), _("佐罗上网管控"), 60).index = true
    
    -- 主菜单项
    entry({"admin", "control", "znetcontrol", "overview"}, template("znetcontrol/overview"), _("概览"), 10)
    entry({"admin", "control", "znetcontrol", "rules"}, cbi("znetcontrol/rules"), _("管控规则"), 20)
    entry({"admin", "control", "znetcontrol", "status"}, template("znetcontrol/status"), _("系统状态"), 30)
    entry({"admin", "control", "znetcontrol", "devices"}, template("znetcontrol/devices"), _("在线设备"), 40)
    
    -- API 接口
    entry({"admin", "control", "znetcontrol", "get_status"}, call("action_get_status")).leaf = true
    entry({"admin", "control", "znetcontrol", "get_devices"}, call("action_get_devices")).leaf = true
    entry({"admin", "control", "znetcontrol", "restart"}, call("action_restart")).leaf = true
    entry({"admin", "control", "znetcontrol", "logs"}, call("action_logs")).leaf = true
    entry({"admin", "control", "znetcontrol", "clear_logs"}, call("action_clear_logs")).leaf = true
    entry({"admin", "control", "znetcontrol", "firewall_status"}, call("action_firewall_status")).leaf = true
    entry({"admin", "control", "znetcontrol", "reload_rules"}, call("action_reload_rules")).leaf = true
end

function action_get_status()
    local sys = require("luci.sys")
    local uci = require("luci.model.uci").cursor()
    local http = require("luci.http")
    local nixio = require("nixio")
    
    local status = {
        running = false,
        total_rules = 0,
        enabled_rules = 0,
        uptime = "",
        pid = nil,
        version = "1.0.3"
    }
    
    -- 方法1：检查PID文件
    local pid_file = "/var/run/znetcontrol.pid"
    if nixio.fs.access(pid_file) then
        local fd = io.open(pid_file, "r")
        if fd then
            local pid = fd:read("*l")
            fd:close()
            if pid and pid ~= "" then
                -- 检查进程是否存在
                local proc_file = "/proc/" .. pid
                if nixio.fs.access(proc_file) then
                    status.running = true
                    status.pid = pid
                    
                    -- 获取进程启动时间
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
    
    -- 方法2：如果PID检查失败，检查nftables规则
    if not status.running then
        local nft_output = sys.exec("nft list table inet znetcontrol 2>/dev/null")
        if nft_output and nft_output ~= "" and nft_output:find("table inet znetcontrol") then
            status.running = true
            status.uptime = "规则已加载"
        end
    end
    
    -- 改进的规则统计逻辑
    local total_count = 0
    local enabled_count = 0
    
    uci:foreach("znetcontrol", "rule", function(s)
        if s[".type"] == "rule" then  -- 确保是rule类型
            total_count = total_count + 1
            
            -- 检查enabled状态
            local enabled = false
            if s.enabled then
                if s.enabled == "1" or s.enabled == "true" or s.enabled == "on" then
                    enabled = true
                end
            else
                -- 如果没有enabled字段，默认启用
                enabled = true
            end
            
            if enabled then
                enabled_count = enabled_count + 1
            end
        end
    end)
    
    status.total_rules = total_count
    status.enabled_rules = enabled_count
    
    http.prepare_content("application/json")
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
    http.write_json(devices)
end

function action_restart()
    local sys = require("luci.sys")
    local http = require("luci.http")
    
    local result = sys.call("/etc/init.d/znetcontrol restart >/dev/null 2>&1")
    
    http.prepare_content("application/json")
    http.write_json({
        success = result == 0,
        message = result == 0 and "服务重启成功" or "服务重启失败"
    })
end

function action_logs()
    local sys = require("luci.sys")
    local nixio = require("nixio")
    local http = require("luci.http")
    
    local logs = {}
    local logfile = "/var/log/znetcontrol.log"
    
    if nixio.fs.access(logfile) then
        local fd = io.open(logfile, "r")
        if fd then
            for line in fd:lines() do
                table.insert(logs, line)
            end
            fd:close()
        end
    else
        -- 如果没有日志文件，返回最近的系统日志
        local log_output = sys.exec("logread | grep -i znetcontrol | tail -50 2>/dev/null")
        if log_output and log_output ~= "" then
            for line in log_output:gmatch("[^\r\n]+") do
                table.insert(logs, line)
            end
        end
    end
    
    -- 限制日志行数
    if #logs > 100 then
        logs = {unpack(logs, #logs - 99)}
    end
    
    http.prepare_content("application/json")
    http.write_json(logs)
end

function action_clear_logs()
    local sys = require("luci.sys")
    local nixio = require("nixio")
    local http = require("luci.http")
    
    local logfile = "/var/log/znetcontrol.log"
    local success = false
    local message = ""
    
    if nixio.fs.access(logfile) then
        -- 备份当前日志
        local timestamp = os.date("%Y%m%d_%H%M%S")
        local backup_file = "/var/log/znetcontrol.log." .. timestamp
        sys.call("cp " .. logfile .. " " .. backup_file .. " 2>/dev/null")
        
        -- 清空日志文件
        local result = sys.call("echo '' > " .. logfile .. " 2>/dev/null")
        
        if result == 0 then
            success = true
            message = "日志已清空"
        else
            success = false
            message = "清空日志失败"
        end
    else
        success = true
        message = "日志文件不存在"
    end
    
    http.prepare_content("application/json")
    http.write_json({
        success = success,
        message = message
    })
end

function action_firewall_status()
    local sys = require("luci.sys")
    local http = require("luci.http")
    
    local status = {
        exists = false,
        blocked_count = 0,
        table_info = ""
    }
    
    local output = sys.exec("nft list table inet znetcontrol 2>/dev/null")
    if output and output ~= "" then
        status.exists = true
        status.table_info = output:sub(1, 200)  -- 截取前200字符
        
        -- 统计被阻止的设备数量
        local count = 0
        for line in output:gmatch("[^\r\n]+") do
            if line:match("elements =") then
                -- 统计MAC地址
                for _ in line:gmatch("([%x%x:]+[%x%x:]+[%x%x:]+[%x%x:]+[%x%x:]+[%x%x])") do
                    count = count + 1
                end
                -- 统计IP地址
                for _ in line:gmatch("(%d+%.%d+%.%d+%.%d+)") do
                    count = count + 1
                end
            end
        end
        status.blocked_count = count
    end
    
    http.prepare_content("application/json")
    http.write_json(status)
end

function action_reload_rules()
    local sys = require("luci.sys")
    local http = require("luci.http")
    
    local result = sys.call("/usr/bin/znetcontrol.sh reload >/dev/null 2>&1")
    
    http.prepare_content("application/json")
    http.write_json({
        success = result == 0,
        message = result == 0 and "规则重新加载成功" or "规则重新加载失败"
    })
end
