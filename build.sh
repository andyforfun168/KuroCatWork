#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="KuroCatWork"
APP_BUNDLE="$ROOT/${APP_NAME}.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"

echo "==> Building ${APP_NAME}.app..."
mkdir -p "$MACOS_DIR" "$RES_DIR"

cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp -R "$ROOT/Resources/WorkSounds" "$RES_DIR/"

cp "$ROOT/Resources/AppIcon.icns" "$RES_DIR/AppIcon.icns"

SWIFT_SOURCES=(
    "$ROOT/Sources/LiveWorkSources.swift"
    "$ROOT/Sources/KeyMap.swift"
    "$ROOT/Sources/InputEngine.swift"
    "$ROOT/Sources/CatPhysics.swift"
    "$ROOT/Sources/CatRenderer.swift"
    "$ROOT/Sources/CoatPatterns.swift"
    "$ROOT/Sources/WorkHoverPlacement.swift"
    "$ROOT/Sources/WorkPanelDrawing.swift"
    "$ROOT/Sources/WorkTypingCadence.swift"
    "$ROOT/Sources/WorkSounds.swift"
    "$ROOT/Sources/WorkModeExperience.swift"
    "$ROOT/Sources/OverlayWindow.swift"
    "$ROOT/Sources/AppDelegate.swift"
    "$ROOT/Sources/main.swift"
)

COMMON_FLAGS=(
    -module-cache-path ${TMPDIR:-/tmp}/kurocatwork-module-cache
    -swift-version 5
    -O
    -framework WebKit
    -lsqlite3
    -framework AppKit
    -framework CoreGraphics
    -framework QuartzCore
    -framework IOKit
    -framework ApplicationServices
)

TMP_BIN_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_BIN_DIR"' EXIT

echo "==> Compiling arm64 slice (macOS 11.0+)..."
swiftc "${COMMON_FLAGS[@]}" -target arm64-apple-macos11.0 "${SWIFT_SOURCES[@]}" -o "$TMP_BIN_DIR/${APP_NAME}_arm64"

echo "==> Compiling x86_64 (Intel) slice (macOS 11.0+)..."
swiftc "${COMMON_FLAGS[@]}" -target x86_64-apple-macos11.0 "${SWIFT_SOURCES[@]}" -o "$TMP_BIN_DIR/${APP_NAME}_x86_64"

echo "==> Creating Universal binary (arm64 + x86_64)..."
lipo -create "$TMP_BIN_DIR/${APP_NAME}_arm64" "$TMP_BIN_DIR/${APP_NAME}_x86_64" -output "$MACOS_DIR/$APP_NAME"
lipo -info "$MACOS_DIR/$APP_NAME"

# Keep a consistent signing identity across builds so macOS can match privacy grants.
# Switching identities can require granting Input Monitoring again. Order of preference:
#   1. $KUROCAT_SIGN_IDENTITY (CI imports the shared certificate and sets this)
#   2. Developer ID Application / Apple Development certificate in the keychain
#   3. Existing self-signed "KuroCat Code Signing" certificate
#   4. Ad-hoc (last resort — permission will be lost on every update)
SIGN_IDENTITY="${KUROCAT_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application:/{print $2; exit}')"
fi
if [ -z "$SIGN_IDENTITY" ]; then
    # Prefer the long-lived shared "KuroCat Code Signing" cert (matches CI so permissions survive updates)
    if security find-identity -p codesigning 2>/dev/null | grep -q '"KuroCat Code Signing"'; then
        SIGN_IDENTITY="KuroCat Code Signing"
    fi
fi
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development:/{print $2; exit}')"
fi

if [ -n "$SIGN_IDENTITY" ]; then
    echo "==> Signing with stable certificate: $SIGN_IDENTITY"
    codesign --force --deep --sign "$SIGN_IDENTITY" --identifier "com.chanke.kurocat" "$APP_BUNDLE"
else
    echo "==> WARNING: no stable signing certificate found — signing ad-hoc." >&2
    echo "    Users will have to re-enable Input Monitoring after EVERY update." >&2
    if [ -n "${KUROCAT_REQUIRE_STABLE_SIGNATURE:-}" ]; then
        echo "[ERROR] KUROCAT_REQUIRE_STABLE_SIGNATURE is set: refusing to ship an ad-hoc build." >&2
        exit 1
    fi
    codesign --force --deep --sign - --identifier "com.chanke.kurocat" "$APP_BUNDLE"
fi
echo "==> Designated requirement (what macOS uses to recognise KuroCat across updates):"
codesign -d -r- "$APP_BUNDLE" 2>&1 | grep -i designated || true

echo "==> Built successfully: $APP_BUNDLE"
