module("luci.controller.znetcontrol", package.seeall)

-- 辅助日志函数（如果不存在）
local function log(message, data)
    local nixio = require("nixio")
    local logfile = "/var/log/znetcontrol.log"
    
    -- 创建日志目录
    os.execute("mkdir -p /var/log 2>/dev/null")
    
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local log_entry = string.format("[%s] %s", timestamp, message)
    
    if data then
        if type(data) == "table" then
            for k, v in pairs(data) do
                log_entry = log_entry .. string.format(" %s=%s", k, tostring(v))
            end
        else
            log_entry = log_entry .. " " .. tostring(data)
        end
    end
    
    local fd = io.open(logfile, "a")
    if fd then
        fd:write(log_entry .. "\n")
        fd:close()
    end
end

-- 版本检测函数（不使用版本文件）
function get_app_version()
    local nixio = require("nixio")
    local version = "2.1.3"
    
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
    entry({"admin", "control", "znetcontrol", "api", "quick_add"}, call("action_quick_add")).leaf = true
end

-- 快速添加规则函数
function action_quick_add()
    local http = require("luci.http")
    local uci = require("luci.model.uci").cursor()
    local sys = require("luci.sys")
    
    http.prepare_content("application/json")
    local data = http.formvalue()
    
    local target = data and data.target
    local target_type = data and data.type
    local name = data and data.name
    
    log("快速添加规则 - 接收参数:", {
        target = target,
        type = target_type,
        name = name
    })
    
    if not target then
        http.write_json({
            success = false,
            message = "目标地址不能为空"
        })
        return
    end
    
    local original_target = target
    target = target:upper():gsub("%s+", ""):gsub("-", ":")
    
    local exists = false
    local existing_name = ""
    uci:foreach("znetcontrol", "device", function(s)
        if s.target and s.target:upper():gsub("%s+", ""):gsub("-", ":") == target then
            exists = true
            existing_name = s.name or "未命名规则"
        end
    end)
    
    if exists then
        http.write_json({
            success = false,
            message = "该设备已在规则中（规则名称: " .. existing_name .. "）"
        })
        return
    end
    
    if not name or name == "" or name == "undefined" then
        if target_type == "mac" then
            local mac_clean = target:gsub(":", ""):gsub("-", "")
            local suffix = mac_clean:sub(-6) or "未知"
            name = "设备_" .. suffix
            log("生成MAC规则名称:", name)
        else
            name = "IP_" .. target:gsub("%.", "_")
            log("生成IP规则名称:", name)
        end
    end
    
    local original_name = name
    
    name = name:gsub("%.lan$", "")
    name = name:gsub("%.local$", "")
    name = name:gsub("%.home$", "")
    name = name:gsub("%.domain$", "")
    name = name:gsub("%.com$", "")
    name = name:gsub("%.net$", "")
    name = name:gsub("%.org$", "")
    name = name:gsub("[<>\"'`]", "")
    
    if #name > 50 then
        name = name:sub(1, 50)
    end
    
    if name == "" then
        if target_type == "mac" then
            local mac_clean = target:gsub(":", ""):gsub("-", "")
            local suffix = mac_clean:sub(-6) or "未知"
            name = "设备_" .. suffix
        else
            name = "IP_" .. target:gsub("%.", "_")
        end
    end
    
    log("清理后规则名称:", name, "（原始:", original_name .. "）")
    
    local section_id = uci:section("znetcontrol", "device", nil, {
        name = name,
        target = target,
        enable = "1",
        week = "0",
        chain = "forward",
        timestart = "00:00",
        timeend = "00:00",
        comment = "从在线设备页面快速添加"
    })
    
    uci:commit("znetcontrol")
    
    log("规则添加成功", {
        id = section_id,
        name = name,
        target = target,
        original_target = original_target
    })
    
    local restart_result = sys.call("/etc/init.d/znetcontrol restart >/dev/null 2>&1 &")
    
    http.write_json({
        success = true,
        message = "规则添加成功",
        data = {
            id = section_id,
            name = name,
            target = target
        }
    })
end

function action_overview()
    local http = require("luci.http")
    local sys = require("luci.sys")
    
    local status_data = {}
    local success, result = pcall(function()
        return action_get_status(true)
    end)
    
    if success then
        status_data = result
    else
        status_data = {
            running = false,
            total_rules = 0,
            enabled_rules = 0,
            active_rules = 0,
            pid = nil,
            version = get_app_version()
        }
    end
    
    http.prepare_content("text/html")
    luci.template.render("znetcontrol/overview", {
        status = status_data
    })
end

-- ========== 修复：gateway_mode 作用域问题 ==========
function action_get_status(return_data)
    local sys = require("luci.sys")
    local uci = require("luci.model.uci").cursor()
    local http = require("luci.http")
    local nixio = require("nixio")
    
    -- 服务状态检测
    local is_running = false
    local main_pid = ""
    
    local pgrep_result = sys.exec("pgrep -f 'znetcontrolctrl' 2>/dev/null")
    if pgrep_result and pgrep_result ~= "" then
        main_pid = pgrep_result:match("%d+")
        if main_pid then
            local proc_dir = "/proc/" .. main_pid
            if nixio.fs.access(proc_dir) then
                is_running = true
            end
        end
    end
    
    -- 运行时间
    local uptime = ""
    if is_running and main_pid ~= "" then
        uptime = get_process_uptime(main_pid)
    end

    -- 规则统计
    local total_count = 0
    local enabled_count = 0
    local active_count = 0
    
    uci:foreach("znetcontrol", "device", function(s)
        if s[".type"] == "device" then
            total_count = total_count + 1
            local enabled = (s.enable == "1" or s.enable == "on" or s.enable == "true")
            if enabled then
                enabled_count = enabled_count + 1
            end
        end
    end)
    
    local idlist_file = "/var/run/znetcontrol.idlist"
    if nixio.fs.access(idlist_file) then
        local fd = io.open(idlist_file, "r")
        if fd then
            local content = fd:read("*all")
            fd:close()
            if content then
                for _ in content:gmatch("![0-9]+!") do
                    active_count = active_count + 1
                end
            end
        end
    end
    
    -- nftables规则计数 + 网关模式检测
    local nft_count = 0
    local gateway_mode = ""
    
    if is_running then
        local default_gw = sys.exec("ip route show default 2>/dev/null | head -1 | awk '{print $3}'") or ""
        local default_dev = sys.exec("ip route show default 2>/dev/null | head -1 | awk '{print $5}'") or ""
        local lan_iface = sys.exec("uci get network.lan.ifname 2>/dev/null || echo br-lan") or "br-lan"
        default_gw = default_gw:gsub("%s+", "")
        default_dev = default_dev:gsub("%s+", "")
        lan_iface = lan_iface:gsub("%s+", "")
        
        if default_dev ~= "" and default_dev ~= lan_iface then
            gateway_mode = "main"
        elseif default_gw == "" or default_gw == "0.0.0.0" then
            gateway_mode = "main"
        else
            gateway_mode = "bypass"
        end
        
        if gateway_mode == "bypass" then
            nft_count = tonumber(sys.exec("nft list table inet znetcontrol 2>/dev/null | grep -c 'drop comment'")) or 0
        else
            local bridge_count = tonumber(sys.exec("nft list table bridge znetcontrol 2>/dev/null | grep -c 'drop comment'")) or 0
            local ip_count = tonumber(sys.exec("nft list table ip znetcontrol 2>/dev/null | grep -c 'drop comment'")) or 0
            nft_count = bridge_count + ip_count
        end
    else
        local default_dev = sys.exec("ip route show default 2>/dev/null | head -1 | awk '{print $5}'") or ""
        local default_gw = sys.exec("ip route show default 2>/dev/null | head -1 | awk '{print $3}'") or ""
        local lan_iface = sys.exec("uci get network.lan.ifname 2>/dev/null || echo br-lan") or "br-lan"
        default_dev = default_dev:gsub("%s+", "")
        default_gw = default_gw:gsub("%s+", "")
        lan_iface = lan_iface:gsub("%s+", "")
        
        if default_dev ~= "" and default_dev ~= lan_iface then
            gateway_mode = "main"
        elseif default_gw == "" or default_gw == "0.0.0.0" then
            gateway_mode = "main"
        else
            gateway_mode = "bypass"
        end
    end
    
    local status = {
        running = is_running,
        gateway_mode = gateway_mode,
        total_rules = total_count,
        enabled_rules = enabled_count,
        active_rules = active_count,
        nft_rules = nft_count,
        pid = main_pid or "",
        uptime = uptime or "",
        version = get_app_version()
    }

    if return_data then
        return status
    end
    
    http.prepare_content("application/json")
    http.header("Cache-Control", "no-cache, no-store, must-revalidate")
    http.header("Pragma", "no-cache")
    http.header("Expires", "0")
    
    local json = require("luci.jsonc")
    http.write_json(status)
end

function get_process_uptime(pid)
    local sys = require("luci.sys")
    local nixio = require("nixio")
    
    if not pid or pid == "" then
        return ""
    end
    
    local ps_uptime = sys.exec("ps -o etime= -p " .. pid .. " 2>/dev/null")
    if ps_uptime and ps_uptime ~= "" then
        local trimmed = ps_uptime:gsub("%s+", "")
        if trimmed ~= "" then
            return trimmed
        end
    end
    
    local proc_dir = "/proc/" .. pid
    if nixio.fs.access(proc_dir) then
        local stat_info = nixio.fs.stat(proc_dir)
        if stat_info then
            local now = os.time()
            local start_time = stat_info.mtime
            local uptime_seconds = now - start_time
            
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
        mac_marked_count = 0,
        devices = {},
        tables_found = {}
    }
    
    local tables_to_check = {
        {name = "inet znetcontrol", type = "inet"},
        {name = "ip znetcontrol", type = "ip"},
        {name = "ip6 znetcontrol", type = "ip6"},
        {name = "bridge znetcontrol", type = "bridge"},
        {name = "inet znetcontrol_mark", type = "mark"}
    }
    
    for _, table_info in ipairs(tables_to_check) do
        local cmd = "nft list table " .. table_info.name .. " 2>/dev/null"
        local output = sys.exec(cmd)
        
        if output and output ~= "" then
            status.table_exists = true
            status.tables_found[table_info.name] = true
            analyze_nft_table(output, table_info.type, status)
        end
    end
    
    http.prepare_content("application/json")
    http.write_json(status)
end

function analyze_nft_table(output, table_type, status)
    local drop_count = 0
    for _ in output:gmatch("drop comment") do
        drop_count = drop_count + 1
    end
    
    status.blocked_count = status.blocked_count + drop_count
    
    if table_type == "bridge" then
        local has_mac_elements = false
        for line in output:gmatch("[^\r\n]+") do
            if line:match("elements =") and line:match("{") then
                if not line:match("elements = { }") then
                    has_mac_elements = true
                    local element_count = 0
                    for _ in line:gmatch("([0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f])") do
                        element_count = element_count + 1
                    end
                    status.mac_count = element_count
                    break
                end
            end
        end
        
        if not has_mac_elements then
            status.mac_count = 0
        end
        
    elseif table_type == "ip" then
        local has_ip_elements = false
        for line in output:gmatch("[^\r\n]+") do
            if line:match("elements =") and line:match("{") then
                if not line:match("elements = { }") then
                    has_ip_elements = true
                    local element_count = 0
                    for _ in line:gmatch("(%d+%.%d+%.%d+%.%d+)") do
                        element_count = element_count + 1
                    end
                    status.ip_count = element_count
                    break
                end
            end
        end
        
        if not has_ip_elements then
            status.ip_count = 0
        end
        
    elseif table_type == "mark" then
        for line in output:gmatch("[^\r\n]+") do
            if line:match("elements =") and line:match("{") then
                if not line:match("elements = { }") then
                    local element_count = 0
                    for _ in line:gmatch("([0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f])") do
                        element_count = element_count + 1
                    end
                    status.mac_marked_count = element_count
                    break
                end
            end
        end
    end
end

function action_get_devices()
    local sys = require("luci.sys")
    local http = require("luci.http")
    local uci = require("luci.model.uci").cursor()
    local nixio = require("nixio")
    
    local configured_devices = {}
    uci:foreach("znetcontrol", "device", function(s)
        if s.target then
            local target = s.target:upper():gsub("%s+", ""):gsub("-", ":")
            configured_devices[target] = true
        end
    end)
    
    uci:foreach("znetcontrol", "rule", function(s)
        if s.target then
            local target = s.target:upper():gsub("%s+", ""):gsub("-", ":")
            configured_devices[target] = true
        elseif s.mac then
            local target = s.mac:upper():gsub("%s+", ""):gsub("-", ":")
            configured_devices[target] = true
        end
    end)
    
    local devices = {}
    
    local arp_cmd = "ip -4 neighbor show 2>/dev/null | grep -v FAILED || arp -n 2>/dev/null"
    local arp_output = sys.exec(arp_cmd)
    
    if arp_output and arp_output ~= "" then
        for line in arp_output:gmatch("[^\r\n]+") do
            local ip, mac = line:match("^(%d+%.%d+%.%d+%.%d+).-([0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F])")
            
            if ip and mac and mac:upper() ~= "00:00:00:00:00:00" then
                mac = mac:upper()
                local hostname = "未知设备"
                
                local dns_result = sys.exec("nslookup " .. ip .. " 2>/dev/null | grep 'name =' | head -1")
                if dns_result and dns_result ~= "" then
                    local name = dns_result:match("name =%s*(.+)$")
                    if name then
                        name = name:gsub("%.$", "")
                        if name ~= ip then
                            hostname = name
                        end
                    end
                end
                
                if hostname == "未知设备" then
                    local dhcp_files = {
                        "/tmp/dhcp.leases",
                        "/var/dhcp.leases",
                        "/tmp/dnsmasq.leases"
                    }
                    
                    for _, dhcp_file in ipairs(dhcp_files) do
                        if nixio.fs.access(dhcp_file) then
                            local fd = io.open(dhcp_file, "r")
                            if fd then
                                for lease_line in fd:lines() do
                                    local parts = {}
                                    for part in lease_line:gmatch("%S+") do
                                        table.insert(parts, part)
                                    end
                                    
                                    if #parts >= 4 then
                                        local lease_mac = parts[2]:upper():gsub("-", ":")
                                        local lease_ip = parts[3]
                                        local lease_hostname = parts[4]
                                        
                                        if (lease_mac == mac or lease_ip == ip) and 
                                           lease_hostname and lease_hostname ~= "*" and 
                                           lease_hostname ~= "" then
                                            hostname = lease_hostname
                                            fd:close()
                                            break
                                        end
                                    end
                                end
                                fd:close()
                            end
                        end
                    end
                end
                
                if hostname == "未知设备" then
                    local hosts_content = sys.exec("cat /etc/hosts 2>/dev/null | grep -w " .. ip)
                    if hosts_content and hosts_content ~= "" then
                        for hosts_line in hosts_content:gmatch("[^\r\n]+") do
                            local hosts_parts = {}
                            for part in hosts_line:gmatch("%S+") do
                                table.insert(hosts_parts, part)
                            end
                            if #hosts_parts >= 2 and hosts_parts[1] == ip then
                                hostname = hosts_parts[2]
                                break
                            end
                        end
                    end
                end
                
                if hostname == "未知设备" then
                    local nmb_result = sys.exec("nmblookup -A " .. ip .. " 2>/dev/null | grep '<00>' | head -1")
                    if nmb_result and nmb_result ~= "" then
                        local nbname = nmb_result:match("^%s*(%S+)%s+")
                        if nbname then
                            hostname = nbname
                        end
                    end
                end
                
                local mac_in_rules = configured_devices[mac] or false
                local ip_in_rules = configured_devices[ip] or false
                local is_configured = mac_in_rules or ip_in_rules
                
                table.insert(devices, {
                    ip = ip,
                    mac = mac,
                    hostname = hostname,
                    is_configured = is_configured,
                    mac_in_rules = mac_in_rules,
                    ip_in_rules = ip_in_rules
                })
            end
        end
    end
    
    if #devices == 0 then
        local arp_content = sys.exec("cat /proc/net/arp 2>/dev/null")
        if arp_content and arp_content ~= "" then
            for line in arp_content:gmatch("[^\r\n]+") do
                if not line:match("^IP address") then
                    local parts = {}
                    for part in line:gmatch("%S+") do
                        table.insert(parts, part)
                    end
                    
                    if #parts >= 6 then
                        local ip = parts[1]
                        local mac = parts[4]:upper()
                        local hostname = "未知设备"
                        
                        if mac and mac ~= "00:00:00:00:00:00" then
                            local lease = sys.exec("cat /tmp/dhcp.leases 2>/dev/null | grep -i '" .. mac:lower() .. "' | head -1")
                            if lease and lease ~= "" then
                                local lease_parts = {}
                                for part in lease:gmatch("%S+") do
                                    table.insert(lease_parts, part)
                                end
                                if #lease_parts >= 4 and lease_parts[4] ~= "*" then
                                    hostname = lease_parts[4]
                                end
                            end
                            
                            table.insert(devices, {
                                ip = ip,
                                mac = mac,
                                hostname = hostname,
                                is_configured = false
                            })
                        end
                    end
                end
            end
        end
    end
    
    http.prepare_content("application/json")
    http.header("Cache-Control", "no-cache, no-store, must-revalidate")
    http.header("Pragma", "no-cache")
    http.header("Expires", "0")
    
    http.write_json(devices or {})
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
    
    if not nixio.fs.access(logfile) then
        sys.call("mkdir -p /var/log 2>/dev/null")
        sys.call("touch " .. logfile)
        local init_log = generate_startup_log()
        for _, line in ipairs(init_log) do
            table.insert(logs, line)
        end
    else
        local fd = io.open(logfile, "r")
        if fd then
            for line in fd:lines() do
                table.insert(logs, line)
            end
            fd:close()
        end
    end
    
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
        local timestamp = os.date("%Y%m%d_%H%M%S")
        local backup_file = "/var/log/znetcontrol.log." .. timestamp
        
        local backup_result = os.execute(string.format('cp "%s" "%s" 2>/dev/null', logfile, backup_file))
        
        local fd = io.open(logfile, "w")
        if fd then
            fd:close()
            success = true
            
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

function action_get_config()
    local uci = require("luci.model.uci").cursor()
    local http = require("luci.http")
    
    local config = {
        log_level = uci:get("znetcontrol", "settings", "log_level") or "info",
        control_mode = uci:get("znetcontrol", "settings", "control_mode") or "blacklist",
        log_auto_refresh = uci:get("znetcontrol", "settings", "log_auto_refresh") or "30",
        log_max_lines = uci:get("znetcontrol", "settings", "log_max_lines") or "1000",
        log_backup_enabled = uci:get("znetcontrol", "settings", "log_backup_enabled") or "0",
        auto_refresh_enabled = uci:get("znetcontrol", "settings", "auto_refresh_enabled") or "1"
    }
    
    http.prepare_content("application/json")
    http.header("Cache-Control", "no-cache, no-store, must-revalidate")
    http.header("Pragma", "no-cache")
    http.header("Expires", "0")
    
    http.write_json(config)
end

function action_save_config()
    local uci = require("luci.model.uci").cursor()
    local sys = require("luci.sys")
    local http = require("luci.http")
    
    local data = luci.http.content()
    local config = luci.jsonc.parse(data)
    
    if config then
        local section_id = uci:get("znetcontrol", "settings")
        if not section_id then
            uci:section("znetcontrol", "global", "settings", {
                enabled = "1",
                log_level = "info",
                control_mode = "blacklist"
            })
        end
        
        local config_map = {
            log_level = "log_level",
            control_mode = "control_mode",
            log_auto_refresh = "log_auto_refresh",
            log_max_lines = "log_max_lines",
            log_backup_enabled = "log_backup_enabled",
            auto_refresh_enabled = "auto_refresh_enabled"
        }
        
        for json_key, uci_key in pairs(config_map) do
            if config[json_key] then
                uci:set("znetcontrol", "settings", uci_key, config[json_key])
            end
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
