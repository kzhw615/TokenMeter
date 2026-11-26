#!/bin/bash
# 一次性创建自签名代码签名证书，用于「固定身份」签名。
# 目的：ad-hoc 签名（codesign --sign -）每次构建的 cdhash 都变，
# macOS 的「屏幕录制」授权会因此失效——每次更新都要重新授权。
# 用固定身份的证书签名后，授权可以跨版本保留。
set -euo pipefail
NAME="TokenMeter Self-Signed"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "✓ 已存在签名身份：$NAME"
    security find-identity -v -p codesigning | grep "$NAME"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "==> 生成自签名证书"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout pass:tokenmeter -name "$NAME" 2>/dev/null

echo "==> 导入登录钥匙串（可能需要输入两次钥匙串密码）"
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P tokenmeter -T /usr/bin/codesign

echo "==> 设为代码签名可信（系统会弹一次授权框，输入登录密码）"
security add-trusted-cert -r trustRoot -p codeSign \
    -k "$HOME/Library/Keychains/login.keychain-db" "$TMP/cert.pem" || {
        echo "⚠️  信任设置被取消，签名可能无法被系统校验；可稍后在「钥匙串访问」里手动把该证书设为「始终信任」。"
    }

echo "==> 结果"
security find-identity -v -p codesigning | grep "$NAME" || echo "✗ 未找到，请检查钥匙串"
