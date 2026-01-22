#!/bin/sh
# ZNetControl 监控脚本 - 每分钟检查规则数量

CONFIG_FILE="/etc/config/znetcontrol"
LOG_FILE="/var/log/znetcontrol.log"
PID_FILE="/var/run/znetcontrol.pid"

log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp - [monitor] $*" >> "$LOG_FILE"
}

# 获取启用规则数量
get_enabled_rule_count() {
    local count=0
    
    if [ -f "$CONFIG_FILE" ]; then
        count=$(grep -c "option enabled '1'" "$CONFIG_FILE" 2>/dev/null || echo 0)
        
        if [ "$count" -eq 0 ]; then
            count=$(grep -c "^[[:space:]]*option enabled[[:space:]]*['\"]1['\"]" "$CONFIG_FILE" 2>/dev/null || echo 0)
        fi
    fi
    
    echo "$count"
}

# 检查服务是否运行
is_service_running() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0  # 运行中
        fi
    fi
    
    # 检查进程
    if pgrep -f "znetcontrol.sh daemon" >/dev/null 2>&1; then
        return 0  # 运行中
    fi
    
    return 1  # 未运行
}

# 主监控循环
monitor_loop() {
    log "ZNetControl 监控服务启动"
    
    while true; do
        local enabled_count=$(get_enabled_rule_count)
        
        # 检查服务是否应该运行
        if [ "$enabled_count" -ge 1 ]; then
            # 有启用规则，检查服务是否在运行
            if ! is_service_running; then
                log "发现 $enabled_count 条启用规则，但服务未运行，尝试启动"
                /etc/init.d/znetcontrol start >/dev/null 2>&1
                if [ $? -eq 0 ]; then
                    log "服务启动成功"
                else
                    log "服务启动失败"
                fi
            fi
        else
            # 没有启用规则，检查服务是否在运行
            if is_service_running; then
                log "没有启用规则，但服务正在运行，尝试停止"
                /etc/init.d/znetcontrol stop >/dev/null 2>&1
                if [ $? -eq 0 ]; then
                    log "服务停止成功"
                else
                    log "服务停止失败"
                fi
            fi
        fi
        
        # 等待60秒后再次检查
        sleep 60
    done
}

# 启动监控
case "$1" in
    start)
        echo "Starting ZNetControl monitor..."
        monitor_loop &
        echo $! > /var/run/znetcontrol-monitor.pid
        echo "Monitor started with PID: $!"
        ;;
    stop)
        echo "Stopping ZNetControl monitor..."
        if [ -f /var/run/znetcontrol-monitor.pid ]; then
            kill $(cat /var/run/znetcontrol-monitor.pid) 2>/dev/null
            rm -f /var/run/znetcontrol-monitor.pid
            echo "Monitor stopped"
        fi
        ;;
    status)
        if [ -f /var/run/znetcontrol-monitor.pid ]; then
            local pid=$(cat /var/run/znetcontrol-monitor.pid)
            if kill -0 "$pid" 2>/dev/null; then
                echo "Monitor is running (PID: $pid)"
                exit 0
            else
                echo "Monitor pid file exists but process is not running"
                exit 1
            fi
        else
            echo "Monitor is not running"
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 {start|stop|status}"
        exit 1
        ;;
esac

exit 0
