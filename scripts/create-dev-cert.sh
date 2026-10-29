#!/bin/bash
# 在 macOS 上建自签名代码签名证书 "ScreenBoard Dev" 并导入登录钥匙串，只需运行一次。
# 用它签名后，重新编译不会让辅助功能授权失效（授权跟证书走，不跟每次编译的 cdhash 走）。
# 用法：KEYCHAIN_PASSWORD=登录密码 scripts/create-dev-cert.sh   （不设就交互输入）
set -euo pipefail

CERT_NAME="ScreenBoard Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$CERT_NAME\""; then
    echo "==> 证书 \"$CERT_NAME\" 已存在，不用再建"
    exit 0
fi

if [[ -z "${KEYCHAIN_PASSWORD:-}" ]]; then
    read -r -s -p "登录钥匙串密码：" KEYCHAIN_PASSWORD
    echo
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
P12_PASS=$(openssl rand -hex 16)

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = ${CERT_NAME}
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

# /usr/bin/openssl 是 LibreSSL，导出的 p12 能直接被 security 导入
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -name "$CERT_NAME" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" -passout "pass:$P12_PASS"

security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign
# 只放行这把私钥给 codesign 用，避免每次签名弹钥匙串授权框
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -l "$CERT_NAME" \
    -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

security find-identity -p codesigning "$KEYCHAIN" | grep "\"$CERT_NAME\""
echo "==> 已建证书 \"$CERT_NAME\"。重新编译后，到“辅助功能”里删掉旧的 ScreenBoard 再授权一次"
