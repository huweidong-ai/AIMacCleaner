#!/bin/bash
# build_app.sh — 一键编译 release 并打成 .app bundle
# 用法：./build_app.sh [目标路径]
#   默认输出到 /Applications/AIMacCleaner.app（Finder 侧栏「应用程序」和 Launchpad 都能看到）
#   装到 ~/Applications 也可以，但两处同时存在会让 Launchpad 出现重复图标
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-/Applications/AIMacCleaner.app}"
APP_NAME="AIMacCleaner"
# CLI 命令名（也是编译出的二进制文件名）。与 APP_NAME（GUI app 显示名/品牌，驼峰）解耦：
# 行业 CLI 惯例用全小写连字符（kebab-case，如 docker/brew/kubectl），驼峰不符合规范，
# 所以命令名用 ai-mac-cleaner；app 显示名 AIMacCleaner 是品牌，保持驼峰不动。
CLI_NAME="ai-mac-cleaner"
# 版本号采用「日期制」：YYYY.M.D（如 2026.8.10），同一天多次构建追加序号
# 变成 YYYY.M.D-2、YYYY.M.D-3 …… 由下方在真正构建时按当天日期算出，并写进
# 生成的 Swift 文件（AppVersion.generated.swift）与 Info.plist。
#
# 下面这个 APP_VERSION 只是给「仅取变量」路径（EXPUNGE_VARS_ONLY=1，被
# build_release.sh source 时）用的占位，真正的值在早退块之后计算。
APP_VERSION="0.0.0-dev"

# 允许 build_release.sh 只取变量、不真的构建
if [ "${EXPUNGE_VARS_ONLY:-}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

cd "$PROJECT_DIR"

# ── 计算日期制版本号 ──
# 格式：YYYY.M.D（去掉月份/日期的前导零，贴合 2026.8.9 这种写法）。
# 同一天第 1 次构建 = 纯日期；第 2 次起追加 -N（N 从 2 开始）。
# 计数器存在仓库根目录的隐藏文件里（已被 .gitignore 忽略），清 .build 也不会丢。
Y=$(date +%Y); M=$(date +%m); D=$(date +%d)
M=${M#0}; D=${D#0}
TODAY="$Y.$M.$D"
STATE_FILE="$PROJECT_DIR/.build_version_state"
if [ -f "$STATE_FILE" ]; then
    OLD=$(cat "$STATE_FILE" 2>/dev/null || echo "")
    OLD_DATE="${OLD%%:*}"
    OLD_COUNT="${OLD##*:}"
    case "$OLD_COUNT" in (*[!0-9]*|"") OLD_COUNT=0;; esac
else
    OLD_DATE=""; OLD_COUNT=0
fi
if [ "$OLD_DATE" = "$TODAY" ]; then
    COUNT=$((OLD_COUNT + 1))
else
    COUNT=1
fi
if [ "$COUNT" -eq 1 ]; then
    APP_VERSION="$TODAY"
else
    APP_VERSION="$TODAY-$COUNT"
fi
APP_VERSION_SHORT="$TODAY"
echo "$TODAY:$COUNT" > "$STATE_FILE"

# 把版本号写进生成的 Swift 文件，作为 AIMacCleanerApp.version 的唯一来源。
# 这样「关于」面板 / --help / 反馈页展示的版本与打包版本严格一致。
GEN_FILE="$PROJECT_DIR/Sources/AIMacCleaner/AppVersion.generated.swift"
cat > "$GEN_FILE" <<SWIFT
// 自动生成 —— 由 build_app.sh 写入，请勿手改，也不入库（见 .gitignore）。
// 版本号采用日期制：YYYY.M.D 或同日多次构建的 YYYY.M.D-N。
import Foundation
extension AIMacCleanerApp {
    /// 版本号的唯一来源，由 build_app.sh 在打包时注入。
    nonisolated static let version = "$APP_VERSION"
}
SWIFT
echo "  版本：$APP_VERSION（短版本 $APP_VERSION_SHORT）"

echo "━━ 1/5 编译 release ━━"
swift build -c release

BIN="$PROJECT_DIR/.build/release/$CLI_NAME"
test -f "$BIN" || { echo "✗ 编译产物未找到: $BIN"; exit 1; }

echo "━━ 2/5 生成 icon ━━"
ICON_DIR="$(mktemp -d)"
# 图标源图：Sources/IconGen/AIMacCleaner.png（1024x1024）。
# 想换图标：编辑 Sources/IconGen/render.swift 后跑 `swift Sources/IconGen/render.swift`。
# render 脚本渲染的是与 UI 顶部品牌区完全一致的 wand.and.rays SF Symbol
# + Petrol Blue 渐变 + 圆角矩形（cornerRadius 1024*7/24）。
ICON_PNG="$PROJECT_DIR/Sources/IconGen/AIMacCleaner.png"
if [ ! -f "$ICON_PNG" ]; then
    echo "✗ 找不到图标源图：$ICON_PNG"
    echo "  跑 `swift Sources/IconGen/render.swift` 重新生成。"
    exit 1
fi
cp "$ICON_PNG" "$ICON_DIR/icon_1024.png"
mkdir -p "$ICON_DIR/icon.iconset"
for size in 16 32 64 128 256 512 1024; do
    sips -z $size $size "$ICON_DIR/icon_1024.png" --out "$ICON_DIR/icon.iconset/icon_${size}x${size}.png" > /dev/null
done
sips -z 32 32   "$ICON_DIR/icon_1024.png" --out "$ICON_DIR/icon.iconset/icon_16x16@2x.png"     > /dev/null
sips -z 64 64   "$ICON_DIR/icon_1024.png" --out "$ICON_DIR/icon.iconset/icon_32x32@2x.png"     > /dev/null
sips -z 256 256 "$ICON_DIR/icon_1024.png" --out "$ICON_DIR/icon.iconset/icon_128x128@2x.png"   > /dev/null
sips -z 512 512 "$ICON_DIR/icon_1024.png" --out "$ICON_DIR/icon.iconset/icon_256x256@2x.png"   > /dev/null
sips -z 1024 1024 "$ICON_DIR/icon_1024.png" --out "$ICON_DIR/icon.iconset/icon_512x512@2x.png" > /dev/null
iconutil -c icns "$ICON_DIR/icon.iconset" -o "$ICON_DIR/$APP_NAME.icns"
ICON_SRC="$ICON_DIR/$APP_NAME.icns"

echo "━━ 3/5 组装 .app bundle ━━"
rm -rf "$TARGET"
mkdir -p "$TARGET/Contents/MacOS" "$TARGET/Contents/Resources"
cp "$BIN" "$TARGET/Contents/MacOS/$CLI_NAME"
chmod +x "$TARGET/Contents/MacOS/$CLI_NAME"

# icon（用 2/5 从静态源图生成的 icns）
if [ ! -f "$ICON_SRC" ]; then
    echo "✗ 找不到 icns：$ICON_SRC"
    exit 1
fi
cp "$ICON_SRC" "$TARGET/Contents/Resources/$APP_NAME.icns"
rm -rf "$ICON_DIR"

# Info.plist
# heredoc 不加引号 —— 需要展开 $APP_VERSION。
# 已确认 plist 里没有其他 $ 或反引号，不会被 shell 误展开。
cat > "$TARGET/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>AIMacCleaner</string>
	<key>CFBundleExecutable</key>
	<string>ai-mac-cleaner</string>
	<key>CFBundleIconFile</key>
	<string>AIMacCleaner</string>
	<key>CFBundleIdentifier</key>
	<string>com.aicleaner.app</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>AIMacCleaner</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$APP_VERSION_SHORT</string>
	<key>CFBundleVersion</key>
	<string>$APP_VERSION</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>© 2026 AI Mac Cleaner. Free and open source.</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSSupportsAutomaticGraphicsSwitching</key>
	<true/>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsArbitraryLoads</key>
		<true/>
	</dict>
</dict>
</plist>
PLIST

echo "━━ 4/5 稳定 adhoc 签名 ━━"
# 为什么要签：macOS 的 TCC（隐私授权）用**代码签名身份**当「这个 app 是谁」的
# 主键。之前完全不签名时，bundle 每次重新打包身份就变，系统当成一个全新的 app，
# 于是「想访问『下载』文件夹」这类授权框每次扫描都重弹。
#
# --identifier 显式给 com.aicleaner.app（和 Info.plist 的 CFBundleIdentifier 一致；
# 不给的话 codesign 会用可执行文件名 "ai-mac-cleaner"，与 bundle id 不符）。
# 不加 --deep：本 bundle 里没有嵌套的 .app / framework，--deep 对它没意义
# 而且 Apple 已不推荐。
#
# **局限（别宣传成「一次授权永久有效」）**：adhoc 签名没有 Developer ID 背书，
# 代码一改、重新编译，签名哈希就变，授权还会重弹一次。真正的一次性授权需要
# Developer ID（$99/年）。现在的效果是：日常使用不再反复弹，重新构建后弹一次。
codesign --force --sign - \
         --identifier com.aicleaner.app \
         --options runtime \
         "$TARGET" 2>&1 | sed 's/^/  /' || {
    echo "  ! 签名失败 —— app 仍可用，但 TCC 授权会反复弹框"
}
if codesign -dv "$TARGET" 2>&1 | grep -q "Identifier=com.aicleaner.app"; then
    echo "  ✓ 已签名（identifier=com.aicleaner.app）"
else
    echo "  ! 签名标识符不符预期，TCC 授权可能记不住"
fi

echo "━━ 5/5 验证 + 重置窗口记忆 ━━"
# 清掉本 app 记住的窗口尺寸（Saved Application State）。
# 原因：macOS 按位置/屏幕记住窗口 frame，adhoc 重打包后身份仍按位置匹配，
# 于是重新打开常带着「上次缩小的旧窄尺寸」→ 侧边栏一开就折叠。
# 删掉它，让用户装完新包第一次打开就用 SwiftUI .defaultSize(1040×680) 的默认展开态。
SS_DIR="$HOME/Library/Saved Application State/com.aicleaner.app.savedState"
if [ -d "$SS_DIR" ]; then
  rm -rf "$SS_DIR"
  echo "  ✓ 已重置窗口记忆（下次打开默认展开侧边栏）"
fi
test -x "$TARGET/Contents/MacOS/$CLI_NAME" && echo "  ✓ 可执行文件就绪"
test -f "$TARGET/Contents/Info.plist" && echo "  ✓ Info.plist 就绪"
test -f "$TARGET/Contents/Resources/$APP_NAME.icns" && echo "  ✓ 图标就绪"

echo ""
echo "✓ 已生成：$TARGET"
echo "  启动方式：open \"$TARGET\"  或在 Finder 双击"
