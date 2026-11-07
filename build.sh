#!/bin/bash
# 编译 T3Shot.app（原生 macOS 应用，菜单栏常驻）。用法：./build.sh [输出目录，默认 ~/Applications] [--install]
#   --install：编译后安装登录启动项并立即启动（⌃⇧4 生效）
set -euo pipefail
cd "$(dirname "$0")"
OUT="$HOME/Applications"; INSTALL=0
for a in "$@"; do case "$a" in --install) INSTALL=1;; *) OUT="$a";; esac; done
APP="$OUT/T3Shot.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/T3Shot" Sources/*.swift -framework AppKit -framework Carbon -framework ScreenCaptureKit
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>T3Shot</string>
  <key>CFBundleIdentifier</key><string>local.t3shot</string>
  <key>CFBundleExecutable</key><string>T3Shot</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# 有开发者证书就用它签名：签名身份稳定，「屏幕录制」授权不会因为重新编译而失效；否则 ad-hoc。
IDENT=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID/{print $2; exit}')
codesign --force --sign "${IDENT:--}" "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "已生成：${APP}（签名：${IDENT:-ad-hoc}）"
if [ "$INSTALL" = 1 ]; then
  pkill -x T3Shot 2>/dev/null || true
  "$APP/Contents/MacOS/T3Shot" --install-agent
fi
