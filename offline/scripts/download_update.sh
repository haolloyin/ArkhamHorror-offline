#!/usr/bin/env bash
# =============================================================================
# download_update.sh — 获取 Arkham Horror LCG 最新发行版压缩包
#
# 本脚本用于升级流程的第 0 步：
#   发现最新版本 → 版本比较 → 检测网络 → 选择下载策略 → 下载压缩包到 BASE_DIR。
#
# 流程：
#   1. 调用 resolve_latest_url() 解析最新 release tag（5s 超时）。
#   2. 若有 latest tag 且不大于本地版本 → 提示并退出；
#      若无 latest tag（可能网络不通）→ 继续后续步骤。
#   3. 检测 generate_204（3s 超时）判断是否直连 GitHub：
#      - 连通 + 有 tag → 直接 GitHub releases 下载
#      - 连通 + 无 tag → 再次解析后直接下载
#      - 不通 + 有 tag → gh-proxy + 已知 tag 下载
#      - 不通 + 无 tag → gh-proxy + 日期递减（最多 30 次）下载
#   4. 下载前检查文件是否已存在，存在则跳过。
# =============================================================================
set -euo pipefail

# ── 颜色定义 ──────────────────────────────────────────────────────────────────
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'; RESET='\033[0m'
die()  { printf "${RED}[错误]${RESET} %s\n" "$*" >&2; exit 1; }
info() { printf "${CYAN}[信息]${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}[警告]${RESET} %s\n" "$*" >&2; }
ok()   { printf "${GREEN}[完成]${RESET} %s\n" "$*"; }

# ── 中断清理 ─────────────────────────────────────────────────────────────────
# Ctrl+C 或被终止时，清理可能残留的 .partial 文件。
cleanup_partial() {
    [ -n "${DEST_PATH:-}" ] && rm -f "${DEST_PATH}.partial"
}
trap cleanup_partial INT TERM

# ── 解析 BASE_DIR ─────────────────────────────────────────────────────────────
if [ $# -ge 1 ] && [ -n "$1" ]; then
    BASE_DIR="$1"
else
    BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
fi

GAME_DIR="${BASE_DIR}/game"

if [ ! -d "$GAME_DIR" ]; then
    die "未找到 game/ 目录：${GAME_DIR}"
fi

BASE_REPO_URL="https://github.com/haolloyin/ArkhamHorror-offline/"
GH_PROXY_URL="https://gh-proxy.org/"

# ── 1. 检测平台 ──────────────────────────────────────────────────────────────
UNAME_S="$(uname -s)"
case "$UNAME_S" in
    Linux*)   PLATFORM_KEY="linux-x86_64" ;;
    Darwin*)  PLATFORM_KEY="macos-arm64"  ;;
    *)        die "不支持的系统平台：${UNAME_S}（需要 Linux 或 macOS）" ;;
esac
info "当前平台：${PLATFORM_KEY}"

# ── 2. 通用工具函数 ────────────────────────────────────────────────────────────

# 解析 releases/latest 的重定向地址，返回最终 URL。
# 参数：$1 — 超时秒数（默认 5）
resolve_latest_url() {
    local timeout="${1:-5}"
    local url="${BASE_REPO_URL}releases/latest"
    curl -fsSLI --connect-timeout "$timeout" --max-time "$timeout" \
        -o /dev/null -w '%{url_effective}' "$url"
}

# 从解析后的 URL 中提取 release tag。
# 预期格式：.../releases/tag/v20260519.1
extract_tag_from_url() {
    local resolved_url="$1"
    printf '%s' "$resolved_url" \
        | sed -nE 's#.*/releases/tag/(v[0-9]+\.[0-9]+).*#\1#p'
}

# 读取本地当前版本标记。
read_local_version() {
    local ver=""
    for marker in "${GAME_DIR}"/current_v[0-9]*; do
        [ -e "$marker" ] || continue
        local fname
        fname="$(basename "$marker")"
        ver="${fname#current_}"
        break
    done
    printf '%s' "$ver"
}

# 比较两个版本号（去掉 v 前缀后按字符串比较）。
# 参数：$1 — 远程 tag, $2 — 本地 tag
# 返回码：0 表示 $1 > $2（需要更新），1 表示 $1 <= $2（无需更新）
is_newer_version() {
    local remote="$1" local="$2"
    local remote_cmp="${remote#v}"
    local local_cmp="${local#v}"

    if [ "$local" = "$remote" ]; then
        return 1  # 相同版本
    fi
    if [ "$local_cmp" \> "$remote_cmp" ]; then
        return 1  # 本地更新
    fi
    return 0  # 远程更新
}

# 根据 tag 构建下载所需的全部路径和 URL。
# 设置全局变量：ARCHIVE_NAME, DOWNLOAD_URL, DEST_PATH
build_archive_info() {
    local tag="$1" prefix="${2:-}"
    ARCHIVE_NAME="ArkhamHorror-${PLATFORM_KEY}-${tag}.tar.gz"
    SHOW_URL="releases/download/${tag}/${ARCHIVE_NAME}"
    DOWNLOAD_URL="${prefix}${BASE_REPO_URL}${SHOW_URL}"
    DEST_PATH="${BASE_DIR}/${ARCHIVE_NAME}"
}

# 检查目标文件是否已存在且非空。
archive_exists() {
    [ -s "$DEST_PATH" ]
}

# 通过 1 字节 range GET 探测 URL 是否可达（部分 CDN/反代不转发 HEAD）。
# 参数：$1 — URL, $2 — 超时秒数（默认 5）
url_reachable() {
    local url="$1" timeout="${2:-5}"
    curl -fsS -r 0-0 --connect-timeout "$timeout" --max-time "$timeout" \
        -o /dev/null "$url" >/dev/null 2>&1
}

# 原子下载：先下载到 .partial 临时文件，成功后重命名。
# 参数：$1 — 下载 URL, $2 — 目标路径
do_download() {
    local url="$1" dest="$2"
    local partial="${dest}.partial"

    rm -f "$partial"

    if ! curl -fL --retry 3 --retry-delay 2 -o "$partial" "$url"; then
        rm -f "$partial"
        return 1
    fi

    if [ ! -s "$partial" ]; then
        rm -f "$partial"
        return 1
    fi

    mv "$partial" "$dest"
    return 0
}

# 检查 generate_204 是否在指定超时内连通。
# 参数：$1 — 超时秒数（默认 3）
check_network_204() {
    local timeout="${1:-3}"
    local http_code
    http_code="$(curl -fsS --connect-timeout "$timeout" --max-time "$timeout" \
        -o /dev/null -w '%{http_code}' \
        'http://www.gstatic.com/generate_204' 2>/dev/null || true)"
    [ "$http_code" = "204" ]
}

# 计算从当天往前推 N 天的日期（兼容 GNU date 和 BSD date）。
# 参数：$1 — 往前推的天数
offset_date() {
    local offset="$1" today result
    today="$(date +%Y%m%d)"

    # 尝试 GNU date
    result="$(date -d "${today} - ${offset} days" +%Y%m%d 2>/dev/null || true)"
    if [ -n "$result" ]; then
        printf '%s' "$result"
        return 0
    fi

    # 尝试 BSD date (macOS)
    result="$(date -v-${offset}d +%Y%m%d 2>/dev/null || true)"
    if [ -n "$result" ]; then
        printf '%s' "$result"
        return 0
    fi

    die "无法计算目标日期，date 命令不受支持。"
}

# 打印即将下载的计划信息（在 build_archive_info 之后调用）。
# 参数：$1 — 下载方式描述（如 "正在下载" / "正在通过 gh-proxy 下载"）
print_download_plan() {
    local action="$1"
    info "压缩包名称：${ARCHIVE_NAME}"
    info "下载地址：  ${SHOW_URL}"
    info "保存位置：  ${DEST_PATH}"
    echo ""
    info "${action} ..."
}

# ── 3. 版本与文件检查封装 ─────────────────────────────────────────────────────
# 给定 tag，依次检查：版本是否比本地新 → 本地压缩包是否已存在。
# 参数：$1 — tag, $2 — URL 前缀（可选，默认无前缀）
# 返回码：0 — 需要下载；1 — 版本不新或相同；2 — 本地文件已存在
verify_download_needed() {
    local tag="$1" prefix="${2:-}"

    if [ -n "$CURRENT_VERSION" ] && ! is_newer_version "$tag" "$CURRENT_VERSION"; then
        return 1
    fi

    build_archive_info "$tag" "$prefix"

    if archive_exists; then
        return 2
    fi

    return 0
}

# ── 4. 主流程 ────────────────────────────────────────────────────────────────────

# 4a. 读取本地版本
CURRENT_VERSION="$(read_local_version)"
if [ -n "$CURRENT_VERSION" ]; then
    info "当前本地版本：${CURRENT_VERSION}"
else
    info "当前本地版本：（无版本信息，视为最早版本）"
fi

# 4b. 第 1 步：先尝试解析 latest tag（5s 超时）
info "解析最新 release 标签（超时 5s）..."
LATEST_TAG=""
RESOLVED_URL="$(resolve_latest_url 5 || true)"
if [ -n "$RESOLVED_URL" ]; then
    LATEST_TAG="$(extract_tag_from_url "$RESOLVED_URL" || true)"
fi

# 4c. 第 2 步：版本比较 + 本地文件检查
if [ -n "$LATEST_TAG" ]; then
    info "最新 release 标签：${LATEST_TAG}"
    VERIFY_RC=0
    verify_download_needed "$LATEST_TAG" || VERIFY_RC=$?
    case "$VERIFY_RC" in
        1) ok "本地已是最新版本 ${CURRENT_VERSION}，无需下载。"; echo ""; exit 0 ;;
        2) ok "本地已存在最新版压缩包：${ARCHIVE_NAME}，跳过下载。"; echo ""; exit 0 ;;
    esac
    ok "需要下载新版本 ${LATEST_TAG}。"
else
    warn "未能解析到最新 release 标签（可能网络不通），将继续尝试后续步骤。"
fi

# 4d. 第 3 步：检测 generate_204（3s 超时）
info "检测网络连通性（generate_204，超时 3s）..."
IS_DIRECT_NETWORK=false
if check_network_204 3; then
    IS_DIRECT_NETWORK=true
    ok "直连 GitHub 可达，使用直接下载模式"
else
    warn "无法直连 GitHub，将尝试代理下载模式"
fi
echo ""

# ── 5. 按四种组合策略下载 ──────────────────────────────────────────────────────

# 情况 A：直连 + 有 tag → 直接 GitHub 下载（4c 已校验版本+文件，直接下载）
if [ "$IS_DIRECT_NETWORK" = true ] && [ -n "$LATEST_TAG" ]; then
    print_download_plan "正在下载"

    if ! do_download "$DOWNLOAD_URL" "$DEST_PATH"; then
        die "下载失败：${DOWNLOAD_URL}"
    fi

# 情况 B：直连 + 无 tag → 再次解析后直接下载
elif [ "$IS_DIRECT_NETWORK" = true ] && [ -z "$LATEST_TAG" ]; then
    info "重新解析最新 release 标签 ..."
    RESOLVED_URL="$(resolve_latest_url 10 || true)"
    if [ -z "$RESOLVED_URL" ]; then
        die "解析最新 release URL 失败，请检查网络连接。"
    fi

    LATEST_TAG="$(extract_tag_from_url "$RESOLVED_URL")"
    if [ -z "$LATEST_TAG" ]; then
        die "无法从解析后的 URL 中提取 release 标签：
        ${RESOLVED_URL}
        可能是 GitHub 的跳转格式发生了变化。"
    fi

    info "最新 release 标签：${LATEST_TAG}"
    VERIFY_RC=0
    verify_download_needed "$LATEST_TAG" || VERIFY_RC=$?
    case "$VERIFY_RC" in
        1) ok "已是最新版本（${CURRENT_VERSION}），无需下载。"; echo ""; exit 0 ;;
        2) ok "本地已存在最新版压缩包：${ARCHIVE_NAME}，跳过下载。"; echo ""; exit 0 ;;
    esac

    print_download_plan "正在下载"

    if ! do_download "$DOWNLOAD_URL" "$DEST_PATH"; then
        die "下载失败：${DOWNLOAD_URL}"
    fi

# 情况 C：不通 + 有 tag → gh-proxy 代理下载（4c 已校验版本+文件，直接下载）
elif [ "$IS_DIRECT_NETWORK" = false ] && [ -n "$LATEST_TAG" ]; then
    build_archive_info "$LATEST_TAG" "$GH_PROXY_URL"

    print_download_plan "正在通过代理下载"

    if ! do_download "$DOWNLOAD_URL" "$DEST_PATH"; then
        die "代理下载失败：${DOWNLOAD_URL}"
    fi

# 情况 D：不通 + 无 tag → gh-proxy + 日期递减（最多 30 次）
else
    MAX_RETRIES=30
    TRIES=0
    LATEST_TAG=""

    info "按日期递减探测是否有新版本（最多 ${MAX_RETRIES} 次），请稍等1~2分钟..."

    while [ "$TRIES" -lt "$MAX_RETRIES" ]; do
        TARGET_DATE="$(offset_date "$TRIES")"
        TAG="v${TARGET_DATE}.1"

        build_archive_info "$TAG" "$GH_PROXY_URL"

        # 候选版本不比本地新 → 日期已退到本地版本或更早，不可能再找到更新版本
        if [ -n "$CURRENT_VERSION" ] && ! is_newer_version "$TAG" "$CURRENT_VERSION"; then
            LATEST_TAG="$CURRENT_VERSION"
            break
        fi

        # 本地已有该版本压缩包 → 跳过下载
        if archive_exists; then
            LATEST_TAG="$TAG"
            warn "无法从服务器获取最新版本；本地已存在版本 ${TAG} 的压缩包"
            break
        fi

        # range GET 探测 URL 是否可达
        if ! url_reachable "$DOWNLOAD_URL" 5; then
            TRIES=$((TRIES + 1))
            continue
        fi

        # 可达则下载
        info "探测到可用版本：${TAG}，开始下载 ..."
        if do_download "$DOWNLOAD_URL" "$DEST_PATH"; then
            LATEST_TAG="$TAG"
            break
        fi

        TRIES=$((TRIES + 1))
    done

    if [ -z "$LATEST_TAG" ]; then
        die "在 ${MAX_RETRIES} 次尝试后仍未找到可下载的版本。"
    fi
fi

# ── 6. 最终提示 ──────────────────────────────────────────────────────────────────
echo ""
if [ -n "$CURRENT_VERSION" ] && [ -n "$LATEST_TAG" ] && \
   ! is_newer_version "$LATEST_TAG" "$CURRENT_VERSION"; then
    ok "已是最新版本（${CURRENT_VERSION}），无需更新。"
else
    ok "已下载 ${LATEST_TAG} 版本"
fi
echo ""
