#!/bin/sh
# 佐罗上网管控 - 支持IP/MAC双模式
# 功能：基于MAC地址或IP地址的网络访问时间管控

NFT_TABLE="inet znetcontrol"
LOG_FILE="/var/log/znetcontrol.log"
PID_FILE="/var/run/znetcontrol.pid"
CONFIG_FILE="/etc/config/znetcontrol"

# 获取版本号：只从版本文件读取
get_version() {
    local version="unknown"  # 默认版本
    
    # 只从版本文件读取（优先级最高）
    if [ -f "/etc/znetcontrol.version" ]; then
        local ver_line=$(grep "^package_version=" /etc/znetcontrol.version 2>/dev/null)
        if [ -n "$ver_line" ]; then
            version="${ver_line#package_version=}"
        fi
    fi
    
    echo "$version"
}

# 移除日志中的版本号
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # 移除版本号：删除 [$(get_version)] 这部分
    echo "$timestamp - $*" >> "$LOG_FILE"
    # logger日志也移除版本号后缀
    logger -t "znetcontrol" "$*"
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
    
    # 添加规则 - MAC地址匹配
    nft add rule $NFT_TABLE forward ether saddr @blocked_mac drop 2>/dev/null || log "添加forward MAC规则失败"
    nft add rule $NFT_TABLE forward ip saddr @blocked_ip drop 2>/dev/null || log "添加forward IP规则失败"
    nft add rule $NFT_TABLE input ether saddr @blocked_mac drop 2>/dev/null || log "添加input MAC规则失败"
    nft add rule $NFT_TABLE input ip saddr @blocked_ip drop 2>/dev/null || log "添加input IP规则失败"
    
    log "防火墙规则设置完成"
    return 0
}

# 检查规则是否在当前时间生效
check_rule_time() {
    local start_time="$1"
    local end_time="$2"
    local days="$3"
    
    # 如果时间都为空，则规则始终生效
    if [ -z "$start_time" ] || [ -z "$end_time" ]; then
        return 0
    fi
    
    # 检查星期
    if [ -n "$days" ] && [ "$days" != "" ]; then
        if ! check_rule_days "$days"; then
            return 1
        fi
    fi
    
    # 获取当前时间
    local current_hour=$(date +%H)
    local current_minute=$(date +%M)
    
    # 移除前导零
    current_hour=${current_hour#0}
    current_minute=${current_minute#0}
    
    local current_total=$((current_hour * 60 + current_minute))
    
    # 解析开始时间
    local start_hour=$(echo "$start_time" | cut -d: -f1)
    local start_minute=$(echo "$start_time" | cut -d: -f2)
    
    # 移除前导零
    start_hour=${start_hour#0}
    start_minute=${start_minute#0}
    
    local start_total=$((start_hour * 60 + start_minute))
    
    # 解析结束时间
    local end_hour=$(echo "$end_time" | cut -d: -f1)
    local end_minute=$(echo "$end_time" | cut -d: -f2)
    
    # 移除前导零
    end_hour=${end_hour#0}
    end_minute=${end_minute#0}
    
    local end_total=$((end_hour * 60 + end_minute))
    
    # 检查是否在时间范围内
    if [ "$start_total" -lt "$end_total" ]; then
        # 正常时间段
        if [ "$current_total" -ge "$start_total" ] && [ "$current_total" -lt "$end_total" ]; then
            return 0
        fi
    else
        # 跨天时间段
        if [ "$current_total" -ge "$start_total" ] || [ "$current_total" -lt "$end_total" ]; then
            return 0
        fi
    fi
    
    return 1
}

# 检查规则是否在生效星期
check_rule_days() {
    local days="$1"
    
    # 如果星期为空，则始终生效
    if [ -z "$days" ] || [ "$days" = "" ]; then
        return 0
    fi
    
    # 获取当前星期（1=周一，7=周日）
    local current_day=$(date +%u)
    
    # 移除空格
    days=$(echo "$days" | tr -d ' ')
    
    # 检查逗号分隔的列表
    if echo "$days" | grep -q ","; then
        local IFS=','
        for day in $days; do
            if [ "$day" = "$current_day" ]; then
                return 0
            fi
        done
    # 检查范围格式
    elif echo "$days" | grep -q "-"; then
        local start_day=$(echo "$days" | cut -d- -f1)
        local end_day=$(echo "$days" | cut -d- -f2)
        if [ "$current_day" -ge "$start_day" ] && [ "$current_day" -le "$end_day" ]; then
            return 0
        fi
    # 单个数字
    else
        if [ "$days" = "$current_day" ]; then
            return 0
        fi
    fi
    
    return 1
}

# 判断目标类型：IP地址或MAC地址
get_target_type() {
    local target="$1"
    
    # 检查是否为IP地址格式
    if echo "$target" | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        echo "ip"
    # 检查是否为MAC地址格式
    elif echo "$target" | grep -q -E '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'; then
        echo "mac"
    else
        echo "unknown"
    fi
}

# 从配置文件加载规则（支持IP/MAC）
load_rules() {
    local reload_time=$(date +"%Y-%m-%d %H:%M:%S")
    local version=$(get_version)
    
    log "====== 规则检查 [$reload_time] [v$version] ======"
    log "从配置文件加载规则"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        log "配置文件不存在: $CONFIG_FILE"
        return 1
    fi
    
    # 检查nftables表是否存在，如果不存在则创建
    if ! nft list table $NFT_TABLE >/dev/null 2>&1; then
        log "nftables表不存在，正在创建..."
        setup_firewall
    fi
    
    # 清空现有集合
    nft flush set $NFT_TABLE blocked_mac 2>/dev/null || log "清空MAC集合失败"
    nft flush set $NFT_TABLE blocked_ip 2>/dev/null || log "清空IP集合失败"
    
    local rule_count=0
    local enabled_count=0
    local active_count=0
    
    # 状态变量
    local in_rule=0
    local current_target=""
    local current_enabled=""
    local current_name=""
    local current_start=""
    local current_end=""
    local current_days=""
    
    # 逐行读取配置文件
    while IFS= read -r line || [ -n "$line" ]; do
        # 移除注释
        line="${line%%#*}"
        # 移除前后空白
        line=$(echo "$line" | xargs)
        
        if [ -z "$line" ]; then
            continue
        fi
        
        # 检测规则开始
        if [[ "$line" == config\ rule* ]]; then
            # 处理前一条规则
            if [ $in_rule -eq 1 ] && [ -n "$current_target" ]; then
                rule_count=$((rule_count + 1))
                
                # 判断目标类型
                target_type=$(get_target_type "$current_target")
                
                log "解析规则 $rule_count: name='$current_name', target='$current_target' ($target_type), enabled='$current_enabled'"
                
                if [ "$current_enabled" = "1" ]; then
                    enabled_count=$((enabled_count + 1))
                    
                    # 检查时间条件
                    local should_block=0
                    if [ -n "$current_start" ] && [ -n "$current_end" ]; then
                        if check_rule_time "$current_start" "$current_end" "$current_days"; then
                            should_block=1
                        fi
                    else
                        # 没有时间限制，始终生效
                        should_block=1
                    fi
                    
                    if [ $should_block -eq 1 ]; then
                        case "$target_type" in
                            "mac")
                                # 添加到MAC地址集合
                                mac_lower=$(echo "$current_target" | tr '[:upper:]' '[:lower:]')
                                nft add element $NFT_TABLE blocked_mac { "$mac_lower" } 2>/dev/null
                                if [ $? -eq 0 ]; then
                                    active_count=$((active_count + 1))
                                    log "✅ 成功添加MAC到阻止列表: $mac_lower"
                                else
                                    log "⚠ 添加MAC失败或已存在: $mac_lower"
                                fi
                                ;;
                            "ip")
                                # 添加到IP地址集合
                                nft add element $NFT_TABLE blocked_ip { "$current_target" } 2>/dev/null
                                if [ $? -eq 0 ]; then
                                    active_count=$((active_count + 1))
                                    log "✅ 成功添加IP到阻止列表: $current_target"
                                else
                                    log "⚠ 添加IP失败或已存在: $current_target"
                                fi
                                ;;
                            *)
                                log "❌ 未知的目标类型: $current_target"
                                ;;
                        esac
                    else
                        log "⏰ 规则不在生效时间: $current_name (目标: $current_target)"
                    fi
                else
                    log "🔕 规则已禁用: $current_name (目标: $current_target)"
                fi
            fi
            
            # 开始新规则
            in_rule=1
            current_target=""
            current_enabled=""
            current_name=""
            current_start=""
            current_end=""
            current_days=""
            
        elif [ $in_rule -eq 1 ] && [[ "$line" == option* ]]; then
            # 解析选项
            local opt_name=$(echo "$line" | awk '{print $2}')
            local opt_value=$(echo "$line" | cut -d' ' -f3- | sed "s/^['\"]//;s/['\"]$//")
            
            case "$opt_name" in
                name)
                    current_name="$opt_value"
                    ;;
                target|mac)  # 兼容旧版本的mac选项
                    current_target="$opt_value"
                    ;;
                enabled)
                    current_enabled="$opt_value"
                    ;;
                start_time)
                    current_start="$opt_value"
                    ;;
                end_time)
                    current_end="$opt_value"
                    ;;
                days)
                    current_days="$opt_value"
                    ;;
            esac
        fi
    done < "$CONFIG_FILE"
    
    # 处理最后一条规则
    if [ $in_rule -eq 1 ] && [ -n "$current_target" ]; then
        rule_count=$((rule_count + 1))
        
        # 判断目标类型
        target_type=$(get_target_type "$current_target")
        
        log "解析规则 $rule_count: name='$current_name', target='$current_target' ($target_type), enabled='$current_enabled'"
        
        if [ "$current_enabled" = "1" ]; then
            enabled_count=$((enabled_count + 1))
            
            # 检查时间条件
            local should_block=0
            if [ -n "$current_start" ] && [ -n "$current_end" ]; then
                if check_rule_time "$current_start" "$current_end" "$current_days"; then
                    should_block=1
                fi
            else
                # 没有时间限制，始终生效
                should_block=1
            fi
            
            if [ $should_block -eq 1 ]; then
                case "$target_type" in
                    "mac")
                        # 添加到MAC地址集合
                        mac_lower=$(echo "$current_target" | tr '[:upper:]' '[:lower:]')
                        nft add element $NFT_TABLE blocked_mac { "$mac_lower" } 2>/dev/null
                        if [ $? -eq 0 ]; then
                            active_count=$((active_count + 1))
                            log "✅ 成功添加MAC到阻止列表: $mac_lower"
                        else
                            log "⚠ 添加MAC失败或已存在: $mac_lower"
                        fi
                        ;;
                    "ip")
                        # 添加到IP地址集合
                        nft add element $NFT_TABLE blocked_ip { "$current_target" } 2>/dev/null
                        if [ $? -eq 0 ]; then
                            active_count=$((active_count + 1))
                            log "✅ 成功添加IP到阻止列表: $current_target"
                        else
                            log "⚠ 添加IP失败或已存在: $current_target"
                        fi
                        ;;
                    *)
                        log "❌ 未知的目标类型: $current_target"
                        ;;
                esac
            else
                log "⏰ 规则不在生效时间: $current_name (目标: $current_target)"
            fi
        else
            log "🔕 规则已禁用: $current_name (目标: $current_target)"
        fi
    fi
    
    log "📊 规则加载统计:"
    log "   总规则数: $rule_count"
    log "   已启用规则: $enabled_count"
    log "   当前生效规则: $active_count"
    log "   系统版本: v$version"
    log "规则加载完成: 找到 $rule_count 条规则，$enabled_count 条已启用，$active_count 条当前生效"
    log "============ 本次检查结束 ============"
    return 0
}

# 前台启动
start_foreground() {
    local version=$(get_version)
    log "启动 ZNetControl v$version (前台模式)"
    init_dirs
    setup_firewall
    load_rules
    log "ZNetControl v$version 启动完成"
}

# 守护进程模式 - 增强版（支持自动时间控制）
daemon_start() {
    local version=$(get_version)
    log "ZNetControl v$version 以守护进程模式启动"
    init_dirs
    
    # 检查是否已在运行
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            log "ZNetControl 已经在运行 (PID: $pid)"
            return 0
        fi
        rm -f "$PID_FILE"
    fi
    
    # 设置防火墙
    setup_firewall
    
    # 启动守护进程循环
    (
        local current_pid=$$  # 获取当前进程PID
        echo $current_pid > "$PID_FILE"  # 强制写入PID文件
        log "ZNetControl v$version 守护进程已启动 (PID: $current_pid)"
        log "监控模式：每分钟检查规则时间"
        
        trap "log '收到停止信号'; cleanup; exit 0" INT TERM
        
        # 初始化变量
        local last_minute=""  # 上次检查的分钟
        local last_config_hash=""  # 上次配置文件的哈希值
        
        # 初始加载规则
        log "初始加载规则"
        load_rules
        
        # 主监控循环
        while true; do
            # 获取当前时间
            local current_hour_minute=$(date +"%H%M")
            local current_day=$(date +%u)
            
            # 计算配置文件哈希值
            local current_config_hash=""
            if [ -f "$CONFIG_FILE" ]; then
                current_config_hash=$(md5sum "$CONFIG_FILE" 2>/dev/null | cut -d' ' -f1)
            fi
            
            local need_reload=false
            
            # 检查1：分钟变化（每分钟检查一次）
            if [ "$current_hour_minute" != "$last_minute" ]; then
                # 转换数字星期为中文星期
                case $current_day in
                    1) week_cn="一" ;;
                    2) week_cn="二" ;;
                    3) week_cn="三" ;;
                    4) week_cn="四" ;;
                    5) week_cn="五" ;;
                    6) week_cn="六" ;;
                    7) week_cn="日" ;;
                    *) week_cn="$current_day" ;;
                esac
                log "时间变化：$(date +"%H:%M") 星期$week_cn"
                need_reload=true
                last_minute="$current_hour_minute"
            fi
            
            # 检查2：配置文件变化
            if [ "$current_config_hash" != "$last_config_hash" ]; then
                log "配置文件变化，重新加载规则"
                need_reload=true
                last_config_hash="$current_config_hash"
            fi
            
            # 如果需要重新加载
            if [ "$need_reload" = true ]; then
                load_rules
            fi
            
            # 休眠30秒（足够检测分钟变化）
            sleep 30
        done
    ) &
    
    sleep 2
    # 检查是否成功启动
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            log "ZNetControl v$version 守护进程启动成功 (PID: $pid)"
        else
            log "ZNetControl 进程启动后异常退出"
            rm -f "$PID_FILE"
            return 1
        fi
    else
        log "ZNetControl v$version 守护进程启动失败"
        return 1
    fi
    
    return 0
}

# 清理函数
cleanup() {
    log "清理资源..."
    rm -f "$PID_FILE"
    log "清理完成"
}

# 停止服务
stop_service() {
    local version=$(get_version)
    log "停止 ZNetControl v$version"
    
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ]; then
            kill $pid 2>/dev/null
            sleep 1
            if kill -0 $pid 2>/dev/null; then
                kill -9 $pid 2>/dev/null
                log "强制终止进程: $pid"
            fi
        fi
        rm -f "$PID_FILE"
    fi
    
    # 可选：清理防火墙规则
    nft delete table $NFT_TABLE 2>/dev/null && log "已清理防火墙规则"
    
    log "ZNetControl v$version 已停止"
}

# 重启服务
restart_service() {
    local version=$(get_version)
    log "重启 ZNetControl v$version"
    stop_service
    sleep 2
    daemon_start
}

# 显示状态
show_status() {
    local version=$(get_version)
    echo "=================================="
    echo "  佐罗上网管控 v$version 状态检查"
    echo "=================================="
    
    # 移除运行时间相关逻辑，仅保留状态和PID
    local pid=""
    local is_running=0
    
    # 1. 先从PID文件读取
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE" 2>/dev/null | tr -d ' ')
        # 验证PID是否有效
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            is_running=1
        else
            # PID文件无效，清空
            rm -f "$PID_FILE"
            pid=""
        fi
    fi
    
    # 2. PID文件无效，主动查找进程
    if [ $is_running -eq 0 ]; then
        pid=$(pgrep -f "znetcontrol.sh daemon" | head -1 | tr -d ' ')
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            is_running=1
            # 更新PID文件
            echo "$pid" > "$PID_FILE"
        fi
    fi
    
    # 3. 输出状态
    if [ $is_running -eq 1 ]; then
        echo "状态: 运行中"
        echo "PID: $pid"
        echo "版本: v$version"
    else
        echo "状态: 未运行"
    fi
    
    echo ""
    echo "nftables 状态:"
    if nft list table $NFT_TABLE >/dev/null 2>&1; then
        nft list table $NFT_TABLE
    else
        echo "nftables 表不存在"
    fi
    
    echo ""
    echo "当前生效设备:"
    if nft list table $NFT_TABLE >/dev/null 2>&1; then
        local nft_output=$(nft list table $NFT_TABLE)
        
        # 统计MAC地址
        local mac_count=0
        echo "  MAC地址:"
        for mac in $(echo "$nft_output" | grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | sort -u); do
            echo "    $mac"
            mac_count=$((mac_count + 1))
        done
        
        # 统计IP地址
        local ip_count=0
        echo "  IP地址:"
        for ip in $(echo "$nft_output" | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' | sort -u); do
            # 排除集合名称中的数字
            if ! echo "$ip" | grep -q '^[0-9]*$'; then
                echo "    $ip"
                ip_count=$((ip_count + 1))
            fi
        done
        
        echo ""
        echo "统计:"
        echo "  MAC地址: $mac_count 个"
        echo "  IP地址: $ip_count 个"
        echo "  总计: $((mac_count + ip_count)) 个设备被阻止"
    else
        echo "  nftables未启用或表不存在"
    fi
    
    echo ""
    echo "最后日志:"
    if [ -f "$LOG_FILE" ]; then
        tail -5 "$LOG_FILE"
    else
        echo "日志文件不存在"
    fi
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
        local version=$(get_version)
        log "====== 启动佐罗上网管控 v$version ======"
        log "重新加载规则"
        load_rules
        sleep 1
        log "规则重新加载完成，状态已更新"
        log "============ 本次规则更新完成 ============"
        ;;
    debug)
        local version=$(get_version)
        echo "ZNetControl v$version 调试信息"
        echo "当前时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "当前星期: $(date +%u) ($(date +%A))"
        echo "系统版本: v$version"
        echo ""
        echo "配置内容:"
        cat "$CONFIG_FILE"
        echo ""
        echo "nftables 状态:"
        nft list table $NFT_TABLE 2>/dev/null || echo "nftables未设置"
        echo ""
        echo "当前生效规则:"
        show_status | tail -20
        ;;
    *)
        local version=$(get_version)
        echo "ZNetControl v$version 使用说明"
        echo "用法: $0 {start|daemon|stop|restart|status|reload|debug}"
        echo ""
        echo "命令说明:"
        echo "  start     - 前台启动服务"
        echo "  daemon    - 后台守护进程模式启动"
        echo "  stop      - 停止服务"
        echo "  restart   - 重启服务"
        echo "  status    - 显示服务状态和当前生效规则"
        echo "  reload    - 重新加载规则"
        echo "  debug     - 显示调试信息"
        exit 1
        ;;
esac

exit 0

