#!/bin/bash
# 编译 T3Shot.app（原生 macOS 应用）。用法：./build.sh [输出目录，默认 ~/Applications]
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-$HOME/Applications}"
APP="$OUT/T3Shot.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/T3Shot" T3Shot.swift -framework AppKit -framework CryptoKit
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>T3Shot</string>
  <key>CFBundleIdentifier</key><string>local.t3shot</string>
  <key>CFBundleExecutable</key><string>T3Shot</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "已生成：$APP"
