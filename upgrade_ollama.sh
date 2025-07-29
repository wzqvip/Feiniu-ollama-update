#!/bin/bash

set -e
set -o pipefail

echo "🔄 Ollama 升级脚本 for FnOS, 脚本v2.1.1"

# 1. 查找 Ollama 安装路径
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

## 如果未找到主安装路径，则检查是否存在中断的备份
if [ -z "$AI_INSTALLER" ]; then
    for vol in "${VOL_PREFIXES[@]}"; do
        testdir="$vol/@appcenter/ai_installer"
        if [ -d "$testdir" ]; then
            cd "$testdir"
            LAST_BK=$(ls -td ollama_bk_* 2>/dev/null | head -n 1)
            if [ -n "$LAST_BK" ] && [ ! -d "ollama" ]; then
                echo "⚠️ 检测到未完成的升级：$testdir 中存在备份 $LAST_BK，但当前没有 ollama/"
                mv "$LAST_BK" ollama
                echo "✅ 已恢复 $LAST_BK 为 ollama/， 请重新执行本脚本更新"
                if [ -x "./ollama/bin/ollama" ]; then
                    ./ollama/bin/ollama --version
                else
                    echo "⚠️ 还原后未找到 ollama 可执行文件，可能备份不完整"
                fi
                exit 0  # ✅ 成功还原后立即退出整个脚本
            fi
        fi
    done

    echo "❌ 未找到 Ollama 安装路径，也没有检测到可恢复的中断备份"
    exit 1
fi

cd "$AI_INSTALLER"

# 2. 打印当前版本
echo "📦 正在检测当前 Ollama 客户端版本..."

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
    echo "❌ 未找到 ollama 可执行文件"
fi

# 3. 下载最新版本
FILENAME="ollama-linux-amd64.tgz"
echo "🌐 获取 Ollama 最新版本号..."

# 使用 GitHub API 获取最新版本号
#LATEST_TAG=$(curl -s https://api.github.com/repos/ollama/ollama/releases/latest | grep '"tag_name":' | cut -d'"' -f4)
# 国内网络原因，或者代理，会遇到速率限制问题。 用一个小trick拉网页获取。
LATEST_TAG=$(curl -s https://github.com/ollama/ollama/releases | grep -oP '/ollama/ollama/releases/tag/\K[^"]+' | head -n 1)

if [ -z "$LATEST_TAG" ]; then
    echo "❌ 无法从 GitHub 获取 Ollama 最新版本号，请检查网络连接或代理设置"
    exit 1
fi

echo "📦 最新版本号：$LATEST_TAG"

# 如果版本一致，退出升级
if [ "$CLIENT_VER" = "${LATEST_TAG#v}" ]; then
    echo "✅ 当前已是最新版本（v$CLIENT_VER），无需升级。"
    exit 0
fi

# 如果已有完整文件就跳过下载
if [ -f "$FILENAME" ]; then
    echo "🔍 检测到本地已有 $FILENAME，验证完整性..."

    if gzip -t "$FILENAME" 2>/dev/null; then
        echo "✅ 本地压缩包完整，跳过下载"
    else
        echo "❌ 本地文件损坏，重新下载"
        rm -f "$FILENAME"
    fi
fi

# 如果文件不存在才开始下载
if [ ! -f "$FILENAME" ]; then
    echo "⬇️ 正在下载版本 $LATEST_TAG ..."
    URL="https://github.com/ollama/ollama/releases/download/$LATEST_TAG/$FILENAME"
    if command -v aria2c >/dev/null 2>&1; then
        echo "🚀 使用 aria2c 多线程下载..."
        aria2c -x 16 -s 16 -k 1M -o "$FILENAME" "$URL"
    else
        echo "⬇️ 使用 curl 单线程下载..."
        curl -L -o "$FILENAME" "$URL"
    fi
fi


# 4. 备份旧版本
BACKUP_NAME="ollama_bk_$(date +%Y%m%d_%H%M%S)"
mv ollama "$BACKUP_NAME"
echo "📦 已备份原版 Ollama 为：$BACKUP_NAME"

# 5. 解压部署新版本
echo "📦 解压到 ollama/ ..."
mkdir -p ollama
tar -xzf "$FILENAME" -C ollama

# 6. 升级 pip 和 open-webui
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

# 7. 打印新版本确认
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
