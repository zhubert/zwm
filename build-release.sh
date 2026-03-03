#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="zwm"
BUNDLE_DIR=".release/${APP_NAME}.app"
BUILD_DIR=".build/release"

echo "=== Building release binary ==="
swift build -c release

echo "=== Assembling app bundle ==="
rm -rf "$BUNDLE_DIR"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

# Copy binary
cp "${BUILD_DIR}/zwm-server" "${BUNDLE_DIR}/Contents/MacOS/zwm-server"

# Copy Info.plist
cp resources/Info.plist "${BUNDLE_DIR}/Contents/Info.plist"

# Copy CLI binary alongside for convenience
cp "${BUILD_DIR}/zwm" ".release/zwm"

echo "=== Done ==="
echo "App bundle: ${BUNDLE_DIR}"
echo "CLI binary: .release/zwm"
echo ""
echo "To install:"
echo "  cp -r ${BUNDLE_DIR} /Applications/"
echo "  cp .release/zwm /usr/local/bin/"
