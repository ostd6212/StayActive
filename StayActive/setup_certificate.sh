#!/bin/bash
# Creates a stable self-signed code-signing certificate entirely via CLI
# (no Keychain Access GUI), so the Accessibility grant survives rebuilds
# as long as the same certificate is reused.
#
# Run once, on macOS, before the first build.sh. Safe to re-run: it will
# reuse the existing identity if one is already trusted.
set -euo pipefail

CERT_NAME="StayActive Dev"
KEY_PATH="$HOME/stayactive-key.pem"
CERT_PATH="$HOME/stayactive-cert.pem"
P12_PATH="$HOME/stayactive.p12"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
P12_PASS="temppass123"

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "Identity '$CERT_NAME' already present and trusted. Skipping generation."
    security find-identity -v -p codesigning
    exit 0
fi

echo "==> Generating self-signed key + certificate"
openssl req -x509 -newkey rsa:2048 -keyout "$KEY_PATH" \
  -out "$CERT_PATH" -days 3650 -nodes -subj "/CN=$CERT_NAME" \
  -addext "extendedKeyUsage=codeSigning" \
  -addext "basicConstraints=critical,CA:false"

echo "==> Exporting to PKCS#12"
openssl pkcs12 -export -out "$P12_PATH" -inkey "$KEY_PATH" \
  -in "$CERT_PATH" -passout "pass:$P12_PASS"

echo "==> Importing into login keychain"
security import "$P12_PATH" -k "$KEYCHAIN" \
  -P "$P12_PASS" -T /usr/bin/codesign -T /usr/bin/security

echo "==> Trusting the certificate for code signing"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$CERT_PATH"

echo "==> Verifying identity is usable"
security find-identity -v -p codesigning | grep "$CERT_NAME" || {
    echo "ERROR: '$CERT_NAME' did not show up in find-identity output."
    echo "You may need to unlock the keychain first:"
    echo "  security unlock-keychain $KEYCHAIN"
    exit 1
}

echo ""
echo "'$CERT_NAME' is ready. Sensitive files left on disk (keep or shred as you prefer):"
echo "  $KEY_PATH"
echo "  $CERT_PATH"
echo "  $P12_PATH  (protected only by password '$P12_PASS')"
