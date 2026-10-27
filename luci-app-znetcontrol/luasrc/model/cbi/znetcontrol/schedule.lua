local m, s, e, fs

local uci = require("luci.model.uci").cursor()
local sys = require("luci.sys")
local http = require("luci.http")

m = Map("znetcontrol", translate("定时任务"),
    translate("按计划自动执行系统维护任务（重启/关机/重拨/清内存/自定义脚本等）") ..
    translate("<br><b style='color:#6f42c1;'>比传统 taskplan 更可靠：</b>任务持久保存在 /etc/config/znetcontrol，") ..
    translate("实际执行行写入 /etc/crontabs/root 标记块（#znc-sched-begin/end），重启不丢，保存即生效。") ..
    translate("<br><b style='color:#28a745;'>时间从左到右依次是：</b>分 → 时 → 日 → 月 → 周（cron 顺序，支持 * 通配、N 数字、N-M 范围、*/N 步进）。") ..
    translate("<br><b style='color:#dc3545;'>星期 0=每天，1-7 对应周一~周日，支持 1-5、1,3,5、*。</b>") ..
    "<style>:root{--znc-danger-text:#dc3545;--znc-primary-text:#007bff;--znc-success-text:#28a745;--znc-warn-text:#6f42c1;}html[data-zncolor=dark]{--znc-danger-text:#ff8a95;--znc-primary-text:#4dabf7;--znc-success-text:#4fd67a;--znc-warn-text:#ffd75e;}</style>")

-- 确保 settings 段存在
local function ensure_settings()
    local cfg = uci:get("znetcontrol", "settings")
    if not cfg then
        uci:section("znetcontrol", "global", "settings")
        uci:commit("znetcontrol")
    end
end

-- ========== 全局：自定义脚本（供 customscript 任务调用） ==========
s = m:section(TypedSection, "global", "自定义脚本与全局")
s.anonymous = true

e = s:option(TextValue, "customscript", translate("自定义脚本内容"),
    translate("供任务类型“自定义脚本”调用的 sh 脚本，保存后写入 /etc/taskplan/znc-custom-script。"))
e.rows = 6
e.wrap = "off"
e.default = "#!/bin/sh"
e.description = translate("每行一条 shell 命令，支持 $(...) 与管道。脚本在 root 权限下执行，注意不要写破坏性命令。")

-- ========== 定时任务段 ==========
s = m:section(TypedSection, "stime", "定时任务",
    "启用后，到点自动调用 /usr/bin/znc-schedhandler 执行对应动作。")
s.addremove = true
s.anonymous = true
s.template = "cbi/tblsection"

e = s:option(Value, "remarks", translate("备注"),
    "任务标识，显示在日志里，方便排查。默认按序号命名。")
e.rmempty = false
e.default = "task"

e = s:option(Flag, "enable", translate("启用"),
    "勾选后任务才会写入 cron；取消勾选立即失效。")
e.rmempty = false
e.default = 0

e = s:option(ListValue, "stype", translate("任务类型"))
e:value("reboot",       translate("定时重启系统"))
e:value("poweroff",     translate("定时关机"))
e:value("network",      translate("定时重启网络（ifdown/ifup wan）"))
e:value("restartwan",   translate("定时重拨 WAN"))
e:value("closewan",     translate("定时关闭 WAN"))
e:value("clearmem",     translate("定时清理内存缓存"))
e:value("upwifi",       translate("定时开启 WiFi"))
e:value("downwifi",     translate("定时关闭 WiFi"))
e:value("customscript", translate("定时执行自定义脚本"))
e:value("opkgupgrade",  translate("定时升级全部软件包"))
e.default = "network"

-- cron 5 段校验：支持 * / N / N-M / */N / N,S,T / N-M/S，按段范围限制
-- 返回错误信息字符串，nil 表示通过
local function check_cronfield(val, min, max)
    val = (val or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if val == "" then return "空值" end
    if val == "*" then return nil end
    local function check_seg(seg)
        if seg:match("^%d+%-%d+$") then
            local a, b = seg:match("^(%d+)%-(%d+)$")
            a, b = tonumber(a), tonumber(b)
            if not a or not b then return "范围格式错误:"..seg
            elseif a > b then return "范围起大于止:"..seg
            elseif a < min or b > max then return "超出范围("..tostring(min).."-"..tostring(max).."):"..seg end
        elseif seg:match("^%d+$") then
            local n = tonumber(seg)
            if n < min or n > max then return "超出范围("..tostring(min).."-"..tostring(max).."):"..seg end
        elseif seg:match("^%*/%d+$") or seg:match("^%d+%-%d+/%d+$") then
            local step = tonumber(seg:match("%d+$"))
            if not step or step < 1 then return "步进须>=1:"..seg end
        else
            return "无法识别的格式:"..seg
        end
        return nil
    end
    for seg in val:gmatch("[^,]+") do
        local err = check_seg(seg)
        if err then return err end
    end
    return nil
end

return m
