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
    entry({"admin", "control", "znetcontrol", "api", "quick_add"}, call("action_quick_add")).leaf = true
end

-- 快速添加规则函数
function action_quick_add()
    local http = require("luci.http")
    local uci = require("luci.model.uci").cursor()
    local sys = require("luci.sys")
    
    -- 读取POST参数
    http.prepare_content("application/json")
    local data = http.formvalue()
    
    local target = data and data.target
    local target_type = data and data.type  -- "mac" 或 "ip"
    local name = data and data.name
    
    if not target then
        http.write_json({
            success = false,
            message = "目标地址不能为空"
        })
        return
    end
    
    -- 标准化目标地址
    target = target:upper():gsub("%s+", ""):gsub("-", ":")
    
    -- 检查是否已存在相同规则
    local exists = false
    uci:foreach("znetcontrol", "device", function(s)
        if s.target and s.target:upper():gsub("%s+", ""):gsub("-", ":") == target then
            exists = true
        end
    end)
    
    if exists then
        http.write_json({
            success = false,
            message = "该设备已在规则中"
        })
        return
    end
    
    -- 生成规则名称
    if not name or name == "" then
        if target_type == "mac" then
            -- 尝试从DHCP获取主机名
            local dhcp_lease = sys.exec("cat /tmp/dhcp.leases 2>/dev/null | grep -i '" .. target:lower() .. "' | head -1")
            if dhcp_lease and dhcp_lease ~= "" then
                local parts = {}
                for part in dhcp_lease:gmatch("%S+") do
                    table.insert(parts, part)
                end
                if #parts >= 4 and parts[4] ~= "*" then
                    name = parts[4]
                end
            end
            name = name or "MAC设备_" .. target:sub(13)
        else
            name = "IP设备_" .. target
        end
    end
    
    -- 创建新规则
    local section_id = uci:section("znetcontrol", "device", nil, {
        name = name,
        target = target,
        enable = "1",
        week = "0",  -- 默认每天
        chain = "forward",  -- 默认普通控制
        comment = "从在线设备页面快速添加"
    })
    
    uci:commit("znetcontrol")
    
    -- 重新启动服务使规则生效
    sys.call("/etc/init.d/znetcontrol restart >/dev/null 2>&1 &")
    
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
    
    -- 统计配置规则
    uci:foreach("znetcontrol", "device", function(s)
        if s[".type"] == "device" then
            total_count = total_count + 1
            local enabled = (s.enable == "1" or s.enable == "on" or s.enable == "true")
            if enabled then
                enabled_count = enabled_count + 1
            end
        end
    end)
    
    -- 统计生效规则（从IDLIST）
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
    
    -- nftables规则计数
    local nft_count = 0
    if is_running then
        -- 检测网关模式
        local default_gw = sys.exec("ip route show default 2>/dev/null | head -1 | awk '{print $3}'")
        local lan_iface = sys.exec("uci get network.lan.ifname 2>/dev/null || echo br-lan")
        local my_lan_ip = sys.exec("ip -4 addr show dev " .. lan_iface .. " 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -1")
        
        if default_gw and default_gw ~= "" and default_gw ~= my_lan_ip and default_gw ~= "0.0.0.0" then
            -- 旁路由模式，检查inet表
            nft_count = tonumber(sys.exec("nft list table inet znetcontrol 2>/dev/null | grep -c 'drop comment'")) or 0
        else
            -- 主路由模式，检查bridge和ip表
            local bridge_count = tonumber(sys.exec("nft list table bridge znetcontrol 2>/dev/null | grep -c 'drop comment'")) or 0
            local ip_count = tonumber(sys.exec("nft list table ip znetcontrol 2>/dev/null | grep -c 'drop comment'")) or 0
            nft_count = bridge_count + ip_count
        end
    end
    
    local status = {
        running = is_running,
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
        mac_marked_count = 0,  -- 新增：标记的MAC数量
        devices = {},
        tables_found = {}
    }
    
    -- 检查所有可能的表类型
    local tables_to_check = {
        {name = "inet znetcontrol", type = "inet"},
        {name = "ip znetcontrol", type = "ip"},
        {name = "ip6 znetcontrol", type = "ip6"},
        {name = "bridge znetcontrol", type = "bridge"},
        {name = "inet znetcontrol_mark", type = "mark"}  -- 新增：标记表
    }
    
    for _, table_info in ipairs(tables_to_check) do
        local cmd = "nft list table " .. table_info.name .. " 2>/dev/null"
        local output = sys.exec(cmd)
        
        if output and output ~= "" then
            status.table_exists = true
            status.tables_found[table_info.name] = true
            
            -- 分析这个表的规则
            analyze_nft_table(output, table_info.type, status)
        end
    end
    
    http.prepare_content("application/json")
    http.write_json(status)
end

function analyze_nft_table(output, table_type, status)
    -- 统计这个表中的drop规则
    local drop_count = 0
    for _ in output:gmatch("drop comment") do
        drop_count = drop_count + 1
    end
    
    status.blocked_count = status.blocked_count + drop_count
    
    -- 根据表类型分类统计
    if table_type == "bridge" then
        -- bridge表处理MAC地址
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
        -- ip表处理IPv4地址
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
        -- 标记表统计
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
    
    -- 获取所有已配置的设备规则
    local configured_devices = {}
    uci:foreach("znetcontrol", "device", function(s)
        if s.target then
            local target = s.target:upper():gsub("%s+", ""):gsub("-", ":")
            configured_devices[target] = true
        end
    end)
    
    -- 兼容旧版本rule段
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
    
    -- 方法1：使用多个命令组合获取更准确的设备信息
    local arp_cmd = "ip -4 neighbor show 2>/dev/null | grep -v FAILED || arp -n 2>/dev/null"
    local arp_output = sys.exec(arp_cmd)
    
    if arp_output and arp_output ~= "" then
        for line in arp_output:gmatch("[^\r\n]+") do
            local ip, mac = line:match("^(%d+%.%d+%.%d+%.%d+).-([0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F])")
            
            if ip and mac and mac:upper() ~= "00:00:00:00:00:00" then
                mac = mac:upper()
                local hostname = "未知设备"
                
                -- 方法1：尝试从DNS反向解析
                local dns_result = sys.exec("nslookup " .. ip .. " 2>/dev/null | grep 'name =' | head -1")
                if dns_result and dns_result ~= "" then
                    local name = dns_result:match("name =%s*(.+)$")
                    if name then
                        name = name:gsub("%.$", "")  -- 去掉末尾的点
                        if name ~= ip then
                            hostname = name
                        end
                    end
                end
                
                -- 方法2：从DHCP租约文件获取（主要方法）
                if hostname == "未知设备" then
                    -- 读取所有DHCP租约文件
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
                                    -- 租约格式通常是：时间戳 MAC地址 IP地址 主机名 客户端ID
                                    local parts = {}
                                    for part in lease_line:gmatch("%S+") do
                                        table.insert(parts, part)
                                    end
                                    
                                    if #parts >= 4 then
                                        local lease_mac = parts[2]:upper():gsub("-", ":")
                                        local lease_ip = parts[3]
                                        local lease_hostname = parts[4]
                                        
                                        -- 检查MAC或IP匹配
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
                
                -- 方法3：尝试从hosts文件获取
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
                
                -- 方法4：尝试使用netbios或LLMNR
                if hostname == "未知设备" then
                    -- 尝试nmblookup（如果安装了samba）
                    local nmb_result = sys.exec("nmblookup -A " .. ip .. " 2>/dev/null | grep '<00>' | head -1")
                    if nmb_result and nmb_result ~= "" then
                        local nbname = nmb_result:match("^%s*(%S+)%s+")
                        if nbname then
                            hostname = nbname
                        end
                    end
                end
                
                -- 检查是否已在规则中
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
    
    -- 如果没有获取到任何设备，尝试备用方法
    if #devices == 0 then
        -- 备用方法：使用cat /proc/net/arp
        local arp_content = sys.exec("cat /proc/net/arp 2>/dev/null")
        if arp_content and arp_content ~= "" then
            for line in arp_content:gmatch("[^\r\n]+") do
                -- 跳过标题行
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
                            -- 简单地从DHCP获取主机名
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
        
        -- 保存所有配置
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

