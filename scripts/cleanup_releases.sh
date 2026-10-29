#!/usr/bin/env bash
#
# cleanup_releases.sh —— 清理 GitHub 仓库中超过保留天数的 Release
#
# 用途：包仓库每次构建都会发布一个 Release（含 apk/ipk 附件），
#       长期累积会撑大仓库体积并让 release 列表变得难以翻查。
#       本脚本只保留最近 N 天的 Release，更早的连同其 git tag 一起删除。
#
# 用法：
#   scripts/cleanup_releases.sh --repo owner/name [选项]
#
# 选项：
#   --repo <owner/name>   目标仓库（必填）
#   --days <N>            保留天数，默认 15
#   --keep-latest <N>     额外保留最新的 N 个 Release（不受天数限制），默认 3
#   --keep-tag <pattern>  保留匹配的 tag（可重复，glob 语法）
#   --no-delete-tags      只删 Release，不删对应的 git tag
#   --dry-run             只打印将要删除的内容，不实际删除
#   -h, --help            显示帮助
#
# 退出码：0 成功；1 参数/环境错误；2 部分删除失败
#

set -euo pipefail

REPO=""
DAYS=15
KEEP_LATEST=3
DELETE_TAGS=1
DRY_RUN=0
declare -a KEEP_PATTERNS=()

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
die() { printf '错误: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '3,25p' "$0" | sed 's/^#//; s/^ //'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)           REPO="${2:-}"; shift 2 ;;
        --days)           DAYS="${2:-}"; shift 2 ;;
        --keep-latest)    KEEP_LATEST="${2:-}"; shift 2 ;;
        --keep-tag)       KEEP_PATTERNS+=("${2:-}"); shift 2 ;;
        --no-delete-tags) DELETE_TAGS=0; shift ;;
        --dry-run)        DRY_RUN=1; shift ;;
        -h|--help)        usage ;;
        *)                die "未知参数: $1（用 --help 查看用法）" ;;
    esac
done

[[ -n "$REPO" ]]          || die "缺少 --repo 参数"
[[ "$REPO" == */* ]]      || die "--repo 格式应为 owner/name，当前为: $REPO"
[[ "$DAYS" =~ ^[0-9]+$ ]]         || die "--days 必须是非负整数，当前为: $DAYS"
[[ "$KEEP_LATEST" =~ ^[0-9]+$ ]] || die "--keep-latest 必须是非负整数，当前为: $KEEP_LATEST"

command -v gh >/dev/null 2>&1 || die "找不到 gh 命令"
gh auth status >/dev/null 2>&1 || die "gh 未登录，请先运行: gh auth login"

# ---- 计算截止时间（用算术，不依赖 GNU date -d）----
NOW_EPOCH=$(date -u +%s)
CUTOFF_EPOCH=$(( NOW_EPOCH - DAYS * 86400 ))
CUTOFF_ISO=$(date -u -d "@$CUTOFF_EPOCH" '+%Y-%m-%d %H:%M:%S' 2>/dev/null              || date -u -r "$CUTOFF_EPOCH" '+%Y-%m-%d %H:%M:%S')

log "仓库: $REPO"
log "保留窗口: $DAYS 天（截止 $CUTOFF_ISO UTC 之前的 Release 将被删除）"
log "额外保护: 最新 $KEEP_LATEST 个 Release，另有 ${#KEEP_PATTERNS[@]} 条 tag 规则"
if [[ $DRY_RUN -eq 1 ]]; then log "模式: DRY-RUN（不会真的删除）"; fi

# ---- 拉取全部 release（含分页），输出 TSV: id / tag / created_at / draft / prerelease ----
RELEASES_TSV=$(gh api --paginate "repos/$REPO/releases?per_page=100"     --jq '.[] | [.id, .tag_name, .created_at, .draft, .prerelease] | @tsv')

if [[ -z "$RELEASES_TSV" ]]; then
    log "该仓库没有任何 Release，无需清理"
    exit 0
fi

TOTAL=$(printf '%s\n' "$RELEASES_TSV" | wc -l | tr -d ' ')
log "共发现 $TOTAL 个 Release"

# ---- 取最新的 KEEP_LATEST 个 tag 名（按 created_at 倒序）----
KEEP_LATEST_TAGS=()
if [[ "$KEEP_LATEST" -gt 0 ]]; then
    while IFS=$'\t' read -r _tag _created; do
        KEEP_LATEST_TAGS+=("$_tag")
    done < <(printf '%s\n' "$RELEASES_TSV" | sort -t"$(printf '\t')" -k3 -r | head -n "$KEEP_LATEST" | cut -f2,3)
fi

tag_protected() {
    local tag="$1" p
    for p in ${KEEP_PATTERNS[@]+"${KEEP_PATTERNS[@]}"}; do
        [[ -n "$p" ]] || continue
        # shellcheck disable=SC2053
        [[ "$tag" == $p ]] && return 0
    done
    for p in ${KEEP_LATEST_TAGS[@]+"${KEEP_LATEST_TAGS[@]}"}; do
        [[ -n "$p" ]] || continue
        [[ "$tag" == "$p" ]] && return 0
    done
    return 1
}

to_epoch() {
    local ts="${1:-}"
    ts="${ts%Z}"
    date -u -d "$ts" +%s 2>/dev/null || date -u -d "${ts/T/ }" +%s 2>/dev/null || echo ""
}

# ---- 先逐个删除 release 附件 ----
# 教训：附件极多的 release（如 v20260524 挂了 370+ 个 apk），
# 直接调 DELETE /releases/{id} 会让 GitHub 后端 502（Server Error），
# 因为它要在一个请求里清理全部附件。必须先把附件删干净再删 release。
delete_assets() {
    local rid="$1"
    local -a aids=()
    while IFS= read -r aid; do
        [[ -n "$aid" ]] && aids+=("$aid")
    done < <(gh api --paginate "repos/$REPO/releases/$rid/assets?per_page=100" --jq ".[].id" 2>/dev/null || true)

    if [[ ${#aids[@]} -eq 0 ]]; then
        return 0
    fi

    log "  含 ${#aids[@]} 个附件，先逐个清理（附件过多会让 release 直接删除返回 502）"
    local aid attempt
    for aid in "${aids[@]}"; do
        for attempt in 1 2 3; do
            if gh api -X DELETE "repos/$REPO/releases/assets/$aid" >/dev/null 2>&1; then
                break
            fi
            sleep $(( attempt * 2 ))
        done
    done
    log "  附件清理完成"
}

DELETED=0
SKIPPED=0
FAILED=0
KEPT=0

while IFS=$'\t' read -r id tag created draft prerelease; do
    [[ -n "$id" ]] || continue

    # 草稿 / 预发布一律不动
    if [[ "$draft" == "true" || "$prerelease" == "true" ]]; then
        log "跳过（草稿/预发布）: $tag"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    if tag_protected "$tag"; then
        log "跳过（受保护）: $tag"
        KEPT=$((KEPT + 1))
        continue
    fi

    epoch=$(to_epoch "$created")
    if [[ -z "$epoch" ]]; then
        log "跳过（无法解析时间）: $tag ($created)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    if (( epoch >= CUTOFF_EPOCH )); then
        log "跳过（仍在保留期内）: $tag ($created)"
        KEPT=$((KEPT + 1))
        continue
    fi

    age_days=$(( (NOW_EPOCH - epoch) / 86400 ))
    log "淘汰: $tag  创建于 $created（$age_days 天前）"

    if [[ $DRY_RUN -eq 1 ]]; then
        DELETED=$((DELETED + 1))
        continue
    fi

    # 附件多的 release 必须先清附件，否则 DELETE release 接口会 502
    delete_assets "$id"

    args=(release delete "$tag" --repo "$REPO" --yes)
    if [[ $DELETE_TAGS -eq 1 ]]; then args+=(--cleanup-tag); fi

    deleted=0
    for attempt in 1 2 3; do
        if gh "${args[@]}" >/dev/null 2>&1; then
            deleted=1
            break
        fi
        log "  删除尝试 $attempt 失败（$(( attempt * 5 )) 秒后重试）"
        sleep $(( attempt * 5 ))
    done

    if [[ $deleted -eq 1 ]]; then
        log "已删除: $tag"
        DELETED=$((DELETED + 1))
    else
        log "删除失败: $tag（3 次重试均未成功）"
        FAILED=$((FAILED + 1))
    fi

    sleep 1   # 避免触发 GitHub API 速率限制
done < <(printf '%s\n' "$RELEASES_TSV")

log "----------------------------------------"
log "结果: 删除 $DELETED / 保留 $KEPT / 跳过 $SKIPPED / 失败 $FAILED"

if [[ $FAILED -gt 0 ]]; then
    exit 2
fi
exit 0
