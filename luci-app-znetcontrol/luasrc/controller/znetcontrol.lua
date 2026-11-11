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
    -- 方法1: apk info（ImmortalWrt APK 固件）
    local f = io.popen("apk info luci-app-znetcontrol 2>/dev/null")
    if f then
        local output = f:read("*a")
        f:close()
        local version = output:match("luci%-app%-znetcontrol%-(%d+%.%d+%.%d+%-[rf]%d+)")
        if version and version ~= "" then
            return version
        end
    end

    -- 方法2: opkg list-installed（标准 OpenWrt opkg 固件）
    local f2 = io.popen("opkg list-installed luci-app-znetcontrol 2>/dev/null")
    if f2 then
        local output = f2:read("*a")
        f2:close()
        local version = output:match("luci%-app%-znetcontrol%s+-%s+([%d%.%-]+)")
        if version and version ~= "" then
            return version
        end
    end

    -- 方法3: 读control文件（fallback）
    local nixio = require("nixio")
    local control_file = "/usr/lib/opkg/info/luci-app-znetcontrol.control"
    if nixio.fs.access(control_file) then
        local fd = io.open(control_file, "r")
        if fd then
            for line in fd:lines() do
                local ctrl_match = line:match("^Version:%s*(.+)")
                if ctrl_match then
                    return ctrl_match
                end
            end
            fd:close()
        end
    end

    return "unknown"
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
    entry({"admin", "control", "znetcontrol", "schedule"}, cbi("znetcontrol/schedule"), _("定时任务"), 25)
    entry({"admin", "control", "znetcontrol", "blacklist"}, cbi("znetcontrol/blacklist"), _("MAC 黑名单"), 27)
    entry({"admin", "control", "znetcontrol", "logs"}, template("znetcontrol/logs"), _("系统日志"), 30)
    entry({"admin", "control", "znetcontrol", "devices"}, template("znetcontrol/devices"), _("在线设备"), 40)
    
    -- API 接口
    entry({"admin", "control", "znetcontrol", "api", "get_status"}, call("action_get_status")).leaf = true
    entry({"admin", "control", "znetcontrol", "api", "get_devices"}, call("action_get_devices")).leaf = true
    entry({"admin", "control", "znetcontrol", "api", "rule_status"}, call("action_rule_status")).leaf = true
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

-- ========== 2.3.13：在线设备采集重写（缺陷①） ==========
-- 历史问题：只从 ip -4 neighbor / /proc/net/arp / DHCP 租约取数，
-- 纯 IPv6 设备（例：无线电视，路由器上只有 IPv6、无任何 IPv4 租约、
-- /proc/net/arp 里也没有）永远不出现在"在线设备"列表里，
-- 用户看到"规则配了但设备不在列表"，无从判断规则是否真的下发。
-- 现在合并五类来源：
--   1) ip -4 neigh show
--   2) ip -6 neigh show（解析 lladdr 与 IPv6 地址，IPv6-only 设备必须列出）
--   3) /tmp/dhcp.leases、/var/dhcp.leases、/tmp/dnsmasq.leases
--   4) /etc/config/dhcp 静态租约（离线也列出）
--   5) UCI 已配规则但不在任何邻居表中的 target（标注离线）

local function znc_norm_mac(v)
    if not v then return "" end
    v = tostring(v):upper():gsub("%s+", ""):gsub("%-", ":")
    if v:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then return v end
    return ""
end

local function znc_is_ipv4(v)
    if not v then return false end
    local a, b, c, d = v:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return false end
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if not (a and b and c and d) then return false end
    return a <= 255 and b <= 255 and c <= 255 and d <= 255
end

local function znc_is_ipv6(v)
    if not v then return false end
    v = tostring(v):gsub("%%.*$", "")
    if #v < 3 then return false end
    if not v:find(":") then return false end
    if not v:match("^[%x:]+$") then return false end
    return true
end

local function znc_mac_pattern()
    return "([0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F])"
end

function action_get_devices()
    local sys = require("luci.sys")
    local http = require("luci.http")
    local uci = require("luci.model.uci").cursor()

    local macpat = znc_mac_pattern()

    -- ---- 规则目标集合（判断"是否已配规则"） ----
    local rule_macs = {}
    local rule_ips = {}
    local function add_rule_target(t)
        if not t or t == "" then return end
        local v = tostring(t):gsub("%s+", "")
        local mac = znc_norm_mac(v)
        if mac ~= "" then
            rule_macs[mac] = true
            return
        end
        if znc_is_ipv4(v) then
            rule_ips[v] = true
            return
        end
        if znc_is_ipv6(v) then
            rule_ips[v:lower()] = true
        end
    end

    uci:foreach("znetcontrol", "device", function(s)
        add_rule_target(s.target)
    end)
    uci:foreach("znetcontrol", "rule", function(s)
        add_rule_target(s.target or s.mac)
    end)

    -- ---- 设备聚合表 ----
    local devices = {}
    local idx_by_mac = {}
    local idx_by_ip = {}

    local function ensure_entry(mac, ip, src)
        local i
        if mac ~= "" and idx_by_mac[mac] then
            i = idx_by_mac[mac]
        elseif ip ~= "" and ip ~= nil and idx_by_ip[ip] then
            i = idx_by_ip[ip]
        end
        if i then
            local e = devices[i]
            if mac ~= "" and e.mac == "" then
                e.mac = mac
                idx_by_mac[mac] = i
            end
            if ip and ip ~= "" and e.ip == "" then
                e.ip = ip
                idx_by_ip[ip] = i
            end
            if src then e.sources[src] = true end
            return e
        end
        local e = {
            mac = mac or "",
            ip = ip or "",
            hostname = "",
            online = false,
            ipv4 = {},
            ipv6 = {},
            sources = {}
        }
        if src then e.sources[src] = true end
        table.insert(devices, e)
        i = #devices
        if e.mac ~= "" then idx_by_mac[e.mac] = i end
        if e.ip ~= "" then idx_by_ip[e.ip] = i end
        return e
    end

    -- ---- 来源 1：ip -4 neigh show ----
    local out = sys.exec("ip -4 neigh show 2>/dev/null") or ""
    for line in out:gmatch("[^\r\n]+") do
        local ip = line:match("^(%d+%.%d+%.%d+%.%d+)")
        if ip and znc_is_ipv4(ip) then
            local mac = line:match("lladdr%s+" .. macpat)
            if mac then
                mac = znc_norm_mac(mac)
                if mac ~= "" then
                    local e = ensure_entry(mac, ip, "neigh4")
                    e.online = true
                    e.ipv4[ip] = true
                end
            end
        end
    end

    -- ---- 来源 2：ip -6 neigh show（IPv6-only 设备必须出现） ----
    out = sys.exec("ip -6 neigh show 2>/dev/null") or ""
    for line in out:gmatch("[^\r\n]+") do
        local tokens = {}
        for tk in line:gmatch("%S+") do tokens[#tokens + 1] = tk end
        local mac = ""
        local addr = ""
        for i = 1, #tokens do
            local tk = tokens[i]
            if mac == "" and tk:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
                mac = znc_norm_mac(tk)
            end
        end
        if mac ~= "" then
            for i = 1, #tokens do
                local tk = tokens[i]
                if tk ~= "lladdr" and not tk:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$")
                   and znc_is_ipv6(tk) then
                    addr = (tk:gsub("%%.*$", ""))
                    break
                end
            end
            if addr ~= "" then
                local e = ensure_entry(mac, "", "neigh6")
                e.online = true
                e.ipv6[addr] = true
            end
        end
    end

    -- ---- 来源 3：DHCP 租约（三种文件路径） ----
    local lease_files = { "/tmp/dhcp.leases", "/var/dhcp.leases", "/tmp/dnsmasq.leases" }
    local now = os.time()
    for _, lf in ipairs(lease_files) do
        local fd = io.open(lf, "r")
        if fd then
            for l in fd:lines() do
                local expiry, mac, ip, host = l:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
                if mac and ip then
                    mac = znc_norm_mac(mac)
                    if mac ~= "" and znc_is_ipv4(ip) then
                        local e = ensure_entry(mac, ip, "dhcp")
                        e.ipv4[ip] = true
                        if host and host ~= "*" and e.hostname == "" then
                            e.hostname = host
                        end
                        local exp = tonumber(expiry)
                        if exp and exp > now then
                            e.online = true
                        end
                    end
                end
            end
            fd:close()
        end
    end

    -- ---- 来源 4：/etc/config/dhcp 静态租约（离线也列出） ----
    pcall(function()
        uci:foreach("dhcp", "host", function(s)
            local mac = znc_norm_mac(s.mac)
            if mac ~= "" then
                local ip = ""
                if znc_is_ipv4(s.ip or "") then ip = s.ip end
                local e = ensure_entry(mac, ip, "static")
                if ip ~= "" then e.ipv4[ip] = true end
                if e.hostname == "" and s.name and s.name ~= "" then
                    e.hostname = s.name
                end
            end
        end)
    end)

    -- ---- 来源 5：/proc/net/arp（flags 0x2 为有效条目） ----
    out = sys.exec("cat /proc/net/arp 2>/dev/null") or ""
    for line in out:gmatch("[^\r\n]+") do
        if not line:match("^IP address") then
            local ip, flags, mac = line:match("^(%S+)%s+%S+%s+(%S+)%s+(%S+)")
            if ip and mac and znc_is_ipv4(ip) then
                mac = znc_norm_mac(mac)
                if mac ~= "" and mac ~= "00:00:00:00:00:00" then
                    local e = ensure_entry(mac, ip, "arp")
                    e.ipv4[ip] = true
                    if flags == "0x2" then e.online = true end
                end
            end
        end
    end

    -- ---- 来源 6：已配规则但不在任何邻居表中的 target（离线） ----
    for mac, _ in pairs(rule_macs) do
        ensure_entry(mac, "", "rule")
    end
    for ip, _ in pairs(rule_ips) do
        if znc_is_ipv4(ip) then
            local e = ensure_entry("", ip, "rule")
            e.ipv4[ip] = true
        elseif znc_is_ipv6(ip) then
            local e = ensure_entry("", "", "rule")
            e.ipv6[ip] = true
        end
    end

    -- ---- 主机名解析（性能：先批量，再仅对前 10 个未命名设备做有限 DNS 查询） ----
    local hosts_map = {}
    local hout = sys.exec("cat /etc/hosts 2>/dev/null") or ""
    for line in hout:gmatch("[^\r\n]+") do
        local ip, host = line:match("^(%S+)%s+(%S+)")
        if ip and host and znc_is_ipv4(ip) then hosts_map[ip] = host end
    end

    local dns_budget = 10
    for _, e in ipairs(devices) do
        if e.hostname == "" and e.ip ~= "" then
            if hosts_map[e.ip] then
                e.hostname = hosts_map[e.ip]
                e.sources["hosts"] = true
            elseif dns_budget > 0 then
                dns_budget = dns_budget - 1
                local ns = sys.exec("nslookup " .. e.ip .. " 2>/dev/null") or ""
                local nm = ns:match("name%s*=%s*(%S+)") or ns:match("[Nn]ame:%s*(%S+)")
                if nm and nm ~= e.ip then
                    e.hostname = (nm:gsub("%.$", ""))
                    e.sources["dns"] = true
                end
                if e.hostname == "" then
                    local nb = sys.exec("nmblookup -A " .. e.ip .. " 2>/dev/null") or ""
                    local nbname = nb:match("%S+%s+(%S+)%s+<00>")
                    if nbname and nbname ~= e.ip then
                        e.hostname = nbname
                        e.sources["netbios"] = true
                    end
                end
            end
        end
    end

    -- ---- 输出 ----
    local result = {}
    for _, e in ipairs(devices) do
        local mac_in_rules = (e.mac ~= "" and rule_macs[e.mac]) and true or false
        local ip_in_rules = (e.ip ~= "" and rule_ips[e.ip]) and true or false
        local v6_in_rules = false
        for a, _ in pairs(e.ipv6) do
            if rule_ips[a:lower()] then v6_in_rules = true end
        end

        local ipv4, ipv6, srcs = {}, {}, {}
        for a, _ in pairs(e.ipv4) do table.insert(ipv4, a) end
        for a, _ in pairs(e.ipv6) do table.insert(ipv6, a) end
        for a, _ in pairs(e.sources) do table.insert(srcs, a) end
        table.sort(ipv4)
        table.sort(ipv6)
        table.sort(srcs)

        table.insert(result, {
            ip = e.ip,
            mac = e.mac,
            hostname = (e.hostname ~= "" and e.hostname) or "未知设备",
            online = e.online and true or false,
            is_configured = (mac_in_rules or ip_in_rules or v6_in_rules) and true or false,
            mac_in_rules = mac_in_rules,
            ip_in_rules = ip_in_rules,
            ipv4 = ipv4,
            ipv6 = ipv6,
            ipv6_only = (e.ip == "" and #ipv6 > 0) and true or false,
            sources = srcs
        })
    end

    http.prepare_content("application/json")
    http.header("Cache-Control", "no-cache, no-store, must-revalidate")
    http.header("Pragma", "no-cache")
    http.header("Expires", "0")

    http.write_json(result)
end

-- ========== 2.3.13：规则下发状态（缺陷③） ==========
-- 目的：区分"规则已下发但设备无流量命中"与"规则根本没下发"
-- 数据来源：
--   - UCI 规则本身（名称/target/启用/时段/星期）
--   - nft -a list chain inet znetcontrol forward（按 comment znc-r<id>-fwd 查 handle）
--     同一条规则行里的 counter packets / bytes 即命中包数与字节数

local function znc_week_match(week, cur_wd)
    if not week or week == "" or week == "0" then return true end
    week = week:gsub("%s+", "")
    for part in week:gmatch("[^,]+") do
        part = part:gsub("%s+", "")
        local a, b = part:match("^(%d+)%-(%d+)$")
        if a then
            a, b = tonumber(a), tonumber(b)
            if a and b and a >= 1 and b <= 7 and a <= b and cur_wd >= a and cur_wd <= b then
                return true
            end
        else
            local n = tonumber(part)
            if n and n == cur_wd then return true end
        end
    end
    return false
end

local function znc_to_min(v)
    if not v then return nil end
    local digits = tostring(v):gsub("%D", "")
    if #digits < 3 then digits = digits .. string.rep("0", 4 - #digits) end
    digits = digits:sub(1, 4)
    local h = tonumber(digits:sub(1, 2))
    local m = tonumber(digits:sub(3, 4))
    if not h then return nil end
    return h * 60 + (m or 0)
end

local function znc_time_match(start_t, end_t, cur_min)
    if (not start_t or start_t == "") and (not end_t or end_t == "") then
        return true, "全天生效"
    end
    if not start_t or start_t == "" then start_t = "00:00" end
    if not end_t or end_t == "" then end_t = "23:59" end
    local s = znc_to_min(start_t)
    local e = znc_to_min(end_t)
    if not s or not e then return false, "不在时段内" end
    if s < e then
        if cur_min >= s and cur_min < e then return true, "生效时段内" end
    else
        if cur_min >= s or cur_min < e then return true, "生效时段内" end
    end
    return false, "不在时段内"
end

function action_rule_status()
    local sys = require("luci.sys")
    local http = require("luci.http")
    local uci = require("luci.model.uci").cursor()

    -- 解析 nft 链上的规则（按 comment 归并）
    local nft_rules = {}
    local function parse_chain(chain)
        local o = sys.exec("nft -a list chain inet znetcontrol " .. chain .. " 2>/dev/null") or ""
        for line in o:gmatch("[^\r\n]+") do
            local cm = line:match('comment%s+"([^"]+)"')
            if cm then
                local handle = line:match("#%s*handle%s+(%d+)")
                local packets, bytes = line:match("packets%s+(%d+)%s+bytes%s+(%d+)")
                local e = nft_rules[cm] or {}
                e.handle = handle or e.handle
                if packets then e.packets = tonumber(packets) end
                if bytes then e.bytes = tonumber(bytes) end
                nft_rules[cm] = e
            end
        end
    end
    parse_chain("forward")
    parse_chain("input")

    -- 集合元素（IP 规则走集合，不走独立 rule）
    local function set_elements(name)
        local o = sys.exec("nft list set inet znetcontrol " .. name .. " 2>/dev/null") or ""
        local s = {}
        for m in o:gmatch("elements%s*=%s*{([^}]*)}") do
            for e in m:gmatch("[^,%s]+") do s[e] = true end
        end
        return s
    end
    local ip_fwd = set_elements("ip_forward")
    local ip6_fwd = set_elements("ip6_forward")

    -- 共享集合（保底）
    local mac_fwd = set_elements("mac_forward")

    local t = os.date("*t")
    local cur_wd = t.wday == 0 and 7 or t.wday   -- 1=周一 .. 7=周日
    local cur_min = (t.hour or 0) * 60 + (t.min or 0)

    local result = {}
    uci:foreach("znetcontrol", "device", function(s)
        local idx = s.index or 0
        local target = s.target or ""
        local name = s.name or ("规则" .. tostring(idx))

        local enable = s.enable
        local chain = s.chain or "forward"
        local week = s.week or "0"
        local ts = s.timestart or ""
        local te = s.timeend or ""

        local enabled = (enable == "1" or enable == "on" or enable == "true")
        local mac = znc_norm_mac(target)
        local is_mac = (mac ~= "")

        -- 时间判定（星期 -> 时段）
        local time_state, time_text
        if not enabled then
            time_state = "disabled"
            time_text = "规则未启用"
        elseif not znc_week_match(week, cur_wd) then
            time_state = "week_mismatch"
            time_text = "星期不匹配（当前星期" .. tostring(cur_wd) .. "，配置" .. week .. "）"
        else
            local in_time
            in_time, time_text = znc_time_match(ts, te, cur_min)
            if in_time then time_state = "in_time" else time_state = "out_of_time" end
        end

        -- nft 上是否真的有这条规则
        local nft_present = false
        local handle = ""
        local packets = 0
        local bytes = 0
        local comment = ""
        local note = ""

        if is_mac then
            comment = "znc-r" .. idx .. "-fwd"
            local r = nft_rules[comment]
            if not r then
                comment = "znc-r" .. idx .. "-in"
                r = nft_rules[comment]
            end
            if r then
                nft_present = true
                handle = r.handle or ""
                packets = r.packets or 0
                bytes = r.bytes or 0
            else
                comment = "znc-r" .. idx .. "-fwd"
                if mac_fwd[mac:lower()] then
                    note = "独立规则未找到，但 MAC 已在共享集合 mac_forward（保底规则生效）"
                end
            end
        else
            local key = tostring(target):gsub("%s+", "")
            if znc_is_ipv4(key) then
                if ip_fwd[key] then
                    nft_present = true
                    note = "已写入 ip_forward 集合（IP 规则按集合生效，计数按集合聚合）"
                end
            elseif znc_is_ipv6(key) then
                if ip6_fwd[key:lower()] then
                    nft_present = true
                    note = "已写入 ip6_forward 集合（IP 规则按集合生效，计数按集合聚合）"
                end
            end
        end

        -- 最终状态描述
        local status
        if not enabled then
            status = "规则未启用"
        elseif time_state == "week_mismatch" or time_state == "out_of_time" then
            if nft_present then
                status = "当前不在生效时段，但 nft 上仍残留规则（建议重启服务清理）"
            else
                status = "不在生效时段，规则未下发（符合预期）"
            end
        elseif nft_present and packets == 0 then
            status = "规则已下发但无流量命中"
        elseif nft_present then
            status = "规则已下发并已命中流量"
        else
            status = "规则未下发（nft 上找不到该规则）"
        end

        table.insert(result, {
            id = idx,
            name = name,
            target = target,
            mac = mac,
            is_mac = is_mac,
            enable = enabled,
            chain = chain,
            week = week,
            timestart = ts,
            timeend = te,
            time_state = time_state,
            time_text = time_text,
            nft_present = nft_present,
            nft_handle = handle,
            nft_comment = comment,
            packets = packets,
            bytes = bytes,
            status = status,
            note = note
        })
    end)

    http.prepare_content("application/json")
    http.header("Cache-Control", "no-cache, no-store, must-revalidate")
    http.header("Pragma", "no-cache")
    http.header("Expires", "0")
    http.write_json(result)
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
    -- source=sched 时改读定时任务日志
    local source = http.formvalue("source") or ""
    if source == "sched" then
        logfile = "/etc/taskplan/znc-sched.log"
    end
    
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
