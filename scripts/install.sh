#!/bin/bash
# 本地更新：重新编译 → 替换 /Applications/VoiceSummon.app → 重启
set -euo pipefail

cd "$(dirname "$0")/.."
./scripts/make-app.sh

echo "==> 停掉正在跑的旧版本"
pkill -f "VoiceSummon.app/Contents/MacOS/VoiceSummon" 2>/dev/null || true
sleep 1

echo "==> 安装到 /Applications"
rm -rf "/Applications/VoiceSummon.app"
cp -R dist/VoiceSummon.app "/Applications/VoiceSummon.app"
xattr -dr com.apple.quarantine "/Applications/VoiceSummon.app" 2>/dev/null || true

echo "==> 启动"
open "/Applications/VoiceSummon.app"
echo "完成：/Applications/VoiceSummon.app"
