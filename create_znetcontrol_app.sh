#!/bin/bash
# create_znetcontrol_app.sh

# 创建主目录结构
echo "创建目录结构..."
mkdir -p luci-app-znetcontrol/{files,luasrc/{controller,model/cbi/znetcontrol,view/znetcontrol},root/{etc/{config,init.d,uci-defaults},usr/{bin,share/{luci/{applications.d,menu.d},rpcd/acl.d}}}}

# 创建 Makefile
echo "创建 Makefile..."
cat > luci-app-znetcontrol/Makefile << 'EOF'
include $(TOPDIR)/rules.mk

LUCI_TITLE:=佐罗上网管控
LUCI_DESCRIPTION:=基于MAC地址的网络访问时间管控系统
LUCI_DEPENDS:=+luci-base +luci-compat
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-znetcontrol
PKG_VERSION:=1.0.4
PKG_RELEASE:=20260115
PKG_MAINTAINER:=zuoxm <zxmlysxl@gmail.com>

include $(TOPDIR)/feeds/luci/luci.mk

# 必须定义安装规则！
define Package/luci-app-znetcontrol/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/znetcontrol.lua $(1)/usr/lib/lua/luci/controller/
	
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi/znetcontrol
	$(INSTALL_DATA) ./luasrc/model/cbi/znetcontrol/rules.lua $(1)/usr/lib/lua/luci/model/cbi/znetcontrol/
	
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/znetcontrol
	$(INSTALL_DATA) ./luasrc/view/znetcontrol/*.htm $(1)/usr/lib/lua/luci/view/znetcontrol/
	
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-znetcontrol.json $(1)/usr/share/luci/menu.d/
	
	$(INSTALL_DIR) $(1)/usr/share/luci/applications.d
	$(INSTALL_DATA) ./root/usr/share/luci/applications.d/luci-app-znetcontrol.json $(1)/usr/share/luci/applications.d/
	
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-znetcontrol.json $(1)/usr/share/rpcd/acl.d/
	
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/znetcontrol.sh $(1)/usr/bin/znetcontrol.sh
	
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/znetcontrol $(1)/etc/config/znetcontrol
	
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/znetcontrol $(1)/etc/init.d/znetcontrol
	
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/luci-znetcontrol $(1)/etc/uci-defaults/luci-znetcontrol
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
EOF

# 创建主控制脚本
echo "创建主控制脚本..."
cat > luci-app-znetcontrol/files/znetcontrol.sh << 'EOF'
#!/bin/sh
# 佐罗上网管控 - 完整修复版
# 功能：基于MAC地址的网络访问时间管控

NFT_TABLE="inet znetcontrol"
LOG_FILE="/var/log/znetcontrol.log"
PID_FILE="/var/run/znetcontrol.pid"
CONFIG_FILE="/etc/config/znetcontrol"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOG_FILE"
    logger -t znetcontrol "$*"
}

# 确保目录存在
init_dirs() {
    mkdir -p /var/log /var/run 2>/dev/null
    touch "$LOG_FILE" 2>/dev/null
    log "初始化目录完成"
}

# 设置nftables防火墙
setup_firewall() {
    log "设置防火墙规则"
    
    # 清理旧规则
    nft delete table $NFT_TABLE 2>/dev/null
    
    # 创建新表
    nft add table $NFT_TABLE 2>/dev/null || {
        log "创建nftables表失败"
        return 1
    }
    
    # 创建MAC地址集合
    nft add set $NFT_TABLE blocked_mac '{ type ether_addr; flags interval; }' 2>/dev/null || {
        log "创建MAC地址集合失败"
        return 1
    }
    
    # 创建IP地址集合
    nft add set $NFT_TABLE blocked_ip '{ type ipv4_addr; flags interval; }' 2>/dev/null || {
        log "创建IP地址集合失败"
        return 1
    }
    
    # 创建forward链
    nft add chain $NFT_TABLE forward '{ type filter hook forward priority filter - 10; policy accept; }' 2>/dev/null || {
        log "创建forward链失败"
        return 1
    }
    
    # 创建input链
    nft add chain $NFT_TABLE input '{ type filter hook input priority filter - 10; policy accept; }' 2>/dev/null || {
        log "创建input链失败"
        return 1
    }
    
    # 添加规则
    nft add rule $NFT_TABLE forward ether saddr @blocked_mac drop 2>/dev/null || log "添加forward MAC规则失败"
    nft add rule $NFT_TABLE forward ip saddr @blocked_ip drop 2>/dev/null || log "添加forward IP规则失败"
    nft add rule $NFT_TABLE input ether saddr @blocked_mac drop 2>/dev/null || log "添加input MAC规则失败"
    nft add rule $NFT_TABLE input ip saddr @blocked_ip drop 2>/dev/null || log "添加input IP规则失败"
    
    log "防火墙规则设置完成"
    return 0
}

# 从配置文件加载规则
load_rules() {
    log "从配置文件加载规则"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        log "配置文件不存在: $CONFIG_FILE"
        return 1
    fi
    
    # 清空现有集合
    nft flush set $NFT_TABLE blocked_mac 2>/dev/null || log "清空MAC集合失败"
    nft flush set $NFT_TABLE blocked_ip 2>/dev/null || log "清空IP集合失败"
    
    local rule_count=0
    local enabled_count=0
    
    # 解析配置文件
    local in_rule=0
    local current_mac=""
    local current_enabled=""
    
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/#.*//')  # 移除注释
        line=$(echo "$line" | xargs)         # 去除前后空格
        
        if [ -z "$line" ]; then
            continue
        fi
        
        if echo "$line" | grep -q "^config rule "; then
            # 新规则开始
            if [ "$in_rule" -eq 1 ] && [ -n "$current_mac" ] && [ "$current_enabled" = "1" ]; then
                nft add element $NFT_TABLE blocked_mac { "$current_mac" } 2>/dev/null && {
                    log "添加规则: MAC=$current_mac"
                    enabled_count=$((enabled_count + 1))
                } || log "添加MAC到集合失败: $current_mac"
            fi
            
            in_rule=1
            rule_count=$((rule_count + 1))
            current_mac=""
            current_enabled=""
            
        elif [ "$in_rule" -eq 1 ]; then
            if echo "$line" | grep -q "^[[:space:]]*option enabled "; then
                current_enabled=$(echo "$line" | awk '{print $3}' | tr -d "'\"")
            elif echo "$line" | grep -q "^[[:space:]]*option mac "; then
                current_mac=$(echo "$line" | awk '{print $3}' | tr -d "'\"")
            fi
        fi
    done < "$CONFIG_FILE"
    
    # 处理最后一条规则
    if [ "$in_rule" -eq 1 ] && [ -n "$current_mac" ] && [ "$current_enabled" = "1" ]; then
        nft add element $NFT_TABLE blocked_mac { "$current_mac" } 2>/dev/null && {
            log "添加规则: MAC=$current_mac"
            enabled_count=$((enabled_count + 1))
        } || log "添加MAC到集合失败: $current_mac"
    fi
    
    log "规则加载完成: 找到 $rule_count 条规则，$enabled_count 条已启用"
    return 0
}

# 启动服务（后台运行）
daemon_start() {
    log "启动ZNetControl服务"
    
    # 创建PID文件
    echo $$ > "$PID_FILE"
    
    # 初始化
    init_dirs
    
    # 设置防火墙
    if ! setup_firewall; then
        log "防火墙设置失败，服务启动中止"
        rm -f "$PID_FILE"
        return 1
    fi
    
    # 加载规则
    load_rules
    
    log "服务启动完成 (PID: $$)"
    
    # 保持进程运行，定期检查
    while true; do
        # 检查PID文件是否存在
        if [ ! -f "$PID_FILE" ]; then
            log "PID文件被删除，服务退出"
            break
        fi
        
        # 检查配置文件是否有变化
        # 这里可以添加配置文件变化检测逻辑
        
        # 睡眠
        sleep 300
    done
    
    return 0
}

# 停止服务
stop_service() {
    log "停止ZNetControl服务"
    
    # 停止后台进程
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log "停止进程 PID: $pid"
        fi
        rm -f "$PID_FILE"
    fi
    
    # 清理防火墙规则
    nft delete table $NFT_TABLE 2>/dev/null && log "清理防火墙规则完成"
    
    log "服务已停止"
    return 0
}

# 重启服务
restart_service() {
    stop_service
    sleep 2
    daemon_start &
}

# 显示状态
show_status() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "运行中 (PID: $pid)"
            return 0
        else
            echo "已停止 (PID文件存在但进程已终止)"
            rm -f "$PID_FILE" 2>/dev/null
            return 1
        fi
    elif nft list table $NFT_TABLE 2>/dev/null | grep -q "table inet znetcontrol"; then
        echo "运行中 (无PID文件，但规则存在)"
        return 0
    else
        echo "已停止"
        return 1
    fi
}

# 前台启动（用于init.d）
start_foreground() {
    echo "Starting ZNetControl..."
    init_dirs
    setup_firewall
    load_rules
    echo "启动完成"
}

# 主逻辑
case "$1" in
    start)
        start_foreground
        ;;
    daemon)
        daemon_start
        ;;
    stop)
        stop_service
        ;;
    restart)
        restart_service
        ;;
    status)
        show_status
        ;;
    reload)
        log "重新加载规则"
        load_rules
        ;;
    *)
        echo "用法: $0 {start|daemon|stop|restart|status|reload}"
        echo "  start     - 前台启动（用于init.d）"
        echo "  daemon    - 后台守护进程"
        echo "  stop      - 停止服务"
        echo "  restart   - 重启服务"
        echo "  status    - 查看状态"
        echo "  reload    - 重新加载规则"
        exit 1
        ;;
esac

exit 0
EOF

# 创建控制器
echo "创建控制器..."
cat > luci-app-znetcontrol/luasrc/controller/znetcontrol.lua << 'EOF'
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
EOF

# 创建规则管理页面
echo "创建规则管理页面..."
cat > luci-app-znetcontrol/luasrc/model/cbi/znetcontrol/rules.lua << 'EOF'
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
EOF

# 创建设备列表页面
echo "创建设备列表页面..."
cat > luci-app-znetcontrol/luasrc/view/znetcontrol/devices.htm << 'EOF'
<%+header%>
<div class="cbi-map">
    <h2 name="content"><%:在线设备%></h2>
    <div class="cbi-map-descr"><%:当前网络中的在线设备列表%></div>
    
    <div class="table cbi-section-table" id="device-table">
        <div class="tr table-titles">
            <div class="th"><%:IP地址%></div>
            <div class="th"><%:MAC地址%></div>
            <div class="th"><%:主机名%></div>
            <div class="th"><%:操作%></div>
        </div>
        <div id="device-list">
            <div class="tr">
                <div class="td" colspan="4" style="text-align: center; padding: 20px;">
                    <span style="color: #666;"><%:正在加载设备列表...%></span>
                </div>
            </div>
        </div>
    </div>
    
    <div class="cbi-page-actions">
        <button class="cbi-button cbi-button-action" onclick="refreshDevices()">
            <%:刷新列表%>
        </button>
        <button class="cbi-button" onclick="window.close()">
            <%:关闭%>
        </button>
    </div>
</div>

<script>
function refreshDevices() {
    document.getElementById('device-list').innerHTML = '<div class="tr"><div class="td" colspan="4" style="text-align: center; padding: 20px;"><span style="color: #666;"><%:正在加载设备列表...%></span></div></div>';
    
    fetch('<%=luci.dispatcher.build_url("admin/control/znetcontrol/get_devices")%>')
        .then(response => response.json())
        .then(devices => {
            let html = '';
            
            if (devices.length === 0) {
                html = '<div class="tr"><div class="td" colspan="4" style="text-align: center; padding: 20px;"><span style="color: #999;"><%:未找到在线设备%></span></div></div>';
            } else {
                devices.forEach(device => {
                    html += '<div class="tr">';
                    html += '<div class="td">' + (device.ip || '未知') + '</div>';
                    html += '<div class="td"><code>' + device.mac + '</code></div>';
                    html += '<div class="td">' + (device.hostname || '未知') + '</div>';
                    html += '<div class="td">';
                    html += '<button class="cbi-button cbi-button-action" onclick="selectDevice(\'' + device.mac + '\')" style="padding: 4px 10px;">';
                    html += '<%:选择%>';
                    html += '</button>';
                    html += '</div>';
                    html += '</div>';
                });
            }
            
            document.getElementById('device-list').innerHTML = html;
        });
}

function selectDevice(mac) {
    if (window.opener && !window.opener.closed) {
        const inputs = window.opener.document.querySelectorAll('input[name*="mac"]');
        for (let i = 0; i < inputs.length; i++) {
            if (inputs[i].type === 'text') {
                inputs[i].value = mac;
                break;
            }
        }
        window.close();
    } else {
        alert('<%:选择的MAC地址: %>' + mac);
    }
}

window.onload = refreshDevices;
</script>
<%+footer%>
EOF

# 创建概览页面
echo "创建概览页面..."
cat > luci-app-znetcontrol/luasrc/view/znetcontrol/overview.htm << 'EOF'
<%+header%>
<div class="cbi-map">
    <h2 name="content"><%:佐罗上网管控%></h2>
    <div class="cbi-map-descr"><%:基于MAC地址的网络访问时间管控系统%></div>
    
    <fieldset class="cbi-section">
        <legend><%:系统状态%></legend>
        <div class="cbi-value">
            <label class="cbi-label"><%:服务状态%></label>
            <div class="cbi-value-field">
                <span id="service-status" class="label">正在检查...</span>
            </div>
        </div>
        <div class="cbi-value">
            <label class="cbi-label"><%:运行时间%></label>
            <div class="cbi-value-field">
                <code id="uptime">--</code>
            </div>
        </div>
    </fieldset>
    
    <fieldset class="cbi-section">
        <legend><%:统计信息%></legend>
        <div class="cbi-value">
            <label class="cbi-label"><%:总规则数%></label>
            <div class="cbi-value-field">
                <code id="total-rules">0</code>
            </div>
        </div>
        <div class="cbi-value">
            <label class="cbi-label"><%:启用规则数%></label>
            <div class="cbi-value-field">
                <code id="enabled-rules">0</code>
            </div>
        </div>
    </fieldset>
    
    <fieldset class="cbi-section">
        <legend><%:系统操作%></legend>
        <div class="cbi-page-actions">
            <button class="cbi-button cbi-button-apply" onclick="restartService()">
                <%:重启服务%>
            </button>
            <button class="cbi-button cbi-button-action" onclick="refreshStatus()">
                <%:刷新状态%>
            </button>
        </div>
    </fieldset>
</div>

<script>
function refreshStatus() {
    fetch('<%=luci.dispatcher.build_url("admin/control/znetcontrol/get_status")%>')
        .then(response => response.json())
        .then(data => {
            const statusEl = document.getElementById('service-status');
            if (data.running) {
                statusEl.textContent = '<%:运行中%>';
                statusEl.className = 'label success';
            } else {
                statusEl.textContent = '<%:已停止%>';
                statusEl.className = 'label error';
            }
            
            document.getElementById('uptime').textContent = data.uptime || '--';
            document.getElementById('total-rules').textContent = data.total_rules || 0;
            document.getElementById('enabled-rules').textContent = data.enabled_rules || 0;
        });
}

function restartService() {
    if (confirm('<%:确定要重启服务吗？%>')) {
        fetch('<%=luci.dispatcher.build_url("admin/control/znetcontrol/restart")%>', { 
            method: 'POST' 
        })
        .then(response => response.json())
        .then(data => {
            alert(data.message);
            setTimeout(refreshStatus, 2000);
        });
    }
}

window.onload = refreshStatus;
setInterval(refreshStatus, 30000);
</script>

<style>
.label {
    display: inline-block;
    padding: 4px 10px;
    border-radius: 4px;
    font-size: 13px;
    font-weight: bold;
}

.label.success {
    background-color: #d4edda;
    color: #155724;
    border: 1px solid #c3e6cb;
}

.label.error {
    background-color: #f8d7da;
    color: #721c24;
    border: 1px solid #f5c6cb;
}
</style>
<%+footer%>
EOF

# 创建状态页面
echo "创建状态页面..."
cat > luci-app-znetcontrol/luasrc/view/znetcontrol/status.htm << 'EOF'
<%+header%>
<div class="cbi-map">
    <h2 name="content"><%:系统状态%></h2>
    
    <fieldset class="cbi-section">
        <legend><%:服务信息%></legend>
        <div class="cbi-value">
            <label class="cbi-label"><%:服务状态%></label>
            <div class="cbi-value-field">
                <span id="service-status" class="label">检查中...</span>
            </div>
        </div>
        <div class="cbi-value">
            <label class="cbi-label"><%:运行时间%></label>
            <div class="cbi-value-field">
                <code id="uptime">--</code>
            </div>
        </div>
        <div class="cbi-value">
            <label class="cbi-label"><%:防火墙状态%></label>
            <div class="cbi-value-field">
                <code id="firewall-status">检查中...</code>
            </div>
        </div>
    </fieldset>
    
    <fieldset class="cbi-section">
        <legend><%:系统操作%></legend>
        <div class="cbi-page-actions">
            <button class="cbi-button cbi-button-apply" onclick="restartService()">
                <%:重启服务%>
            </button>
            <button class="cbi-button cbi-button-action" onclick="updateStatus()">
                <%:刷新状态%>
            </button>
            <button class="cbi-button cbi-button-reset" onclick="clearLogs()">
                <%:清空日志%>
            </button>
        </div>
    </fieldset>
    
    <fieldset class="cbi-section">
        <legend><%:实时日志%></legend>
        <div class="cbi-value">
            <label class="cbi-label"><%:系统日志%></label>
            <div class="cbi-value-field">
                <div style="margin-bottom: 5px;">
                    <button class="cbi-button cbi-button-action" onclick="refreshLogs()" style="padding: 4px 10px;">
                        <%:刷新日志%>
                    </button>
                </div>
                <pre id="log-content" style="height: 250px; overflow-y: auto; background: #f5f5f5; padding: 10px; border: 1px solid #ddd; border-radius: 3px;"></pre>
            </div>
        </div>
    </fieldset>
</div>

<script>
function updateStatus() {
    // 获取服务状态
    fetch('<%=luci.dispatcher.build_url("admin/control/znetcontrol/get_status")%>')
        .then(response => response.json())
        .then(data => {
            const statusEl = document.getElementById('service-status');
            if (data.running) {
                statusEl.textContent = '<%:运行中%>';
                statusEl.className = 'label success';
            } else {
                statusEl.textContent = '<%:已停止%>';
                statusEl.className = 'label error';
            }
            
            document.getElementById('uptime').textContent = data.uptime || '--';
        });
    
    // 获取防火墙状态
    fetch('<%=luci.dispatcher.build_url("admin/control/znetcontrol/firewall_status")%>')
        .then(response => response.json())
        .then(data => {
            const firewallEl = document.getElementById('firewall-status');
            if (data.exists) {
                firewallEl.textContent = '<%:已加载 (' + (data.blocked_count || 0) + '个规则)%>';
            } else {
                firewallEl.textContent = '<%:未找到%>';
            }
        });
    
    // 获取日志
    refreshLogs();
}

function refreshLogs() {
    fetch('<%=luci.dispatcher.build_url("admin/control/znetcontrol/logs")%>')
        .then(response => response.json())
        .then(logs => {
            const logElement = document.getElementById('log-content');
            if (logs.length === 0) {
                logElement.textContent = '<%:暂无日志%>';
            } else {
                logElement.textContent = logs.join('\n');
                logElement.scrollTop = logElement.scrollHeight;
            }
        });
}

function restartService() {
    if (confirm('<%:确定要重启服务吗？%>')) {
        fetch('<%=luci.dispatcher.build_url("admin/control/znetcontrol/restart")%>', { method: 'POST' })
            .then(response => response.json())
            .then(data => {
                alert(data.message);
                setTimeout(updateStatus, 2000);
            });
    }
}

function clearLogs() {
    if (confirm('<%:确定要清空所有日志吗？%>')) {
        fetch('<%=luci.dispatcher.build_url("admin/control/znetcontrol/clear_logs")%>', { method: 'POST' })
            .then(response => response.json())
            .then(data => {
                alert(data.message);
                refreshLogs();
            });
    }
}

// 页面加载时初始化
window.onload = updateStatus;
// 每30秒自动更新一次
setInterval(updateStatus, 30000);
</script>

<style>
.label {
    display: inline-block;
    padding: 4px 10px;
    border-radius: 4px;
    font-size: 13px;
    font-weight: bold;
}

.label.success {
    background-color: #d4edda;
    color: #155724;
    border: 1px solid #c3e6cb;
}

.label.error {
    background-color: #f8d7da;
    color: #721c24;
    border: 1px solid #f5c6cb;
}
</style>
<%+footer%>
EOF

# 创建配置文件
echo "创建配置文件..."
cat > luci-app-znetcontrol/root/etc/config/znetcontrol << 'EOF'
config global 'settings'
    option enabled '1'
    option scan_interval '60'
    option log_level 'info'

# 示例规则
# config rule 'example_rule'
#     option name '孩子晚间上网限制'
#     option mac 'AA:BB:CC:DD:EE:FF'
#     option enabled '1'
#     option days '1,2,3,4,5'
#     option start_time '22:00'
#     option end_time '06:00'
#     option date_range ''
EOF

# 创建init.d脚本
echo "创建init.d脚本..."
cat > luci-app-znetcontrol/root/etc/init.d/znetcontrol << 'EOF'
#!/bin/sh
# ZNetControl init.d 脚本 - 完整版

START=99
STOP=10
PID_FILE="/var/run/znetcontrol.pid"
DAEMON="/usr/bin/znetcontrol.sh"
NAME="znetcontrol"
DESC="ZNetControl Internet Access Control"

start() {
    echo "Starting $DESC..."
    
    # 检查是否已运行
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "$DESC is already running (PID: $pid)"
            return 0
        fi
        rm -f "$PID_FILE"
    fi
    
    # 启动服务
    if $DAEMON daemon >/dev/null 2>&1; then
        sleep 2
        
        if [ -f "$PID_FILE" ]; then
            local pid=$(cat "$PID_FILE")
            echo "Started $DESC (PID: $pid)"
            return 0
        else
            echo "Failed to start $DESC (no PID file)"
            return 1
        fi
    else
        echo "Failed to start $DESC"
        return 1
    fi
}

stop() {
    echo "Stopping $DESC..."
    
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ]; then
            $DAEMON stop
            echo "Stopped $DESC"
            return 0
        fi
    fi
    
    # 如果没有PID文件，尝试直接停止
    $DAEMON stop
    echo "Stopped $DESC"
    return 0
}

restart() {
    echo "Restarting $DESC..."
    stop
    sleep 3
    start
}

status() {
    $DAEMON status
    return $?
}

reload() {
    echo "Reloading $DESC rules..."
    $DAEMON reload
    return $?
}

case "$1" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart|reload)
        restart
        ;;
    status)
        status
        ;;
    enable)
        ln -sf /etc/init.d/$NAME /etc/rc.d/S99$NAME 2>/dev/null
        ln -sf /etc/init.d/$NAME /etc/rc.d/K10$NAME 2>/dev/null
        echo "Enabled $DESC"
        ;;
    disable)
        rm -f /etc/rc.d/*$NAME* 2>/dev/null
        echo "Disabled $DESC"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|enable|disable}"
        exit 1
        ;;
esac

exit 0
EOF

# 创建uci-defaults脚本（简化版本）
echo "创建uci-defaults脚本..."
cat > luci-app-znetcontrol/root/etc/uci-defaults/luci-znetcontrol << 'EOF'
#!/bin/sh

# 只在真实系统运行
[ -n "$IPKG_INSTROOT" ] && exit 0

# 创建日志目录
mkdir -p /var/log 2>/dev/null
touch /var/log/znetcontrol.log 2>/dev/null

# 确保配置目录存在
mkdir -p /etc/config 2>/dev/null

exit 0
EOF

# 复制主控制脚本到usr/bin
echo "复制主控制脚本到usr/bin..."
cp luci-app-znetcontrol/files/znetcontrol.sh luci-app-znetcontrol/root/usr/bin/znetcontrol.sh

# 创建菜单配置文件
echo "创建菜单配置文件..."
cat > luci-app-znetcontrol/root/usr/share/luci/menu.d/luci-app-znetcontrol.json << 'EOF'
{
    "admin/control": {
        "title": "管控",
        "order": 70,
        "action": {
            "type": "firstchild"
        },
        "depends": {
            "acl": ["luci-app-znetcontrol"]
        }
    },
    "admin/control/znetcontrol": {
        "title": "佐罗上网管控",
        "order": 10,
        "action": {
            "type": "firstchild"
        },
        "depends": {
            "acl": ["luci-app-znetcontrol"],
            "fs": {
                "/usr/lib/lua/luci/controller/znetcontrol.lua": "file"
            }
        }
    }
}
EOF

# 创建应用程序配置文件
echo "创建应用程序配置文件..."
cat > luci-app-znetcontrol/root/usr/share/luci/applications.d/luci-app-znetcontrol.json << 'EOF'
{
    "description": "基于MAC地址的网络访问时间管控系统",
    "name": "znetcontrol",
    "i18n": {
        "chinese": "佐罗上网管控"
    },
    "title": {
        "zh-cn": "佐罗上网管控"
    },
    "maintainer": "zuoxm <zxmlysxl@gmail.com>"
}
EOF

# 创建RPC权限配置文件
echo "创建RPC权限配置文件..."
cat > luci-app-znetcontrol/root/usr/share/rpcd/acl.d/luci-app-znetcontrol.json << 'EOF'
{
    "luci-app-znetcontrol": {
        "description": "Grant access to ZNetControl",
        "read": {
            "ubus": {
                "luci": ["getFeatures"],
                "uci": ["get"],
                "file": {
                    "/etc/config/znetcontrol": ["read"],
                    "/var/log/znetcontrol.log": ["read"],
                    "/tmp/dhcp.leases": ["read"]
                },
                "network.interface": ["dump"],
                "network.device": ["status"],
                "network.wireless": ["status"]
            },
            "uci": ["znetcontrol", "network", "dhcp", "wireless"]
        },
        "write": {
            "ubus": {
                "luci": ["setFeatures"],
                "uci": ["set", "add", "delete", "commit", "revert"],
                "file": {
                    "/etc/config/znetcontrol": ["write"]
                },
                "service": ["list", "get", "set", "add", "delete", "update", "reload", "restart", "start", "stop"],
                "system": ["syslog"]
            },
            "uci": ["znetcontrol"]
        }
    }
}
EOF

# 设置文件权限
echo "设置文件权限..."
chmod +x luci-app-znetcontrol/files/znetcontrol.sh
chmod +x luci-app-znetcontrol/root/etc/init.d/znetcontrol
chmod +x luci-app-znetcontrol/root/etc/uci-defaults/luci-znetcontrol
chmod +x luci-app-znetcontrol/root/usr/bin/znetcontrol.sh

echo "完成！luci-app-znetcontrol 应用已创建在 'luci-app-znetcontrol' 目录中"
echo ""
echo "文件结构如下："
find luci-app-znetcontrol -type f | sort | sed 's/^/  /'
echo ""
echo "总文件数："
find luci-app-znetcontrol -type f | wc -l
echo ""
echo "下一步："
echo "1. 将 'luci-app-znetcontrol' 目录复制到 OpenWrt 的 package 目录"
echo "2. 在 OpenWrt 中运行 'make menuconfig'"
echo "3. 在 LuCI -> Applications 中找到并选择 'luci-app-znetcontrol'"
echo "4. 运行 'make package/luci-app-znetcontrol/compile' 编译"
