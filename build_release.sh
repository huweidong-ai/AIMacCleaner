#!/bin/bash
# build_release.sh — 打发布用的 DMG + sha256 校验和
#
# 用法：./build_release.sh [输出目录]
#   默认输出到 ./dist/
#
# 产物：
#   dist/AIMacCleaner-<版本>.dmg
#   dist/AIMacCleaner-<版本>.dmg.sha256
#
# **本脚本不做签名和公证。** AIMacCleaner 目前只有 adhoc 签名（没有 Apple
# Developer 账号），用户首次打开需要右键 → 打开。校验和是在这个前提下
# 能给出的最强的完整性保证：它证明你下到的 DMG 和发布时那份逐字节一致。
# 对一个会删文件的工具，这个不能省。
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

# 版本号和 app 名从 build_app.sh 取，避免两处各写一份而不一致
# shellcheck source=build_app.sh
EXPUNGE_VARS_ONLY=1 source ./build_app.sh

OUT_DIR="${1:-$PROJECT_DIR/dist}"
DMG_NAME="$APP_NAME-$APP_VERSION.dmg"
DMG_PATH="$OUT_DIR/$DMG_NAME"

# 先清掉同名旧产物。**这一步必须在自检之前** —— 否则自检失败中止时，
# dist/ 里会留着上一次成功构建的旧 DMG，你可能以为这次发布失败了、
# 却把旧文件传上去。宁可目录是空的，也不能让它似是而非。
rm -f "$DMG_PATH" "$DMG_PATH.sha256"

# 在临时目录里组装 app，不动 /Applications 里那份 —— 发布构建不该
# 顺手把开发机上正在用的 app 换掉。
STAGE="$(mktemp -d)"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

echo "━━ 1/4 构建 app 到临时目录 ━━"
./build_app.sh "$STAGE/$APP_NAME.app" > /dev/null
test -x "$STAGE/$APP_NAME.app/Contents/MacOS/$CLI_NAME" \
    || { echo "✗ app 构建失败"; exit 1; }
echo "  ✓ $STAGE/$APP_NAME.app"

echo "━━ 2/4 自检（不通过就不发布）━━"
# 发布前必须跑一遍。构建成功不等于逻辑正确，而这个工具的 bug 会删错文件。
if "$STAGE/$APP_NAME.app/Contents/MacOS/$CLI_NAME" --self-test > "$STAGE/selftest.log" 2>&1; then
    tail -1 "$STAGE/selftest.log" | sed 's/^/  /'
else
    echo "  ✗ 自检未通过，中止发布："
    grep -E '✗' "$STAGE/selftest.log" | head -20 | sed 's/^/    /'
    exit 1
fi

echo "━━ 3/4 打 DMG ━━"
mkdir -p "$OUT_DIR"

# DMG 里放 app + 一个「拖到这里」的 Applications 软链，这是 Mac 用户
# 期望的安装体验（不放软链的话用户得自己开一个 Finder 窗口）
DMG_SRC="$STAGE/dmg"
mkdir -p "$DMG_SRC"
cp -R "$STAGE/$APP_NAME.app" "$DMG_SRC/"
ln -s /Applications "$DMG_SRC/Applications"

hdiutil create \
    -volname "$APP_NAME $APP_VERSION" \
    -srcfolder "$DMG_SRC" \
    -ov -format UDZO \
    "$DMG_PATH" > /dev/null
echo "  ✓ $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"

echo "━━ 4/4 生成 sha256 ━━"
# 只存文件名不存绝对路径，这样用户 `shasum -a 256 -c` 时不必在同一路径下
(cd "$OUT_DIR" && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256")
cat "$OUT_DIR/$DMG_NAME.sha256" | sed 's/^/  /'

# 自校验：立刻验一遍，确保发出去的校验和是对的
(cd "$OUT_DIR" && shasum -a 256 -c "$DMG_NAME.sha256" > /dev/null) \
    && echo "  ✓ 校验和自检通过" \
    || { echo "  ✗ 校验和对不上，别发布"; exit 1; }

echo ""
echo "✓ 发布产物就绪："
echo "    $DMG_PATH"
echo "    $DMG_PATH.sha256"
echo ""
echo "  两个文件都要上传到 GitHub Release —— 只发 DMG 的话校验和就没有意义。"
echo "  用户侧验证方式："
echo "    shasum -a 256 -c $DMG_NAME.sha256"
