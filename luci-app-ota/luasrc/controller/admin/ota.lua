--[[
LuCI - Lua Configuration Interface
Copyright 2021 jjm2473
Copyright 2024-2025 sirpdboy
]]--
require "luci.util"
module("luci.controller.admin.ota", package.seeall)

function index()
    if luci.sys.call("ota >/dev/null 2>&1") ~= 0 then
        return
    end

    entry({"admin", "system", "ota"}, post_on({ apply = "1" }, "action_ota"), _("OTA"), 69)
    entry({"admin", "system", "flash_progress"}, call("flash_progress")).leaf = true
    entry({"admin", "system", "ota", "check"}, post("action_check"))
    entry({"admin", "system", "ota", "download"}, post("action_download"))
    entry({"admin", "system", "ota", "progress"}, call("action_progress"))
    entry({"admin", "system", "ota", "cancel"}, post("action_cancel"))
end

local function ota_exec(cmd)
    local nixio = require "nixio"
    local os = require "os"
    local fs = require "nixio.fs"
    local rshift = nixio.bit.rshift

    local oflags = nixio.open_flags("wronly", "creat")
    local lock, code, msg = nixio.open("/var/lock/ota_api.lock", oflags)
    if not lock then
        return 255, "", "Open stdio lock failed: " .. msg
    end

    -- Acquire lock
    local stat, code, msg = lock:lock("tlock")
    if not stat then
        lock:close()
        return 255, "", "Lock stdio failed: " .. msg
    end

    local r = os.execute(cmd .. " >/var/log/ota.stdout 2>/var/log/ota.stderr")
    local e = fs.readfile("/var/log/ota.stderr")
    local o = fs.readfile("/var/log/ota.stdout")

    fs.unlink("/var/log/ota.stderr")
    fs.unlink("/var/log/ota.stdout")

    lock:lock("ulock")
    lock:close()

    e = e or ""
    if r == 256 and e == "" then
        e = "os.execute failed, is /var/log full or not existed?"
    end
    return rshift(r, 8), o or "", e or ""
end

local function image_supported(image)
    return (os.execute("sysupgrade -T %q >/dev/null" % image) == 0)
end

local function fork_exec(command)
    local pid = nixio.fork()
    if pid > 0 then
        return pid
    elseif pid == 0 then
        nixio.chdir("/")
        local null = nixio.open("/dev/null", "w+")
        if null then
            nixio.dup(null, nixio.stderr)
            nixio.dup(null, nixio.stdout)
            nixio.dup(null, nixio.stdin)
            if null:fileno() > 2 then
                null:close()
            end
        end
        nixio.exec("/bin/sh", "-c", command)
    end
end
function action_ota()
    local image_tmp = "/tmp/firmware.img"
    local http = require "luci.http"
    local nixio = require "nixio"
    if http.formvalue("apply") == "1" then
        if not luci.dispatcher.test_post_security() then
            return
        end

        -- 清空日志文件
        os.execute("echo 'Starting flash firmware' > /tmp/ezotaflash.log")
        os.execute("chmod 644 /tmp/ezotaflash.log")

        -- 初始化脚本
        os.execute("echo '#!/bin/sh' > /tmp/otaflash.sh")
        -- 验证固件文件
	
        os.execute("echo 'echo Verify firmware files >> /tmp/ezotaflash.log && sleep 5' >> /tmp/otaflash.sh  && chmod +x /tmp/otaflash.sh") 
        if not image_supported(image_tmp) then
              luci.template.render("admin_system/ota", {image_invalid = true})
              return
        end
        -- 获取参数
        local keep = (http.formvalue("keep") == "1") and "" or "-n"
        local bopkg = (http.formvalue("bopkg") == "1") and "" or "-k"
        local expsize = tonumber(http.formvalue("expsize")) or 0
	
        local current_ip = luci.http.getenv("SERVER_ADDR") or "192.168.10.1"  -- 默认 fallback
        local fallback_ip = "192.168.10.1"  -- 如果 JSON 解析失败时的备用 IP
	local target_ip = fallback_ip
	if http.formvalue("keep") == "1" and expsize == 0 then
 	   target_ip = current_ip  -- keep=1 时使用当前设备的 IP
	else
 	   local json = require "luci.jsonc"
 	   local file = "/tmp/run/ezota/ezota.json"
 	   local ok, data = pcall(function()
  	      return json.parse(io.readfile(file))
  	   end)
  	   if ok and data and data.x86_64 and #data.x86_64 > 0 and data.x86_64[1].ip then
  	      target_ip = data.x86_64[1].ip
  	   end
	end

        os.execute("echo WEB IP Address:".. target_ip .." >> /tmp/ezotaflash.log")
        -- 准备响应内容
luci.http.prepare_content("text/html; charset=UTF-8")
luci.http.write([[
<!DOCTYPE html>
<html>
<head>
    <title>]] .. luci.i18n.translate("Firmware Upgrade") .. [[</title>
    <meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate">
    <meta http-equiv="Pragma" content="no-cache">
    <meta http-equiv="Expires" content="0">
    <style>
    body { background:#6a7893; color:#fff; font-family:sans-serif; text-align:center; padding-top:50px; }
    .container { background:#272727; max-width:600px; margin:0 auto; padding:30px; border-radius:8px; }
    .spinner { margin:30px auto; width:50px; height:50px; border:5px solid rgba(255,255,255,0.3); 
               border-radius:50%; border-top-color:#fff; animation:spin 1s ease-in-out infinite; }
    .progress-container { width:100%; height:20px; background:#444; border-radius:10px; margin:15px 0; }
    .progress-bar { height:100%; background:#4CAF50; border-radius:10px; transition:width 0.3s; }
    .log-output { max-height:200px; overflow-y:auto; background:#222; padding:10px; border-radius:5px; 
                 margin-top:15px; font-family:monospace; font-size:12px; text-align:left; }
    .status-message { margin:15px 0; font-size:16px; }
    @keyframes spin { to { transform:rotate(360deg); } }
    </style>
</head>
<body>
    <div class="container">
        <h1>]] .. luci.i18n.translate("Firmware Upgrade") .. [[</h1>
        <div class="status-message">]] .. luci.i18n.translate("Preparing flash process") .. [[</div>
        <div class="spinner"></div>
        <div class="progress-container"><div id="progress-bar" class="progress-bar" style="width:0%"></div></div>
        <div id="status-message" class="status-message"></div>
        <pre id="log-output" class="log-output"></pre>
    </div>
    <script>
    const maxChecks = 300; // 5分钟超时(每秒检查一次)
    let checkCount = 0;
    let reconnectAttempts = 0;
    const maxReconnectAttempts = 30;
    const targetIP = "]] .. target_ip .. [[";
    
    function updateProgress() {
        fetch("/cgi-bin/luci/admin/system/flash_progress")
            .then(r => {
                if (!r.ok) throw new Error('Network error');
                return r.json();
            })
            .then(data => {
                checkCount++;
                
                // 更新进度条
                if (data.progress) {
                    document.getElementById("progress-bar").style.width = data.progress + "%";
                }
                
                // 更新状态信息
                if (data.message) {
                    document.getElementById("status-message").innerHTML = data.message;
                }
                
                // 更新日志输出
                if (data.log) {
                    const logOutput = document.getElementById("log-output");
                    logOutput.textContent = data.log;
                    logOutput.scrollTop = logOutput.scrollHeight;
                }
                
                // 处理完成状态
                if (data.status === "complete" || data.status === "rebooting") {
                    document.getElementById("status-message").innerHTML += "<br><br>" + 
                        "]] .. luci.i18n.translate("Device will reboot shortly. Trying to reconnect") .. [[";
                    startReconnect();
                    return;
                }
                
                // 处理失败状态
                if (data.status === "failed" || checkCount >= maxChecks) {
                    if (checkCount >= maxChecks) {
                        document.getElementById("status-message").innerHTML += "<br><br>" + 
                            "]] .. luci.i18n.translate("Operation timed out! Please check device connection manually.") .. [[";
                    }
                    return;
                }
                
                // 继续检查进度
                setTimeout(updateProgress, 1000);
            })
            .catch(e => {
                console.error("Progress check error:", e);
                if (checkCount < maxChecks) {
                    setTimeout(updateProgress, 2000);
                }
            });
    }
    
    function startReconnect() {
        const checkConnection = () => {
            reconnectAttempts++;
            fetch(`http://${targetIP}/cgi-bin/luci`, { 
                mode: 'no-cors',
                cache: 'no-store'
            })
            .then(() => {
                window.location.href = `http://${targetIP}`;
            })
            .catch(e => {
                if (reconnectAttempts < maxReconnectAttempts) {
                    setTimeout(checkConnection, 2000);
                } else {
                    document.getElementById("status-message").innerHTML += "<br><br>" + 
                        "]] .. luci.i18n.translate("Could not reconnect automatically. Please try to access:") .. [[ " + 
                        targetIP + " " + "]] .. luci.i18n.translate("manually.") .. [[";
                }
            });
        };
        
        setTimeout(checkConnection, 5000);
    }
    
    // 初始启动进度检查
    setTimeout(updateProgress, 1500);
    </script>
</body>
</html>
        ]])
        luci.http.close()
            -- 验证固件
		  
        if expsize > 0 then
            local image_extractedpath = luci.sys.exec("head -n 1 /etc/partexppath | awk '{print $1}' 2>/dev/null | tr -d '\n'")
            local image_extracteddev = luci.sys.exec("echo -n /dev/`head -n 1 /etc/partexppath | awk '{print $2}'` | tr -d '\n'")
            local image_extracted = luci.sys.exec("echo -n `head -n 1 /etc/partexppath |awk  '{print $1}'`/image_extracted.img | tr -d '\n'")

            if not image_extractedpath or image_extractedpath == "" or not image_extracteddev or image_extracteddev == "" then
                os.execute("echo 'error: Could not determine expansion path or device' >> /tmp/ezotaflash.log")
                return
            end

            -- 清理旧文件并解压固件
            os.execute("echo 'echo Preparing extracted image  >> /tmp/ezotaflash.log' >> /tmp/otaflash.sh")
	    os.execute(string.format(
                "echo 'gzip -dc %s > %s' >> /tmp/otaflash.sh",
                image_tmp,
                image_extracted
            ))
            if nixio.fs.access(image_extracted) then
	        os.execute("rm -rf " .. image_extracted) 
            end

            -- 处理分区扩展
            os.execute("echo 'echo Additional expansion capacity   >> /tmp/ezotaflash.log' >> /tmp/otaflash.sh")
            local sizes = {0, 1024, 2048, 5120, 10240, 20480}  
	    os.execute("echo 'dd if=/dev/zero bs=1M count=" .. sizes[expsize + 1] .. " >> " .. image_extracted.. " ' >> /tmp/otaflash.sh")
            if os.execute("which sgdisk >/dev/null") ~= 0 then
                 os.execute("opkg update && opkg install sgdisk")
            end
	    
            os.execute("echo 'echo Fix GPT expansion partition   >> /tmp/ezotaflash.log' >> /tmp/otaflash.sh")
	    os.execute("echo '(sgdisk -e " .. image_extracted .. " >/dev/null 2>&1; true)' >> /tmp/otaflash.sh")
            os.execute("echo 'echo Expand partition   >> /tmp/ezotaflash.log' >> /tmp/otaflash.sh")
	    os.execute("echo 'echo -e \"resizepart 2 -1\\nq\" | parted " .. image_extracted .. " >/dev/null 2>&1' >> /tmp/otaflash.sh")
            os.execute("echo 'echo Writing image to flash >> /tmp/ezotaflash.log' >> /tmp/otaflash.sh")
	    os.execute(string.format(
                "echo -e 'sleep 1\n" ..
                "killall dropbear uhttpd nginx\n" ..
                "sleep 1\nsync\n" ..
                "sleep 1 && echo Rebooting system >> /tmp/ezotaflash.log \nsleep 5 \n" ..
                "(dd if=%s of=%s bs=4k conv=fsync >> /tmp/ezotaflash.log && sleep 10 && echo b > /proc/sysrq-trigger ) &\n" ..
                "sleep 5'>> /tmp/otaflash.sh",
                image_extracted,
                image_extracteddev
            ))

        else
            -- 标准sysupgrade模式
	    local slist = {}
	    if keep ~= "" then table.insert(slist, keep) end
	    if bopkg ~= "" then table.insert(slist, bopkg) end
  
            os.execute("echo 'echo Running sysupgrade command >> /tmp/ezotaflash.log && sleep 2' >> /tmp/otaflash.sh") 
	    os.execute(string.format(
                "echo -e 'sleep 1\n" ..
                "killall dropbear uhttpd nginx\n" ..
                "sleep 1\nsync\n" ..
                "sleep 1 && echo Upgrade completed >> /tmp/ezotaflash.log \nsleep 5  \n" ..
                "(/sbin/sysupgrade -v %s %s >> /tmp/ezotaflash.log && sleep 10) &\n" ..

                "sleep 5'>> /tmp/otaflash.sh",
                table.concat(slist, " "),
                image_tmp
            ))
        end

        fork_exec("/bin/sh /tmp/otaflash.sh")
    else
        luci.template.render("admin_system/ota")
    end
end

function flash_progress()
    luci.http.prepare_content("application/json")
    local response = {
        status = "running",
        message = luci.i18n.translate("Starting flash process"),
        progress = 0,
        log = ""
    }
    if nixio.fs.access("/tmp/ezotaflash.log") then
        -- 读取完整日志
        response.log = luci.sys.exec("cat /tmp/ezotaflash.log 2>/dev/null") or ""
        
        -- 更精确的进度检测逻辑
        if response.log:find("Rebooting system") then
            response.status = "rebooting"
            response.message = luci.i18n.translate("Flash complete! Rebooting")
            response.progress = 100
        elseif response.log:find("Upgrade completed") then
            response.status = "complete"
            response.message = luci.i18n.translate("Flash complete!")
            response.progress = 100
        elseif response.log:find("Writing image to flash") then

            response.progress = 50  -- 默认进度
            response.message = luci.i18n.translate("Writing firmware to flash")
            response.status = "flashing"
        elseif response.log:find("Running sysupgrade command") then
            local step = 30
            if response.log:find("Switching to ramdisk") then 
                step = 80
                response.message = luci.i18n.translate("Switching to ramdisk mode")
            elseif response.log:find("Creating ramdisk") then 
                step = 60
                response.message = luci.i18n.translate("Creating ramdisk")
            elseif response.log:find("Saving config files") then 
                step = 50
                response.message = luci.i18n.translate("Saving configuration files")
            end
            response.progress = step
	    response.message = luci.i18n.translate("Running sysupgrade command")
            response.status = "upgrading"
        elseif response.log:find("Starting flash firmware") then
            local step = 5
            if response.log:find("Fix GPT expansion partition") then 
                step = 25
                response.message = luci.i18n.translate("Fix GPT expansion partition")
            elseif response.log:find("Preparing extracted image") then 
                step = 15
                response.message = luci.i18n.translate("Preparing extracted image")
            elseif response.log:find("Verify firmware") then 
                step = 10
                response.message = luci.i18n.translate("Verify firmware files")
            end
            response.progress = step
            response.status = "upgrading"
        elseif response.log:lower():find("error") or response.log:lower():find("fail") then
            response.status = "failed"
            response.message = luci.i18n.translate("Flash failed! Check log for details")
            -- 从日志中提取错误信息
            local err = response.log:match("error: (.+)") or 
                       response.log:match("fail: (.+)") or
                       response.log:match("ERROR: (.+)")
            if err then
                response.message = luci.i18n.translate("Flash failed: ") .. err
            end
        end
        
        -- 如果进度长时间卡住，尝试更新状态
        if response.status == "running" and response.log ~= "" then
            response.progress = 5
            response.message = luci.i18n.translate("Preparing upgrade environment")
        end
    end
    
    luci.http.write_json(response)
end
 
function action_check()
    local r, o, e = ota_exec("ota check")
    local ret = {
        code = 500,
        msg = "Unknown"
    }
    if r == 0 or r == 1 or r == 2 then
        ret.code = r
        ret.msg = o
    else
        ret.code = 500
        ret.msg = e
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json(ret)
end

function action_download()
    local r, o, e = ota_exec("ota download")
    local ret = {
        code = 500,
        msg = "Unknown"
    }
    if r == 0 then
        ret.code = 0
        ret.msg = ""
    else
        ret.code = 500
        ret.msg = e
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json(ret)
end

function action_progress()
    local r, o, e = ota_exec("ota progress")
    local ret = {
        code = 500,
        msg = "Unknown"
    }
    if r == 0 then
        ret.code = 0
        ret.msg = "done"
    elseif r == 1 or r == 2 or r == 254 then
        ret.code = r
        ret.msg = o
    else
        ret.code = 500
        ret.msg = e
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json(ret)
end

function action_cancel()
    local r, o, e = ota_exec("ota cancel")
    local ret = {
        code = 500,
        msg = "Unknown"
    }
    if r == 0 then
        ret.code = 0
        ret.msg = "ok"
    else
        ret.code = 500
        ret.msg = e
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json(ret)
end
