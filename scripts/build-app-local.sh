#!/usr/bin/env bash
# build-app-local.sh — Build Murmur.app locally and ad-hoc sign it.
#
# Unlike scripts/build-dmg.sh, this does NOT use a Developer ID certificate and
# does NOT notarize. It produces a locally-runnable .app signed with an ad-hoc
# signature ("-"), which is the right choice when building from source you've
# audited yourself and don't want to depend on any external signing identity.
#
# Usage: bash scripts/build-app-local.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
SWIFT_DIR="$REPO/src-swift"

APP_NAME="Murmur"
DIST_DIR="$REPO/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

echo "▶ Building $APP_NAME (local ad-hoc)…"

# ── 1. Release binary ─────────────────────────────────────────────────────────
echo "[1/4] Compiling release binary…"
cd "$SWIFT_DIR"
swift build -c release --product murmur
BUILD_DIR="$SWIFT_DIR/.build/arm64-apple-macosx/release"
BINARY="$BUILD_DIR/murmur"

# ── 2. Assemble .app bundle ───────────────────────────────────────────────────
echo "[2/4] Assembling $APP_NAME.app…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY"               "$APP_BUNDLE/Contents/MacOS/murmur"
cp "$SWIFT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$SWIFT_DIR/murmur.icns" "$APP_BUNDLE/Contents/Resources/murmur.icns"

# SPM resource bundle (tray icons / localizations). Placed in code-sign-safe
# locations under Contents/ and resolved at runtime by Bundle.appResources
# (see Localization.swift) — NOT at the .app root, which would break signing.
#   - Contents/Resources/ : primary lookup for Bundle.appResources
#   - Contents/MacOS/      : the tray-icon loader looks next to the executable
if [ -d "$BUILD_DIR/murmur_murmur.bundle" ]; then
    cp -R "$BUILD_DIR/murmur_murmur.bundle" "$APP_BUNDLE/Contents/Resources/"
    cp -R "$BUILD_DIR/murmur_murmur.bundle" "$APP_BUNDLE/Contents/MacOS/"
fi

# SenseVoice model → Contents/Resources/models/sense-voice-zh-en/
# Bundle whichever precision variants are present. The app prefers model.onnx
# (fp32) and falls back to model.int8.onnx, so shipping both lets the user switch.
MODEL_SRC="$REPO/models/sense-voice-zh-en"
MODEL_DST="$APP_BUNDLE/Contents/Resources/models/sense-voice-zh-en"
if [ -f "$MODEL_SRC/model.onnx" ] || [ -f "$MODEL_SRC/model.int8.onnx" ]; then
    mkdir -p "$MODEL_DST"
    cp "$MODEL_SRC/tokens.txt" "$MODEL_DST/"
    [ -f "$MODEL_SRC/model.onnx" ]      && cp "$MODEL_SRC/model.onnx"      "$MODEL_DST/" && echo "  + bundled model.onnx (fp32)"
    [ -f "$MODEL_SRC/model.int8.onnx" ] && cp "$MODEL_SRC/model.int8.onnx" "$MODEL_DST/" && echo "  + bundled model.int8.onnx"
else
    echo "  ⚠ no model found in $MODEL_SRC — app will fail to transcribe"
fi

# ── 3. Code sign (inside-out) ─────────────────────────────────────────────────
# Prefer the stable local "Murmur Local Signing" self-signed identity if present:
# it yields a Designated Requirement anchored to the cert (not the cdhash), so
# macOS keeps Accessibility/Microphone grants across rebuilds. Falls back to
# ad-hoc ("-") when the cert isn't installed (see scripts/setup-signing-cert.sh).
SIGN_ID=$(security find-identity 2>/dev/null | grep "Murmur Local Signing" | grep -oE "[0-9A-F]{40}" | head -1)
SIGN_ID="${SIGN_ID:--}"
echo "[3/4] Signing with: $SIGN_ID"
ENTITLEMENTS="$SWIFT_DIR/murmur.entitlements"
# Sign both copies of the resource bundle before sealing the app.
for RES_BUNDLE in "$APP_BUNDLE/Contents/Resources/murmur_murmur.bundle" "$APP_BUNDLE/Contents/MacOS/murmur_murmur.bundle"; do
    [ -d "$RES_BUNDLE" ] && codesign --force --sign "$SIGN_ID" "$RES_BUNDLE"
done
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$APP_BUNDLE/Contents/MacOS/murmur"
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$APP_BUNDLE"

# ── 4. Verify ─────────────────────────────────────────────────────────────────
echo "[4/4] Verifying…"
codesign --verify --verbose=1 "$APP_BUNDLE"
echo ""
echo "✓ Done: $APP_BUNDLE"
ls -ld "$APP_BUNDLE"
