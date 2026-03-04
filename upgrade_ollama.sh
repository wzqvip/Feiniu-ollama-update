#!/bin/bash

set -e
set -o pipefail

echo "🔄 Ollama 升级脚本 for FnOS, 脚本v3.2.0"

# ─── 工具函数 ───────────────────────────────────────────────────────────────────

available() { command -v "$1" >/dev/null 2>&1; }

require() {
    local MISSING=''
    for TOOL in "$@"; do
        if ! available "$TOOL"; then
            MISSING="$MISSING $TOOL"
        fi
    done
    echo "$MISSING"
}

# ─── 依赖检查 ────────────────────────────────────────────────────────────────────

NEEDS=$(require curl tar grep)
if [ -n "$NEEDS" ]; then
    echo "❌ 缺少以下必要工具，请先安装：$NEEDS"
    exit 1
fi

# ─── 架构检测 ────────────────────────────────────────────────────────────────────

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)       ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "❌ 不支持的架构：$ARCH"; exit 1 ;;
esac

# ─── 版本参数（支持通过环境变量指定版本） ─────────────────────────────────────────

VER_PARAM="${OLLAMA_VERSION:+?version=$OLLAMA_VERSION}"

# ─── 镜像列表（竞速顺序）──────────────────────────────────────────────────────────

# 用法：在列表中追加或删除镜像前缀即可，脚本自动竞速
GH_MIRRORS=("https://xuc.xi-xu.me/gh" "https://ghfast.top" "https://gh.con.sh")

# ─── 多源竞速下载函数 ─────────────────────────────────────────────────────────────
#
# race_download_file <dest_file> <url1> [url2] ...
#   同时向所有 URL 发起下载，谁先完整写入 dest_file 就用谁，其余 kill 掉。
#   支持断点续传（-C -）：若 dest_file 已存在则从断点继续。
#   成功返回 0；全部失败返回 1。

race_download_file() {
    local dest="$1"; shift
    local urls=("$@")
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local pids=() tmp_files=() flag_dir
    flag_dir="$tmp_dir/done"
    local winner_tmp=""

    # 若目标文件已有部分内容则继续（断点续传）
    local existing_size=0
    [ -f "$dest" ] && existing_size=$(stat -c%s "$dest" 2>/dev/null || echo 0)

    for i in "${!urls[@]}"; do
        local url="${urls[$i]}"
        local tmp_out="$tmp_dir/part_${i}"

        # 若本地已有部分文件，复制一份作为续传基础
        if [ "$existing_size" -gt 0 ]; then
            cp "$dest" "$tmp_out" 2>/dev/null || true
        fi

        (
            # -C - 断点续传；--retry 3 简单重试；--max-time 300
            if curl --fail --location --silent --show-error \
                     -C - --retry 3 --max-time 300 \
                     -o "$tmp_out" "$url"; then
                # 写入成功信号（文件名即 tmp 路径）
                echo "$tmp_out" > "$flag_dir"
            fi
        ) &
        pids+=($!)
        tmp_files+=("$tmp_out")
    done

    # 轮询等待第一个成功信号（最多 300 秒）
    local timeout=300 elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if [ -f "$flag_dir" ]; then
            winner_tmp=$(cat "$flag_dir")
            break
        fi
        # 检查是否所有子进程都已退出（全败）
        local all_done=1
        for pid in "${pids[@]}"; do
            kill -0 "$pid" 2>/dev/null && all_done=0 && break
        done
        [ $all_done -eq 1 ] && break
        sleep 0.5
        elapsed=$((elapsed + 1))
    done

    # Kill 所有剩余子进程
    for pid in "${pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null

    if [ -n "$winner_tmp" ] && [ -s "$winner_tmp" ]; then
        mv "$winner_tmp" "$dest"
        rm -rf "$tmp_dir"
        return 0
    fi

    rm -rf "$tmp_dir"
    return 1
}

# ─── 下载并解压函数（多源竞速 + 断点续传） ───────────────────────────────────────

download_and_extract() {
    local url_base="$1"   # 仍作兜底（ollama.com/download）
    local dest_dir="$2"
    local filename="$3"

    # 构建各镜像的完整 URL 列表
    local gh_urls=() direct_url="https://github.com/ollama/ollama/releases/download/${LATEST_TAG}"
    for mirror in "${GH_MIRRORS[@]}"; do
        gh_urls+=("${mirror}/ollama/ollama/releases/download/${LATEST_TAG}")
    done

    # ── 尝试 .tar.zst 格式（新版 Ollama 默认）──────────────────────────────────
    local try_zst=0
    # 用第一个镜像或直连快速探测 zst 是否存在（HEAD 请求，不下数据）
    if curl --fail --silent --head --location --max-time 10 \
            "${gh_urls[0]}/${filename}.tar.zst" >/dev/null 2>&1 || \
       curl --fail --silent --head --location --max-time 10 \
            "${direct_url}/${filename}.tar.zst" >/dev/null 2>&1; then
        try_zst=1
    fi

    if [ "$try_zst" -eq 1 ]; then
        if ! available zstd; then
            echo "❌ 此版本需要 zstd 解压工具，请先安装："
            echo "   apt-get install zstd  或  opkg install zstd"
            exit 1
        fi
        echo "⬇️ 正在竞速下载 ${filename}.tar.zst（${#gh_urls[@]} 镜像 + 直连同时抢跑）..."

        # 构建所有候选 URL（镜像优先，直连兜底）
        local all_urls=()
        for base in "${gh_urls[@]}"; do all_urls+=("${base}/${filename}.tar.zst"); done
        all_urls+=("${direct_url}/${filename}.tar.zst")
        all_urls+=("${url_base}/${filename}.tar.zst${VER_PARAM}")

        local tmp_file="${dest_dir}/${filename}.tar.zst.tmp"
        if race_download_file "$tmp_file" "${all_urls[@]}"; then
            echo "✅ 下载完成，开始解压..."
            zstd -d < "$tmp_file" | tar -xf - -C "${dest_dir}"
            rm -f "$tmp_file"
            return 0
        fi
        echo "❌ 所有源均下载失败"
        return 1
    fi

    # ── 回退到 .tgz 格式（旧版兼容）──────────────────────────────────────────────
    echo "⬇️ 正在竞速下载 ${filename}.tgz（${#gh_urls[@]} 镜像 + 直连同时抢跑）..."

    local all_urls=()
    for base in "${gh_urls[@]}"; do all_urls+=("${base}/${filename}.tgz"); done
    all_urls+=("${direct_url}/${filename}.tgz")
    all_urls+=("${url_base}/${filename}.tgz${VER_PARAM}")

    local tmp_file="${dest_dir}/${filename}.tgz.tmp"
    if race_download_file "$tmp_file" "${all_urls[@]}"; then
        echo "✅ 下载完成，开始解压..."
        tar -xzf "$tmp_file" -C "${dest_dir}"
        rm -f "$tmp_file"
        return 0
    fi
    echo "❌ 所有源均下载失败"
    return 1
}

# ─── 1. 查找 Ollama 安装路径 ─────────────────────────────────────────────────────

echo "🔍 查找 Ollama 安装路径..."
VOL_PREFIXES=(/vol1 /vol2 /vol3 /vol4 /vol5 /vol6 /vol7 /vol8 /vol9)
AI_INSTALLER=""

# 遍历寻找 ollama 安装目录
for vol in "${VOL_PREFIXES[@]}"; do
    if [ -d "$vol/@appcenter/ai_installer/ollama" ]; then
        AI_INSTALLER="$vol/@appcenter/ai_installer"
        echo "✅ 找到安装路径：$AI_INSTALLER"
        break
    fi
done

# 如果未找到主安装路径，则检查是否存在中断的备份
if [ -z "$AI_INSTALLER" ]; then
    for vol in "${VOL_PREFIXES[@]}"; do
        testdir="$vol/@appcenter/ai_installer"
        if [ -d "$testdir" ]; then
            cd "$testdir"
            LAST_BK=$(ls -td ollama_bk_* 2>/dev/null | head -n 1)
            if [ -n "$LAST_BK" ] && [ ! -d "ollama" ]; then
                echo "⚠️ 检测到未完成的升级：$testdir 中存在备份 $LAST_BK，但当前没有 ollama/"
                mv "$LAST_BK" ollama
                echo "✅ 已恢复 $LAST_BK 为 ollama/，请重新执行本脚本更新"
                if [ -x "./ollama/bin/ollama" ]; then
                    ./ollama/bin/ollama --version
                else
                    echo "⚠️ 还原后未找到 ollama 可执行文件，可能备份不完整"
                fi
                exit 0
            fi
        fi
    done

    echo "❌ 未找到 Ollama 安装路径，也没有检测到可恢复的中断备份"
    exit 1
fi

cd "$AI_INSTALLER"

# ─── 2. 打印当前版本 ──────────────────────────────────────────────────────────────

echo "📦 正在检测当前 Ollama 客户端版本..."

CLIENT_VER=""
if [ -x "./ollama/bin/ollama" ]; then
    VERSION_RAW=$(./ollama/bin/ollama --version 2>&1)
    CLIENT_VER=$(echo "$VERSION_RAW" | grep -i "client version" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')

    if [ -n "$CLIENT_VER" ]; then
        echo "📦 当前已安装版本：v$CLIENT_VER（客户端）"
    else
        echo "⚠️ 无法获取版本号，原始输出如下："
        echo "$VERSION_RAW"
    fi
else
    echo "⚠️ 未找到 ollama 可执行文件，将强制下载安装"
fi

# ─── 3. 获取最新版本号 ────────────────────────────────────────────────────────────

echo "🌐 并行获取 Ollama 最新版本号（多源竞速）..."

# 构建多个版本号获取 URL（包括镜像、GitHub API、页面抓取）
_TAG_SOURCES=(
    # GitHub 官方 API（返回 JSON，速度快）
    "https://api.github.com/repos/ollama/ollama/releases/latest"
    # 各镜像的 releases 页面
    "https://xuc.xi-xu.me/gh/ollama/ollama/releases"
    "https://ghfast.top/ollama/ollama/releases"
    "https://gh.con.sh/ollama/ollama/releases"
    # 直连 GitHub（作为安全底）
    "https://github.com/ollama/ollama/releases"
)

# 并行向所有源发起请求，谁先返回有效 tag 就用谁
_TAG_FIFO=$(mktemp -u)
mkfifo "$_TAG_FIFO"
_TAG_PIDS=()
for _src in "${_TAG_SOURCES[@]}"; do
    (
        _raw=$(curl -s --max-time 15 --location "$_src" 2>/dev/null)
        # GitHub API 返回 JSON，用 tag_name 字段
        _tag=$(echo "$_raw" | grep -oP '"tag_name":\s*"\K[^"]+' | head -n1)
        # 页面抓取方式（镜像页/GitHub releases）
        [ -z "$_tag" ] && _tag=$(echo "$_raw" | grep -oP '/ollama/ollama/releases/tag/\K[^"]+' | head -n1)
        [ -n "$_tag" ] && echo "$_tag" > "$_TAG_FIFO"
    ) &
    _TAG_PIDS+=($!)
done

# 读取第一个有效结果（跭时 15s）
LATEST_TAG=$(timeout 15 cat "$_TAG_FIFO" 2>/dev/null | head -n1)

# 清理：kill 剪余子进程，删除 FIFO
for _p in "${_TAG_PIDS[@]}"; do kill "$_p" 2>/dev/null || true; done
wait 2>/dev/null
rm -f "$_TAG_FIFO"

if [ -z "$LATEST_TAG" ]; then
    echo "❌ 无法从任何源获取 Ollama 最新版本号，请检查网络连接或代理设置"
    exit 1
fi

echo "📦 最新版本号：$LATEST_TAG"

# 如果版本一致，退出升级
if [ -n "$CLIENT_VER" ] && [ "$CLIENT_VER" = "${LATEST_TAG#v}" ]; then
    echo "✅ 当前已是最新版本（v$CLIENT_VER），无需升级。"
    exit 0
fi

# ─── 4. 备份旧版本 ────────────────────────────────────────────────────────────────

BACKUP_NAME="ollama_bk_$(date +%Y%m%d_%H%M%S)"
mv ollama "$BACKUP_NAME"
echo "📦 已备份原版 Ollama 为：$BACKUP_NAME"

# ─── 5. 下载并解压新版本 ──────────────────────────────────────────────────────────

echo "📦 解压到 ollama/ ..."
mkdir -p ollama
download_and_extract "https://ollama.com/download" "ollama" "ollama-linux-${ARCH}"

# ─── 6. 升级 pip 和 open-webui ───────────────────────────────────────────────────

PIP_DIR="$AI_INSTALLER/python/bin"
PYTHON_EXEC="/var/apps/ai_installer/target/python/bin/python3.12"

echo "⬆️ 正在升级 pip..."
"$PYTHON_EXEC" -m pip install --upgrade pip || {
    echo "❌ pip 升级失败，可能是网络问题或 GitHub 被墙"
    echo "   请尝试设置代理后重新运行："
    echo "   export https_proxy=http://127.0.0.1:7890"
    echo "   export http_proxy=http://127.0.0.1:7890"
    exit 1
}

echo "⬆️ 正在升级 open-webui..."
cd "$PIP_DIR"
./pip3 install --upgrade open_webui || {
    echo "❌ open-webui 升级失败"
    echo "🔎 常见原因：网络不通 / pip太旧 / 无法连接 PyPI"
    echo "✔️ 可尝试设置代理或手动升级："
    echo "   export https_proxy=http://127.0.0.1:7890"
    echo "   export http_proxy=http://127.0.0.1:7890"
    exit 1
}

# ─── 7. 打印新版本确认 ────────────────────────────────────────────────────────────

cd "$AI_INSTALLER"

if [ -x "./ollama/bin/ollama" ]; then
    VERSION_RAW=$(./ollama/bin/ollama --version 2>&1)
    CLIENT_VER=$(echo "$VERSION_RAW" | grep -i "client version" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')

    if [ -n "$CLIENT_VER" ]; then
        echo "✅ 新 Ollama 版本为：v$CLIENT_VER（客户端）"
    else
        echo "⚠️ 无法提取版本号，原始输出如下："
        echo "$VERSION_RAW"
    fi
else
    echo "❌ 未找到 ollama 可执行文件"
fi

echo "🎉 升级完成！Ollama 与 open-webui 均为最新版本。"
