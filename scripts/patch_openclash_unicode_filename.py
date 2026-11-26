#!/usr/bin/env python3
"""
OpenClash 补丁：允许配置文件使用中文（UTF-8）文件名。

背景
----
luci-app-openclash 上游对文件名做了 ASCII 白名单校验:

    local function is_safe_filename(filename)
        return filename and filename:match("^[%w%._%-]+$") and not filename:match("^%.")
    end

Lua 的 %w 只覆盖 ASCII 字母数字, 所以 "我的订阅.yaml" 这类中文名在
"运行状态页 -> 添加配置文件"(action_upload_config) 会被判成
"Invalid filename" 而被拒绝; 而同一页面的 "重命名"(rename_file) 与
"新建文件"(create_file) 没有调用这个校验, 于是又能写中文名 ——
同一个页面两套行为, 属于 bug。

上游前端 (config_upload.js) 的白名单其实是
/^[a-zA-Z0-9_\-\s\u4e00-\u9fa5\.]+$/, 明确允许中文, 后端这一侧才是
漏网的那个。

本脚本做什么
------------
1. 把 is_safe_filename 换成 "允许 UTF-8 多字节 + ASCII 白名单" 的版本,
   仍然拒绝路径分隔符 / 路径穿越 / 控制字符。
2. 让 create_file() 与 rename_file() 也走同一套校验, 三条路径行为一致;
   同时限定只能操作 OpenClash 自己的几个目录, 顺带堵掉客户端可控
   file_path / filepath 造成的路径穿越。
3. 维护 Makefile 里的 PKG_RELEASE 标记。Makefile 同样位于被 rsync
   --delete 覆盖的目录内, 不由本脚本维护的话, upstream 同步一次就把
   版本号冲回去了, 包管理器也看不出打过补丁。

幂等
----
带标记注释, 已打过则跳过。上游改版导致匹配不到时, 打印说明并以 0
退出, 绝不阻断 feed 同步。

用法
----
    python3 scripts/patch_openclash_unicode_filename.py [repo_root]
    python3 scripts/patch_openclash_unicode_filename.py --check [repo_root]
"""

import os
import re
import sys

MARKER = "-- openclaw-unicode-filename-patch"

TARGET = os.path.join("luci-app-openclash", "luasrc", "controller", "openclash.lua")

# Makefile 同样位于被 rsync --delete 覆盖的目录内, 版本标记也必须由本脚本
# 维护, 否则 upstream 同步一次就把版本号冲回去了。
MAKEFILE = os.path.join("luci-app-openclash", "Makefile")

# 本地补丁的 PKG_RELEASE。上游 OpenClash 的 Makefile 不定义 PKG_RELEASE,
# 默认是 1; 抬到 2 之后包管理器才能识别出这是打过补丁的版本。
PKG_RELEASE = "2"

MAKEFILE_MARKER = "# openclash-unicode-filename-patch: local patch, unicode config filenames"

# 上游原始 is_safe_filename 定义, 整块删除, 换成提前插入的新实现
ORIGINAL_SAFE_FN_RE = re.compile(
    r"local function is_safe_filename\(filename\).*?\nend\n", re.S)

CREATE_FN_RE = re.compile(r"function create_file\(\).*?\nend\n", re.S)

RENAME_FN_RE = re.compile(r"function rename_file\(\).*?\nend\n", re.S)

HELPER_BLOCK = MARKER + """
-- 允许 UTF-8(中文等)文件名, 但仍拒绝路径分隔符 / 路径穿越 / 控制字符。
-- 上游原实现用 ^[%w%._%-]+$, %w 只含 ASCII, 会把中文名判为非法;
-- 而同页面的 rename_file / create_file 又没有校验, 行为不一致。
local function is_safe_filename(filename)
	if not filename or filename == "" then
		return false
	end
	if filename:match("^%.") or filename:find("..", 1, true) then
		return false
	end
	local allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._- "
	for i = 1, #filename do
		local b = filename:byte(i)
		if b < 0x20 or b == 0x7f then
			return false
		end
		if b == 0x2f or b == 0x5c then
			return false
		end
		if b < 0x80 and not allowed:find(string.char(b), 1, true) then
			return false
		end
	end
	return true
end

-- 只允许操作 OpenClash 自己的目录, 防止客户端参数造成路径穿越。
local function is_allowed_openclash_dir(dirpath)
	if not dirpath or dirpath == "" then
		return false
	end
	local allowed_dirs = {
		"/etc/openclash/config/",
		"/etc/openclash/proxy_provider/",
		"/etc/openclash/rule_provider/",
	}
	for _, d in ipairs(allowed_dirs) do
		if dirpath == d then
			return true
		end
	end
	return false
end

"""

NEW_CREATE_FN = """function create_file()
	local file_name = HTTP.formvalue("filename")
	local file_path = HTTP.formvalue("filepath")
	if not file_name or not is_safe_filename(file_name) then
		HTTP.status(500, "Create File Failed")
		return
	end
	if not is_allowed_openclash_dir(file_path) then
		HTTP.status(500, "Create File Failed")
		return
	end
	local full_path = file_path .. file_name
	fs.writefile(full_path, "")
	if not fs.isfile(full_path) then
		HTTP.status(500, "Create File Failed")
	end
	return
end
"""

NEW_RENAME_FN = """function rename_file()
	local new_file_name = HTTP.formvalue("new_file_name")
	local file_path = HTTP.formvalue("file_path")
	local old_file_name = HTTP.formvalue("file_name")
	if not new_file_name or not is_safe_filename(new_file_name) then
		HTTP.status(500, "Rename File Failed")
		return
	end
	if not old_file_name or not is_safe_filename(old_file_name) then
		HTTP.status(500, "Rename File Failed")
		return
	end
	if not is_allowed_openclash_dir(file_path) then
		HTTP.status(500, "Rename File Failed")
		return
	end
	local old_file_path = file_path .. old_file_name
	local new_file_path = file_path .. new_file_name
	local old_run_file_path = "/etc/openclash/" .. old_file_name
	local new_run_file_path = "/etc/openclash/" .. new_file_name
	if fs.rename(old_file_path, new_file_path) then
		if file_path == "/etc/openclash/config/" then
			if fs.uci_get_config("config", "config_path") == old_file_path then
				uci:set("openclash", "config", "config_path", new_file_path)
			end

			if fs.isfile(old_run_file_path) then
				fs.rename(old_run_file_path, new_run_file_path)
			end

			fs.config_refs(old_file_name, new_file_name)
		end
		HTTP.status(200, "Rename File Successful")
	else
		HTTP.status(500, "Rename File Failed")
	end
	return
end
"""


def patch_text(text):
    """返回 (新文本, 说明列表)。无变更时原样返回。"""
    notes = []

    if MARKER in text:
        return text, ["已打过补丁, 跳过"]

    # 1) 删掉上游原来的 is_safe_filename 定义
    new_text, n = ORIGINAL_SAFE_FN_RE.subn("", text, count=1)
    if n != 1:
        # 上游可能已自行修复: 不动它, 避免覆盖上游的修复。
        return text, ["未匹配到上游原始 is_safe_filename 定义, 跳过(上游可能已自行修复)"]
    text = new_text
    notes.append("移除上游 ASCII 白名单版 is_safe_filename")

    # 2) 在 create_file 之前插入新的 helper
    m = CREATE_FN_RE.search(text)
    if not m:
        return text, notes + ["未找到 create_file, 终止"]
    text = text[:m.start()] + HELPER_BLOCK + text[m.start():]
    notes.append("插入 UTF-8 友好的 is_safe_filename + is_allowed_openclash_dir")

    # 3) 替换 create_file
    text, n = CREATE_FN_RE.subn(lambda _m: NEW_CREATE_FN, text, count=1)
    if n != 1:
        return text, notes + ["create_file 替换失败, 终止"]
    notes.append("create_file 接入统一校验")

    # 4) 替换 rename_file
    text, n = RENAME_FN_RE.subn(lambda _m: NEW_RENAME_FN, text, count=1)
    if n != 1:
        return text, notes + ["rename_file 替换失败, 终止"]
    notes.append("rename_file 接入统一校验并限定目录")

    return text, notes


def patch_makefile(text):
    """在 Makefile 里维护 PKG_RELEASE 标记, 返回 (新文本, 说明列表)。"""
    notes = []

    if MAKEFILE_MARKER in text and ("PKG_RELEASE:=" + PKG_RELEASE) in text:
        return text, ["Makefile 版本标记已是最新"]

    # 去掉上游可能存在的 PKG_RELEASE 定义, 统一由本脚本设置
    text, n = re.subn(r"^PKG_RELEASE\s*:?=.*$", "", text, count=1, flags=re.M)
    if n:
        notes.append("移除上游 PKG_RELEASE 定义")

    lines = ("\n" + MAKEFILE_MARKER + "\nPKG_RELEASE:=" + PKG_RELEASE + "\n")

    m = re.search(r"^PKG_VERSION\s*:?=.*$", text, re.M)
    if not m:
        return text, notes + ["Makefile 中未找到 PKG_VERSION, 不改版本标记"]
    text = text[:m.end()] + lines + text[m.end():]
    notes.append("设置 PKG_RELEASE:=" + PKG_RELEASE)
    return text, notes


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    check_only = "--check" in sys.argv
    repo_root = args[0] if args else "."

    changed = False

    # --- Lua 控制器 ---
    path = os.path.join(repo_root, TARGET)
    if not os.path.isfile(path):
        print("::warning::找不到 %s, 跳过" % path)
    else:
        with open(path, "r", encoding="utf-8") as fh:
            original = fh.read()

        patched, notes = patch_text(original)
        for note in notes:
            print("  - %s" % note)

        if patched != original:
            changed = True
            if check_only:
                print("OpenClash 补丁: 需要应用(未写入) %s" % path)
            else:
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(patched)
                print("OpenClash 补丁: 已写入 %s" % path)

    # --- Makefile 版本标记 ---
    mk_path = os.path.join(repo_root, MAKEFILE)
    if not os.path.isfile(mk_path):
        print("::warning::找不到 %s, 跳过" % mk_path)
    else:
        with open(mk_path, "r", encoding="utf-8") as fh:
            original = fh.read()

        patched, notes = patch_makefile(original)
        for note in notes:
            print("  - %s" % note)

        if patched != original:
            changed = True
            if check_only:
                print("OpenClash 补丁: 需要应用(未写入) %s" % mk_path)
            else:
                with open(mk_path, "w", encoding="utf-8") as fh:
                    fh.write(patched)
                print("OpenClash 补丁: 已写入 %s" % mk_path)

    if not changed:
        print("OpenClash 补丁: 无需变更")
    return 0


if __name__ == "__main__":
    sys.exit(main())
