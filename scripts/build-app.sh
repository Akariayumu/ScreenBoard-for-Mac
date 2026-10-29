#!/bin/bash
# 在 macOS 上打包菜单栏程序：build/ScreenBoard.app
# 用法：scripts/build-app.sh [--install]   --install 复制到 /Applications 并启动
# 签名：默认用钥匙串里名为 "ScreenBoard Dev" 的自签名代码签名证书，重新编译后辅助功能授权仍然有效；
#       没有这个证书就临时签名（每次重新编译都要重新授权）。也可以用 SIGN_IDENTITY=... 指定。
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/ScreenBoard.app
VERSION=$(git describe --tags --always 2>/dev/null || echo dev)
CERT_NAME="ScreenBoard Dev"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    # 不加 -v：自签名证书不受信任，但可以用来签名
    if security find-identity -p codesigning 2>/dev/null | grep -q "\"$CERT_NAME\""; then
        SIGN_IDENTITY="$CERT_NAME"
    else
        SIGN_IDENTITY="-"
        echo "==> 没找到证书 \"$CERT_NAME\"，临时签名：重新编译后要重新授权辅助功能"
    fi
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> ScreenBoard"
swiftc -O -swift-version 5 -parse-as-library \
    -target "$(uname -m)-apple-macos14.0" \
    Sources/*.swift -o "$APP/Contents/MacOS/ScreenBoard"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.xstation.screenboard</string>
    <key>CFBundleName</key>
    <string>ScreenBoard</string>
    <key>CFBundleDisplayName</key>
    <string>屏幕键盘</string>
    <key>CFBundleExecutable</key>
    <string>ScreenBoard</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

codesign --force --sign "$SIGN_IDENTITY" "$APP"
echo "==> $APP（签名：$SIGN_IDENTITY）"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x ScreenBoard 2>/dev/null || true
    rm -rf /Applications/ScreenBoard.app
    cp -R "$APP" /Applications/
    open /Applications/ScreenBoard.app
    echo "==> 已安装并启动 /Applications/ScreenBoard.app"
fi
