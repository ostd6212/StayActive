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

EXISTING_LINE="$(security find-identity -v -p codesigning | grep "$CERT_NAME" || true)"
if [ -n "$EXISTING_LINE" ]; then
    if echo "$EXISTING_LINE" | grep -q "$CERT_NAME\"\$"; then
        echo "Identity '$CERT_NAME' already present and trusted. Skipping generation."
        security find-identity -v -p codesigning
        exit 0
    fi
    # Present but flagged invalid (e.g. "(Invalid Key Usage for policy)") --
    # confirmed live this happens on newer macOS for a cert generated
    # without an explicit keyUsage extension. Remove it and regenerate
    # rather than reusing something codesign will refuse anyway.
    echo "Identity '$CERT_NAME' is present but invalid for code signing:"
    echo "  $EXISTING_LINE"
    echo "Removing it and generating a fresh one."
    security delete-identity -c "$CERT_NAME" "$KEYCHAIN"
fi

echo "==> Generating self-signed key + certificate"
# keyUsage=digitalSignature is required alongside extendedKeyUsage=codeSigning --
# without it, newer macOS rejects the identity for code signing entirely
# ("Invalid Key Usage for policy" in `security find-identity`) even though
# it still shows up as present in the keychain.
openssl req -x509 -newkey rsa:2048 -keyout "$KEY_PATH" \
  -out "$CERT_PATH" -days 3650 -nodes -subj "/CN=$CERT_NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" \
  -addext "basicConstraints=critical,CA:false"

echo "==> Exporting to PKCS#12"
# OpenSSL 3.x defaults to AES-256/PBKDF2 for PKCS#12, which macOS's
# Security framework importer cannot parse ("MAC verification failed
# during PKCS12 import (wrong password?)" even with the correct
# password). -legacy forces the old RC2/3DES encoding that `security
# import` understands. Older OpenSSL/LibreSSL doesn't have -legacy (and
# doesn't need it), so fall back if the flag is rejected.
if ! openssl pkcs12 -export -out "$P12_PATH" -inkey "$KEY_PATH" \
      -in "$CERT_PATH" -passout "pass:$P12_PASS" -legacy 2>/tmp/stayactive-pkcs12-err.log; then
    if grep -qi "unknown option\|unrecognized" /tmp/stayactive-pkcs12-err.log; then
        echo "    (-legacy not supported by this openssl, retrying without it)"
        openssl pkcs12 -export -out "$P12_PATH" -inkey "$KEY_PATH" \
          -in "$CERT_PATH" -passout "pass:$P12_PASS"
    else
        cat /tmp/stayactive-pkcs12-err.log
        exit 1
    fi
fi
rm -f /tmp/stayactive-pkcs12-err.log

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
