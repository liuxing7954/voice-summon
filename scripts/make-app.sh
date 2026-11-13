#!/bin/bash
# 打包成可分发的 VoiceSummon.app（单二进制 + bundle 外壳；麦克风/语音识别权限必须挂在 bundle 上）
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="VoiceSummon"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Packaging/Info.plist)"
DIST="dist"
APP="$DIST/$APP_NAME.app"
ARCH_LIST="$(uname -m)"

echo "==> 编译 arm64"
swift build -c release >/dev/null
ARM_BIN="$(swift build -c release --show-bin-path)/$APP_NAME"

echo "==> 编译 x86_64（Intel 兼容）"
X86_BIN=""
if swift build -c release --triple x86_64-apple-macos14.0 >/dev/null 2>&1; then
  X86_BIN="$(swift build -c release --triple x86_64-apple-macos14.0 --show-bin-path)/$APP_NAME"
  ARCH_LIST="arm64 + x86_64"
else
  echo "    x86_64 交叉编译不可用，只出当前架构"
fi

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ -n "$X86_BIN" && -f "$X86_BIN" ]]; then
  lipo -create "$ARM_BIN" "$X86_BIN" -output "$APP/Contents/MacOS/$APP_NAME"
else
  cp "$ARM_BIN" "$APP/Contents/MacOS/$APP_NAME"
fi
cp Packaging/Info.plist "$APP/Contents/Info.plist"
BUILD_TIME="$(date '+%m-%d %H:%M')"
/usr/libexec/PlistBuddy -c "Add :VSBuildTime string $BUILD_TIME" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :VSBuildTime $BUILD_TIME" "$APP/Contents/Info.plist"
[[ -f Packaging/AppIcon.icns ]] && cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp scripts/voicesummon "$APP/Contents/Resources/voicesummon"
printf 'APPL????' > "$APP/Contents/PkgInfo"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

echo "==> ad-hoc 签名"
codesign --force --sign - --identifier com.fujiang.voicesummon "$APP" >/dev/null
codesign --verify --deep --strict "$APP" && echo "    签名校验通过"

cp scripts/voicesummon "$DIST/voicesummon"
chmod +x "$DIST/voicesummon"

echo "==> 打包 zip（保留权限位）"
rm -f "$DIST/$APP_NAME-$VERSION-macOS.zip"
ditto -c -k --keepParent "$APP" "$DIST/$APP_NAME-$VERSION-macOS.zip"

echo
echo "架构：$ARCH_LIST"
echo "完成："
du -sh "$APP" "$DIST/$APP_NAME-$VERSION-macOS.zip"
echo "  app : $(pwd)/$APP"
echo "  zip : $(pwd)/$DIST/$APP_NAME-$VERSION-macOS.zip"
