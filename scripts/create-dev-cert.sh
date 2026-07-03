#!/bin/bash
# Creates a stable self-signed code-signing identity ("Confluence Dev") in the login
# keychain so local builds keep the SAME signature across rebuilds. Without this the app
# is ad-hoc signed with a new signature every build, and macOS re-prompts for Keychain
# access each time. With a stable identity, "Always Allow" sticks for good.
#
# Run once per machine (safe to re-run). Requires OpenSSL 3 (brew) — uses -legacy so the
# PKCS12 is readable by Apple's `security` tool.
set -euo pipefail
CERT_NAME="Confluence Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
P12_PASS="temp-import-pass" # transient; only used to move the key into the keychain
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-identity -p codesigning -v "$KEYCHAIN" | grep -q "$CERT_NAME"; then
  echo "'$CERT_NAME' already exists — nothing to do."
  exit 0
fi

echo "Generating self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$CERT_NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

# -legacy: OpenSSL 3's default PKCS12 MAC isn't readable by macOS `security`.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout "pass:$P12_PASS" -name "$CERT_NAME" >/dev/null 2>&1

security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" -A -T /usr/bin/codesign >/dev/null
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" >/dev/null 2>&1 || true

echo "Done:"
security find-identity -p codesigning -v "$KEYCHAIN" | grep "$CERT_NAME"
