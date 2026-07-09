#!/usr/bin/env bash
# =============================================================================
# build_jre25.sh
# -----------------------------------------------------------------------------
# 下载并解压 iOS 平台原生的 OpenJDK 25 运行时。
#
# 来源说明：
#   此脚本参照 catsruledogs/Amethyst-iOS-25 仓库的 scripts/build_jre25.sh
#   实现，下载 vibecodest/Amethyst-iOS 发布的 iOS 原生编译版 OpenJDK 25
#   （由 .github/workflows/build-ios-jdk25.yml 从 OpenJDK 源码 +
#    scripts/jdk25_ios_fixups.py 实际针对 iOS 平台编译，而非简单 retag）。
#
# 历史背景：
#   早期版本曾将 macOS Adoptium 二进制 retag 为 iOS，但该方案在运行时
#   会因 OpenJDK 内部的 macOS 专属代码路径而失败。当前版本使用真正的
#   iOS 目标编译产物。
#
# 可覆盖的环境变量：
#   JRE_URL    — 自定义 JRE25 下载地址（默认指向 vibecodest release v10）
#   DEST_DIR   — 解压目标目录（默认为仓库根目录下的 depends/java-25-openjdk）
#   WORK_DIR   — 临时工作目录（默认由 mktemp 创建）
#
# 退出码：
#   0 — 成功（已存在或下载并校验通过）
#   1 — 下载失败 / 解压失败 / 必需的 dylib 缺失
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# 默认值定义
# -----------------------------------------------------------------------------
# vibecodest/Amethyst-iOS 发布的 iOS 原生 OpenJDK 25（release v10）
# 该 URL 已验证可访问（HTTP 200），区别于早期使用的
# Taylen-chud/Amethyst-iOS release（已 404 不可用）
JRE_URL="${JRE_URL:-https://github.com/vibecodest/Amethyst-iOS/releases/download/jre25-ios-v10/jre25-ios-arm64-20260509-release.tar.xz}"

# 目标目录：仓库根目录下的 depends/java-25-openjdk
# 通过脚本自身位置定位仓库根目录，避免硬编码绝对路径
DEST_DIR="${DEST_DIR:-$(cd "$(dirname "$0")/.." && pwd)/depends/java-25-openjdk}"

# 临时工作目录：使用 mktemp 创建，下载完成后自动清理
WORK_DIR="${WORK_DIR:-$(mktemp -d -t jre25-XXXXXX)}"

# -----------------------------------------------------------------------------
# 缓存检查：如果目标目录已存在有效的 JRE25，直接跳过下载
# -----------------------------------------------------------------------------
# release 文件是 OpenJDK 的版本标识文件
# lib/server/libjvm.dylib 是 JVM 核心动态库（HotSpot）
if [ -f "$DEST_DIR/release" ] && [ -f "$DEST_DIR/lib/server/libjvm.dylib" ]; then
    echo "[jre25] $DEST_DIR already present, skipping download"
    exit 0
fi

# -----------------------------------------------------------------------------
# 下载阶段
# -----------------------------------------------------------------------------
echo "[jre25] downloading iOS-built OpenJDK 25 from release..."
echo "[jre25]   URL: $JRE_URL"
echo "[jre25]   Dest: $DEST_DIR"

# 使用 curl 下载，--fail 在 HTTP 4xx/5xx 时返回非零退出码
# -L 跟随 GitHub release 的重定向（302 → 实际下载地址）
# -o 指定输出文件
curl -L --fail -o "$WORK_DIR/jre25.tar.xz" "$JRE_URL"

# -----------------------------------------------------------------------------
# 解压阶段
# -----------------------------------------------------------------------------
mkdir -p "$DEST_DIR"
echo "[jre25] extracting to $DEST_DIR..."
# tar xf 自动识别压缩格式（.tar.xz 会使用 xz 解压）
tar xf "$WORK_DIR/jre25.tar.xz" -C "$DEST_DIR"

# -----------------------------------------------------------------------------
# 完整性校验：必需的动态库必须存在
# -----------------------------------------------------------------------------
# libjvm.dylib — JVM 核心（HotSpot 虚拟机实现）
# libjli.dylib — Java Launcher Interface（启动器接口库）
JVM="$DEST_DIR/lib/server/libjvm.dylib"
JLI="$DEST_DIR/lib/libjli.dylib"
for required in "$JVM" "$JLI"; do
    if [ ! -f "$required" ]; then
        echo "[jre25] ERROR: required dylib missing: $required"
        # 输出目录下所有 libjvm*/libjli* 文件，便于诊断
        find "$DEST_DIR" -name "libjvm*.dylib" -o -name "libjli*.dylib" 2>/dev/null
        exit 1
    fi
done

# -----------------------------------------------------------------------------
# 平台校验：确认 libjvm.dylib 是 iOS Mach-O（而非 macOS retag）
# -----------------------------------------------------------------------------
# vtool 显示 Mach-O 的平台信息。iOS 编译的二进制应包含 "platform IOS"
# 如果是 macOS retag，此检查会输出 WARNING（不阻断构建，但提示风险）
if vtool -show "$JVM" 2>/dev/null | grep -q "platform IOS"; then
    echo "[jre25] confirmed: libjvm.dylib has platform IOS"
else
    echo "[jre25] WARNING: libjvm.dylib is not tagged as iOS. vtool output:"
    vtool -show "$JVM" || true
    echo "[jre25] This may cause runtime failures due to macOS-specific code paths."
fi

# -----------------------------------------------------------------------------
# 清理临时文件
# -----------------------------------------------------------------------------
rm -rf "$WORK_DIR"

echo "[jre25] done. Final size:"
du -sh "$DEST_DIR"
