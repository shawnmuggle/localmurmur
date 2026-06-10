#!/usr/bin/env bash
# setup-signing-cert.sh — Create a STABLE local code-signing identity.
#
# Why: building with an ad-hoc signature ("-") changes the code's Designated
# Requirement on every rebuild, so macOS drops the app's Accessibility and
# Microphone grants and you must re-authorize after each build. Signing with a
# fixed self-signed certificate keeps the Designated Requirement constant
# (anchored to the cert), so the grants persist across rebuilds.
#
# This identity is self-signed and NOT trusted by Gatekeeper — that's fine for a
# locally-built app you run yourself. The keychain password is randomly generated
# here and never stored anywhere (the keychain is set to never auto-lock), so no
# secret is committed to the repo.
#
# Run once per machine:  bash scripts/setup-signing-cert.sh
set -euo pipefail

CN="Murmur Local Signing"
KC="murmur-signing.keychain"
KCPW="$(openssl rand -hex 16)"   # throwaway, only needed during creation

if security find-identity 2>/dev/null | grep -q "$CN"; then
    echo "✓ '$CN' already exists — nothing to do."
    security find-identity 2>/dev/null | grep "$CN"
    exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; cd "$TMP"

echo "▶ Generating self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
    -subj "/CN=$CN" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# -legacy: package the .p12 with algorithms the macOS keychain can import
# (OpenSSL 3's modern defaults fail `security import` with a MAC error).
openssl pkcs12 -export -legacy -out id.p12 -inkey key.pem -in cert.pem \
    -passout "pass:$KCPW" -name "$CN" 2>/dev/null

echo "▶ Importing into dedicated keychain '$KC'…"
security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KCPW" "$KC"
security set-keychain-settings "$KC"               # no auto-lock / timeout
security unlock-keychain -p "$KCPW" "$KC"
security import id.p12 -k "$KC" -P "$KCPW" -T /usr/bin/codesign -A
security set-key-partition-list -S apple-tool:,apple:,unsigned: -s -k "$KCPW" "$KC" >/dev/null 2>&1
# Add to the user keychain search list (preserving existing entries).
security list-keychains -d user -s "$KC" $(security list-keychains -d user | sed 's/"//g')

echo "▶ Done. build-app-local.sh will pick this up automatically:"
security find-identity 2>/dev/null | grep "$CN"
