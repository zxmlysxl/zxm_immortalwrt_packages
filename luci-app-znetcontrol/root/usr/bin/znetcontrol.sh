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
