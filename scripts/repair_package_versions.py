#!/usr/bin/env python3
"""
同步后修复失效的包版本。

背景
----
本 feed 镜像多个上游仓库(含 xiaorouji/openwrt-passwall-packages)。上游
偶尔会把版本锁到"tag 存在、但 release 资产为空"的版本, 例如:

    naiveproxy v154.0.8037.49-4   -> assets: 0    (下载 404)
    xray-core  v26.10.17           -> tag 不存在

这类包一旦进入固件编译, make 会在下载阶段 404 直接失败, 整轮固件报废
(单次 3~4 小时)。已发生过多次。

本脚本在 rsync 同步之后扫描所有包, 对确定失效的包自动:
  1. 找到上游最新的、资产齐全的 release
  2. 反解出对应的 PKG_VERSION / PKG_RELEASE
  3. 重算该包各架构的 PKG_HASH
并改写 Makefile。

判据只用上游权威信息, 不自己拼下载地址
----------------------------------
"失效"的定义: 当前 tag 对应的 release 不存在, 或存在但资产数为 0。
不自己拼 URL 去探测 —— 包名里常带架构变量, 拼错会误判成失效,
那样会把能用的包改坏, 比不改更糟。

保守原则
--------
只修确定失效(404)的包; 403 / 超时 / 其它一律不动。
修复时若无法确认新版本资产名, 一律跳过。

用法
----
    python3 scripts/repair_package_versions.py [repo_root]
"""

import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor

VAR_RE = re.compile(r"\$[({]([A-Za-z0-9_]+)[)}]")
DEF_RE = re.compile(r"^\s*([A-Za-z0-9_]+)\s*:?=\s*(.*?)\s*$")
# 原始值(未展开)上的结构匹配, 保留版本模板
GH_REL_RE = re.compile(
    r"^https://github\.com/([^/]+)/([^/]+)/releases/download/(.+?)/?$")
GH_TAR_RE = re.compile(
    r"^https://codeload\.github\.com/([^/]+)/([^/]+)/tar\.gz/(.+?)\??$")
HASH_BRANCH_RE = re.compile(
    r"(?:ifeq|else ifeq)\s*\(\$\(ARCH_PREBUILT\),([^)]+)\)\s*\n(\s*PKG_HASH\s*:?=)[ \t]*([0-9a-fA-F]{64})")

TIMEOUT = 90
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120"
API = "https://api.github.com"
TOKEN = os.environ.get("GITHUB_TOKEN", "").strip()


def parse_defs(text):
    defs = {}
    for line in text.split("\n"):
        m = DEF_RE.match(line)
        if not m:
            continue
        name, val = m.group(1), m.group(2)
        if name in defs:
            continue
        if val.startswith("(") or val.startswith("$") or val.startswith("+="):
            continue
        defs[name] = val.strip().strip('"').strip("'")
    return defs


def expand(value, defs, depth=0):
    if not value or depth > 6:
        return value

    def repl(m):
        name = m.group(1)
        if name in defs:
            return expand(defs[name], defs, depth + 1)
        return m.group(0)

    return VAR_RE.sub(repl, value)


def template_to_regex(tpl):
    parts = []
    pos = 0
    for m in VAR_RE.finditer(tpl):
        parts.append(re.escape(tpl[pos:m.start()]))
        name = m.group(1)
        if name == "PKG_VERSION":
            parts.append("(?P<VER>.+?)")
        elif name == "PKG_RELEASE":
            parts.append("(?P<REL>.+?)")
        else:
            parts.append(re.escape(m.group(0)))
        pos = m.end()
    parts.append(re.escape(tpl[pos:]))
    return re.compile("^" + "".join(parts) + "$")


def solve_version(tpl, tag):
    try:
        rx = template_to_regex(tpl)
    except re.error:
        return None
    m = rx.match(tag)
    if not m:
        return None
    g = m.groupdict()
    return g.get("VER"), g.get("REL")


def gh_api(path):
    headers = {"User-Agent": UA, "Accept": "application/vnd.github+json"}
    if TOKEN:
        headers["Authorization"] = "Bearer " + TOKEN
    req = urllib.request.Request(API + path, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return {"__http__": e.code}
    except Exception:
        return None


def get_release(owner, repo, tag):
    data = gh_api("/repos/%s/%s/releases/tags/%s" % (owner, repo, tag))
    if isinstance(data, dict) and "__http__" in data:
        return None if data["__http__"] == 404 else {"assets": []}
    return data if isinstance(data, dict) else None


def list_releases(owner, repo, limit=20):
    data = gh_api("/repos/%s/%s/releases?per_page=%d" % (owner, repo, limit))
    if not isinstance(data, list):
        return []
    out = []
    for r in data:
        tag = r.get("tag_name") or ""
        assets = [a.get("name") or "" for a in (r.get("assets") or [])]
        out.append((tag, assets))
    return out


def http_code(url):
    cmd = ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
           "-L", "--max-time", str(TIMEOUT), "-A", UA, "-I", url]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=TIMEOUT + 15)
        c = r.stdout.strip()
        return int(c) if c.isdigit() else None
    except Exception:
        return None


def download_sha256(url):
    try:
        r = subprocess.run(
            ["curl", "-sL", "--max-time", str(TIMEOUT), "-A", UA, "-o", "-", url],
            capture_output=True, timeout=TIMEOUT + 20)
        if r.returncode != 0 or not r.stdout:
            return None
        return hashlib.sha256(r.stdout).hexdigest()
    except Exception:
        return None


def analyze(makefile):
    try:
        text = open(makefile, encoding="utf-8", errors="ignore").read()
    except Exception:
        return None
    if "PKG_SOURCE_URL" not in text:
        return None
    defs = parse_defs(text)
    raw = defs.get("PKG_SOURCE_URL", "")
    if not raw.startswith("http"):
        return None
    m = GH_REL_RE.match(raw)
    if m:
        return ("asset", m.group(1), m.group(2), m.group(3), defs, text)
    m = GH_TAR_RE.match(raw)
    if m:
        return ("tar", m.group(1), m.group(2), m.group(3), defs, text)
    return None


def asset_name(defs, over, arch):
    d = dict(defs)
    d.update(over)
    d["ARCH_PREBUILT"] = arch
    return expand(defs.get("PKG_SOURCE", ""), d)


def repair(makefile, info):
    kind, owner, repo, tpl, defs, text = info
    cur_ver = defs.get("PKG_VERSION", "")
    cur_rel = defs.get("PKG_RELEASE", "")
    cur_tag = expand(tpl, dict(defs, PKG_VERSION=cur_ver, PKG_RELEASE=cur_rel))
    if VAR_RE.search(cur_tag):
        return None

    if kind == "tar":
        # codeload 源码包: 源码来自 tarball 而非 release 资产,
        # release 资产数与它毫无关系, 必须直接探测 tarball 可达性。
        probe = "https://codeload.github.com/%s/%s/tar.gz/%s" % (owner, repo, cur_tag)
        code = http_code(probe)
        if code != 404:
            return None      # tarball 可达, 认为是好的, 不动
        why = "源码 tarball 不可达(HTTP %s)" % code
    else:
        rel = get_release(owner, repo, cur_tag)
        if rel is None:
            why = "release 不存在"
        elif not (rel.get("assets") or []):
            why = "release 资产数为 0"
        else:
            return None      # 有资产, 认为正常, 不动
    print("  [失效] %s @ %s (%s)" % (os.path.basename(os.path.dirname(makefile)), cur_tag, why))

    for tag, assets in list_releases(owner, repo):
        solved = solve_version(tpl, tag)
        if not solved:
            continue
        new_ver, new_rel = solved
        if new_rel is None:
            new_rel = cur_rel
        if new_ver == cur_ver and new_rel == cur_rel:
            continue
        over = {"PKG_VERSION": new_ver, "PKG_RELEASE": new_rel}
        ndefs = dict(defs, **over)
        branches = HASH_BRANCH_RE.findall(text)
        if kind == "asset":
            want = None
            for arch, _p, _h in branches:
                nm = asset_name(defs, over, arch)
                if nm and nm in assets:
                    want = nm
                    break
            if not want:
                continue
            base = "https://github.com/%s/%s/releases/download/%s/" % (owner, repo, tag)
        else:
            url = "https://codeload.github.com/%s/%s/tar.gz/%s" % (owner, repo, tag)
            h = download_sha256(url)
            if not h:
                continue
            base = url
        print("    改用 %s (PKG_VERSION=%s PKG_RELEASE=%s)" % (tag, new_ver, new_rel))
        out = text
        out = re.sub(r"^(PKG_VERSION\s*:?=).*$", lambda m: m.group(1) + new_ver,
                     out, count=1, flags=re.M)
        if new_rel is not None:
            out = re.sub(r"^(PKG_RELEASE\s*:?=).*$", lambda m: m.group(1) + new_rel,
                         out, count=1, flags=re.M)
        if kind == "tar":
            # 源码包的 PKG_HASH 就是 tarball 的哈希, 只有一处(不分架构)
            th = download_sha256(base)
            if th:
                out = re.sub(r"^(PKG_HASH\s*:?=)[ \t]*[0-9a-fA-F]{64}",
                             lambda m: m.group(1) + th, out, count=1, flags=re.M)
        for arch, prefix, _old in HASH_BRANCH_RE.findall(out):
            if kind != "asset":
                continue
            nm = asset_name(defs, over, arch)
            if not nm:
                continue
            h = download_sha256(base + nm)
            if not h:
                print("      架构 %s 资产取不到, 保留原 hash" % arch)
                continue
            pat = re.compile(
                r"(\(\$\(ARCH_PREBUILT\)," + re.escape(arch) +
                r"\)\s*\n\s*PKG_HASH\s*:?=[ \t]*)[0-9a-fA-F]{64}")
            out = pat.sub(lambda m: m.group(1) + h, out)
        open(makefile, "w", encoding="utf-8").write(out)
        return tag
    print("    上游没有可用版本, 保持原样")
    return None


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    targets = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames
                       if d not in (".git", ".github", "scripts", "node_modules")]
        if "Makefile" not in filenames:
            continue
        mf = os.path.join(dirpath, "Makefile")
        info = analyze(mf)
        if info:
            targets.append((mf, info))
    print("=== 检查 %d 个带 GitHub 源码的包 ===" % len(targets))
    if not targets:
        print("  无需检查")
        return 0
    fixed = []
    for mf, info in targets:
        try:
            r = repair(mf, info)
        except Exception as e:
            print("  跳过 %s: %s" % (mf, e))
            continue
        if r:
            fixed.append((mf, r))
    print()
    if fixed:
        print("=== 已修复 %d 个包 ===" % len(fixed))
        for mf, tag in fixed:
            print("  %s -> %s" % (mf, tag))
    else:
        print("=== 所有包源码均可达, 无需修复 ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
